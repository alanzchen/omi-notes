"""Phone → server ingest: chunks, seals, events, capture status (capture-format-v1.md, "HTTP API").

File first (docs/vault.md, "Write rules"): validate → durable vault write (file + new parent
directories fsynced; receipts/events appended and fsynced) → index commit (`synchronous=FULL`) →
only then 2xx. 2xx means the bytes are durable in the vault and queued, not processed or synced.

A file without an index row (a crash, or a failed commit, between the two) is never overwritten:
a retry with identical bytes indexes it and answers 200, different bytes get 409. The startup
sweep (`rebuild.sweep`) indexes such orphans too. Everything is idempotent by identity + content.
"""

from __future__ import annotations

import errno
import hashlib
import json
import shutil
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, StrictBool, StrictInt, StrictStr, ValidationError

from .audio import aac
from .db import Database
from .envelope import EnvelopeError, EnvelopeHeader, parse_envelope
from .settings import Settings
from .spool import atomic_write_bytes, make_dirs_durable
from .util import UUID_RE, canonical_json, sha256_hex
from .vault import Vault

MIN_FREE_BYTES = 256 * 1024 * 1024
_lock = threading.Lock()


@dataclass
class ApiError(Exception):
    status: int
    code: str
    detail: str = ""

    def body(self) -> dict[str, str]:
        return {"error": self.code, "detail": self.detail}


SealReason = Literal[
    "ble_disconnected",
    "user_stopped",
    "device_forgotten",
    "app_recovered",
    "sync_complete",
    "sync_interrupted",
    "replay_complete",
]


def _iso_string(value: Any) -> Any:
    """Timestamps must be ISO-8601 strings on the wire (no numeric epochs)."""
    if not isinstance(value, str):
        raise ValueError("expected an ISO-8601 timestamp string")
    return value


IsoTime = Annotated[datetime, BeforeValidator(_iso_string)]
Count = Annotated[StrictInt, Field(ge=0)]


class RingSealInfo(BaseModel):
    model_config = ConfigDict(extra="allow")
    generation: Count | None = None
    info_read_seq: Count | None = None
    info_write_seq: Count | None = None
    done_next_seq: Count | None = None
    dropped: Count | None = None
    rtc_valid: StrictBool | None = None
    covers_until: IsoTime | None = None


class SealBody(BaseModel):
    """Validated strictly (no string→number coercion): only the normalized values are indexed,
    while the raw body is kept (seal.json) for the immutability comparison."""

    model_config = ConfigDict(extra="allow")
    last_chunk_sequence: Annotated[StrictInt, Field(ge=-1)]
    reason: SealReason
    ended_at: IsoTime
    end_offset_us: Count | None = None
    device_id: Annotated[StrictStr, Field(min_length=1, max_length=128)]
    source: Literal["live_ble", "device_ring", "wav_replay", "watch_mic"]
    ring: RingSealInfo | None = None


class EventBody(BaseModel):
    model_config = ConfigDict(extra="allow")
    device_id: Annotated[StrictStr, Field(min_length=1, max_length=128)]
    type: Annotated[StrictStr, Field(min_length=1, max_length=64)]
    at: IsoTime
    data: dict[str, Any] = Field(default_factory=dict)
    capture_id: StrictStr | None = None
    offset_us: Count | None = None


def _check_uuid(value: str, what: str) -> None:
    if not UUID_RE.match(value):
        raise ApiError(422, f"invalid_{what}", f"{what} must be a lowercase UUID")


def _aware_epoch(dt: datetime, field: str) -> float:
    if dt.tzinfo is None:
        raise ApiError(422, "invalid_body", f"{field} must include a timezone")
    return dt.timestamp()


@dataclass(frozen=True)
class SealFacts:
    """A validated seal's normalized values (what the index stores)."""

    seal: SealBody
    canonical: str
    ended_at: float
    covers_until: float | None


def validate_seal(raw: Any) -> SealFacts:
    if not isinstance(raw, dict):
        raise ApiError(422, "invalid_body", "seal body must be a JSON object")
    try:
        seal = SealBody.model_validate(raw)
    except ValidationError as exc:
        raise ApiError(422, "invalid_body", str(exc.errors(include_url=False, include_input=False))) from exc
    ended_at = _aware_epoch(seal.ended_at, "ended_at")
    ring = seal.ring or RingSealInfo()
    covers_until: float | None = None
    if seal.reason == "sync_complete":
        if seal.source != "device_ring":
            raise ApiError(422, "invalid_body", "sync_complete is only valid for device_ring captures")
        if ring.covers_until is None or ring.info_read_seq is None:
            raise ApiError(422, "invalid_body", "sync_complete requires ring.covers_until and ring.info_read_seq")
        covers_until = _aware_epoch(ring.covers_until, "ring.covers_until")
    elif seal.reason == "sync_interrupted" and seal.source != "device_ring":
        raise ApiError(422, "invalid_body", "sync_interrupted is only valid for device_ring captures")
    return SealFacts(seal, canonical_json(raw), ended_at, covers_until)


@dataclass(frozen=True)
class EventFacts:
    event: EventBody
    canonical: str
    at: float
    code: int | None


def validate_event(raw: Any) -> EventFacts:
    if not isinstance(raw, dict):
        raise ApiError(422, "invalid_body", "event body must be a JSON object")
    try:
        event = EventBody.model_validate(raw)
    except ValidationError as exc:
        raise ApiError(422, "invalid_body", str(exc.errors(include_url=False, include_input=False))) from exc
    at = _aware_epoch(event.at, "at")
    code = event.data.get("code") if event.type == "button" else None
    if code is not None and (not isinstance(code, int) or isinstance(code, bool)):
        raise ApiError(422, "invalid_body", "button data.code must be an integer")
    validate_event_type(event)
    return EventFacts(event, canonical_json(raw), at, code)


def validate_event_type(event: EventBody) -> None:
    """Type-specific requirements (capture-format-v1.md, "Events")."""
    data = event.data
    if event.type in ("voice_enrollment_start", "voice_enrollment_end"):
        enrollment = data.get("enrollment_id")
        if not isinstance(enrollment, str) or not UUID_RE.match(enrollment):
            raise ApiError(422, "invalid_body", f"{event.type} requires data.enrollment_id (lowercase UUID)")
        if event.capture_id is not None and not UUID_RE.match(event.capture_id):
            raise ApiError(422, "invalid_body", "capture_id must be a lowercase UUID")
        if event.type == "voice_enrollment_start" and (event.capture_id is None or event.offset_us is None):
            raise ApiError(422, "invalid_body", "voice_enrollment_start requires capture_id and offset_us")
        if event.type == "voice_enrollment_end":
            end = data.get("end_offset_us")
            if not isinstance(end, int) or isinstance(end, bool) or end < 0:
                raise ApiError(422, "invalid_body", "voice_enrollment_end requires data.end_offset_us (integer >= 0)")
            if data.get("outcome") not in ("completed", "cancelled", "interrupted"):
                raise ApiError(422, "invalid_body", "voice_enrollment_end requires data.outcome "
                               "(completed, cancelled or interrupted)")  # fmt: skip


# -- index rows (shared by ingest, the startup sweep and the rebuild) ------------------------------


def ring_record_hashes(env) -> list[tuple[int, str]]:
    """(ring sequence, sha1) of every record in a ring chunk."""
    if env.header.payload_format != "ring_records_v1":
        return []
    first = env.header.ring.first_sequence
    return [(first + i, hashlib.sha1(raw).hexdigest()) for i, raw in enumerate(env.ring_records())]


def index_chunk(conn, header: EnvelopeHeader, *, digest: str, size: int, path: str, received_at: float,
                raw_deleted: bool = False, ring: list[tuple[int, str]] = ()) -> None:  # fmt: skip
    capture_id = header.capture_id
    started = header.capture_started_at.timestamp()
    conn.execute(
        "INSERT OR IGNORE INTO captures (capture_id, device_id, source, created_at) VALUES (?,?,?,?)",
        (capture_id, header.device_id, header.source, received_at),
    )
    conn.execute(
        """UPDATE captures SET payload_format=?, codec_id=?, capture_started_at=?,
               offline_storage=COALESCE(?, offline_storage), device_name=COALESCE(?, device_name),
               model_number=COALESCE(?, model_number), firmware_revision=COALESCE(?, firmware_revision),
               hardware_revision=COALESCE(?, hardware_revision), timezone=COALESCE(?, timezone),
               ring_dropped=COALESCE(?, ring_dropped), created_at=MIN(created_at, ?)
           WHERE capture_id=?""",
        (
            header.payload_format,
            header.codec_id,
            started,
            None if header.offline_storage is None else int(header.offline_storage),
            header.device_name,
            header.model_number,
            header.firmware_revision,
            header.hardware_revision,
            header.timezone,
            header.ring.dropped if header.ring else None,
            received_at,
            capture_id,
        ),
    )
    conn.execute(
        """INSERT INTO chunks (capture_id, chunk_sequence, device_id, source, sha256, size, path, received_at,
               start_epoch, end_epoch, start_offset_us, end_offset_us, status, raw_deleted)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (capture_id, header.chunk_sequence, header.device_id, header.source, digest, size, path, received_at,
         header.chunk_start_epoch, header.chunk_end_epoch, header.chunk_start_offset_us, header.chunk_end_offset_us,
         "processed" if raw_deleted else "pending", int(raw_deleted)),
    )  # fmt: skip
    conn.executemany(
        """INSERT OR IGNORE INTO ring_records (device_id, ring_seq, record_hash, capture_id, chunk_sequence, received_at)
           VALUES (?,?,?,?,?,?)""",
        [(header.device_id, rs, h, capture_id, header.chunk_sequence, received_at) for rs, h in ring],
    )
    touch_device(conn, header.device_id, received_at, header.device_name, header.model_number, header.firmware_revision)


def index_seal(conn, capture_id: str, facts: SealFacts, received_at: float) -> None:
    seal, ring = facts.seal, facts.seal.ring or RingSealInfo()
    conn.execute(
        "INSERT OR IGNORE INTO captures (capture_id, device_id, source, created_at) VALUES (?,?,?,?)",
        (capture_id, seal.device_id, seal.source, received_at),
    )
    # Only sync_complete carries coverage evidence; app_recovered/sync_interrupted never do.
    conn.execute(
        """UPDATE captures SET seal_json=?, seal_reason=?, last_chunk_sequence=?, sealed_at=?,
               ended_at=?, seal_end_offset_us=?, ring_covers_until=?, ring_generation=?,
               ring_info_read_seq=?, ring_dropped=COALESCE(ring_dropped, ?), created_at=MIN(created_at, ?)
           WHERE capture_id=?""",
        (facts.canonical, seal.reason, seal.last_chunk_sequence, received_at, facts.ended_at, seal.end_offset_us,
         facts.covers_until, ring.generation, ring.info_read_seq, ring.dropped, received_at, capture_id),
    )  # fmt: skip
    touch_device(conn, seal.device_id, received_at)


def index_event(conn, event_id: str, facts: EventFacts, received_at: float) -> None:
    event = facts.event
    conn.execute(
        """INSERT INTO events (event_id, device_id, type, at, capture_id, offset_us, code, body_json, received_at)
           VALUES (?,?,?,?,?,?,?,?,?)""",
        (event_id, event.device_id, event.type, facts.at, event.capture_id, event.offset_us, facts.code,
         facts.canonical, received_at),
    )  # fmt: skip
    touch_device(conn, event.device_id, received_at)
    if event.type != "heartbeat":
        return
    data = event.data
    conn.execute(
        """UPDATE devices SET heartbeat_json=?,
               firmware_revision=COALESCE(?, firmware_revision),
               model_number=COALESCE(?, model_number)
           WHERE device_id=?""",
        (
            canonical_json({"at": facts.at, **data}),
            data.get("firmware_revision") if isinstance(data.get("firmware_revision"), str) else None,
            data.get("model_number") if isinstance(data.get("model_number"), str) else None,
            event.device_id,
        ),
    )
    cov = data.get("coverage")
    if isinstance(cov, dict):
        cap = cov.get("capture_id")
        through = cov.get("through_offset_us")
        requires = cov.get("through_chunk_sequence")
        if isinstance(cap, str) and UUID_RE.match(cap) and isinstance(through, int) and through >= 0 and isinstance(requires, int):
            conn.execute(
                """INSERT INTO coverage (device_id, kind, capture_id, through_offset_us, requires_chunk, event_id)
                   VALUES (?,?,?,?,?,?)""",
                (event.device_id, "heartbeat", cap, through, requires, event_id),
            )


def touch_device(conn, device_id: str, now: float, name=None, model=None, firmware=None) -> None:
    conn.execute(
        """INSERT INTO devices (device_id, device_name, model_number, firmware_revision, last_seen)
           VALUES (?,?,?,?,?)
           ON CONFLICT(device_id) DO UPDATE SET
             device_name=COALESCE(excluded.device_name, device_name),
             model_number=COALESCE(excluded.model_number, model_number),
             firmware_revision=COALESCE(excluded.firmware_revision, firmware_revision),
             last_seen=MAX(COALESCE(last_seen, 0), excluded.last_seen)""",
        (device_id, name, model, firmware, now),
    )


def receipt_time(vault: Vault, device_id: str, capture_id: str, seq: int) -> float | None:
    for line in Vault.read_jsonl(vault.receipts_path(device_id, capture_id)):
        if line.get("seq") == seq and isinstance(line.get("received_at"), (int, float)):
            return float(line["received_at"])
    return None


def tombstone_header(tomb: dict) -> EnvelopeHeader:
    return EnvelopeHeader.model_validate(tomb["header"])


# -- ingest ----------------------------------------------------------------------------------------


class ReadOnly(Exception):
    """The vault is open read-only (incomplete sync, divergence, foreign writer)."""


class Ingest:
    """HTTP ingest against one vault + index. One process-wide lock serializes identity checks."""

    def __init__(self, db: Database, vault: Vault, settings: Settings, *, read_only: callable = lambda: None,
                 clock=time.time) -> None:  # fmt: skip
        self.db = db
        self.vault = vault
        self.settings = settings
        self.read_only = read_only  # () -> reason or None
        self.clock = clock  # receipt times (injectable for tests)
        # Captures / events with a durable file whose index commit failed in this process.
        self._dirty: set[tuple[str, str]] = set()
        self._pending_events: dict[str, tuple[str, float]] = {}

    def _writable(self) -> None:
        reason = self.read_only()
        if reason:
            raise ApiError(503, "vault_read_only", reason)

    def _recover(self, device_id: str, capture_id: str) -> None:
        if (device_id, capture_id) in self._dirty:
            from .rebuild import index_capture_orphans

            index_capture_orphans(self.db, self.vault, device_id, capture_id)
            self._dirty.discard((device_id, capture_id))

    # -- chunks ----------------------------------------------------------------------------------

    def put_chunk(self, capture_id: str, seq: int, body: bytes, sha_header: str | None) -> tuple[int, dict]:
        _check_uuid(capture_id, "capture_id")
        if seq < 0:
            raise ApiError(422, "invalid_chunk_sequence", "chunk_sequence must be >= 0")
        if not sha_header or len(sha_header) != 64:
            raise ApiError(400, "missing_sha256", "X-Content-SHA256 header with a hex SHA-256 is required")
        digest = sha256_hex(body)
        if digest != sha_header.lower():
            raise ApiError(400, "checksum_mismatch", "body SHA-256 does not match X-Content-SHA256")

        def ok(status: int, duplicate: bool) -> tuple[int, dict]:
            return status, {"capture_id": capture_id, "chunk_sequence": seq, "sha256": digest, "stored": True,
                            "duplicate": duplicate}  # fmt: skip

        db, vault = self.db, self.vault
        with _lock:
            existing = db.one("SELECT sha256 FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq))
            if existing is None:
                capture = db.one("SELECT device_id FROM captures WHERE capture_id=?", (capture_id,))
                if capture is not None:
                    self._recover(capture["device_id"], capture_id)
                    existing = db.one(
                        "SELECT sha256 FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq)
                    )
            if existing is not None:
                if existing["sha256"] == digest:
                    return ok(200, True)
                raise ApiError(409, "chunk_conflict", "different content is already stored under this identity")

            try:
                env = parse_envelope(body, capture_id=capture_id, chunk_sequence=seq)
            except EnvelopeError as exc:
                raise ApiError(422, "invalid_envelope", str(exc)) from exc
            if env.header.payload_format == "aac_m4a_v1":
                # refuse a file we can't decode before acknowledging it (the phone keeps refused ones)
                try:
                    aac.decode(env.payload, env.header.record_count)
                except aac.AacError as exc:
                    raise ApiError(422, "invalid_audio", str(exc)) from exc
            header = env.header
            if (header.device_id, capture_id) in self._dirty:
                self._recover(header.device_id, capture_id)
                existing = db.one("SELECT sha256 FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq))
                if existing is not None:
                    if existing["sha256"] == digest:
                        return ok(200, True)
                    raise ApiError(409, "chunk_conflict", "different content is already stored under this identity")

            capture = db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
            started = header.capture_started_at.timestamp()
            if capture is not None:
                if capture["device_id"] != header.device_id or capture["source"] != header.source:
                    raise ApiError(409, "capture_identity_conflict", "device_id/source differ from this capture")
                if capture["capture_started_at"] is not None and abs(capture["capture_started_at"] - started) > 0.0015:
                    raise ApiError(409, "capture_identity_conflict", "capture_started_at differs from earlier chunks")

            path = vault.chunk_path(header.device_id, capture_id, seq)
            tomb_path = path.with_suffix(".gone")
            if path.exists() or tomb_path.exists():
                return ok(*self._adopt_orphan(env, digest, len(body), path, tomb_path))

            if capture is not None and capture["last_chunk_sequence"] is not None and seq > capture["last_chunk_sequence"]:
                raise ApiError(409, "beyond_seal", "chunk_sequence is above the sealed last_chunk_sequence")
            self._writable()
            self._ensure_space()
            try:
                atomic_write_bytes(path, body)
            except OSError as exc:
                if exc.errno == errno.ENOSPC:
                    raise ApiError(507, "storage_full", "server disk is full") from exc
                raise
            now = self.clock()
            try:
                Vault.append_jsonl(vault.receipts_path(header.device_id, capture_id),
                                   {"seq": seq, "sha256": digest, "received_at": now})  # fmt: skip
                with db.tx() as conn:
                    index_chunk(conn, header, digest=digest, size=len(body), path=vault.relpath(path), received_at=now,
                                ring=ring_record_hashes(env))  # fmt: skip
            except BaseException:
                self._dirty.add((header.device_id, capture_id))
                raise
        return ok(201, False)

    def _adopt_orphan(self, env, digest: str, size: int, path, tomb_path) -> tuple[int, bool]:
        """A durable file for this identity exists without an index row: same bytes → index it
        (200), different bytes → 409. Never overwritten."""
        header = env.header
        if path.exists():
            data = path.read_bytes()
            if sha256_hex(data) != digest:
                raise ApiError(409, "chunk_conflict", "different content is already stored under this identity")
            deleted = False
        else:
            tomb = json.loads(tomb_path.read_text())
            if tomb.get("sha256") != digest:
                raise ApiError(409, "chunk_conflict", "different content was stored (and expired) under this identity")
            deleted = True
        received = receipt_time(self.vault, header.device_id, header.capture_id, header.chunk_sequence)
        if received is None:
            self._writable()
            received = self.clock()
            Vault.append_jsonl(self.vault.receipts_path(header.device_id, header.capture_id),
                               {"seq": header.chunk_sequence, "sha256": digest, "received_at": received})  # fmt: skip
        with self.db.tx() as conn:
            index_chunk(conn, header, digest=digest, size=size, path=self.vault.relpath(path), received_at=received,
                        raw_deleted=deleted, ring=ring_record_hashes(env))  # fmt: skip
            if deleted:
                from .rebuild import apply_capture_evidence

                apply_capture_evidence(conn, self.vault, header.device_id, header.capture_id, only_seq=header.chunk_sequence)
        return 200, True

    def _ensure_space(self) -> None:
        make_dirs_durable(self.vault.raw)
        if shutil.disk_usage(self.vault.raw).free < MIN_FREE_BYTES:
            raise ApiError(507, "storage_full", "server disk is nearly full")

    # -- seals -----------------------------------------------------------------------------------

    def put_seal(self, capture_id: str, raw: Any) -> tuple[int, dict]:
        _check_uuid(capture_id, "capture_id")
        facts = validate_seal(raw)
        seal = facts.seal
        db, vault = self.db, self.vault
        with _lock:
            self._recover(seal.device_id, capture_id)
            capture = db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
            if capture is not None and capture["seal_json"] is not None:
                if capture["seal_json"] == facts.canonical:
                    return 200, capture_status(db, capture_id)  # type: ignore[return-value]
                raise ApiError(409, "seal_conflict", "a different seal is already stored for this capture")
            if capture is not None and (capture["device_id"] != seal.device_id or capture["source"] != seal.source):
                raise ApiError(409, "capture_identity_conflict", "device_id/source differ from this capture")
            path = vault.seal_path(seal.device_id, capture_id)
            stored = Vault.read_json(path)
            if stored is not None:  # durable seal without an index row
                if canonical_json(stored.get("body")) != facts.canonical:
                    raise ApiError(409, "seal_conflict", "a different seal is already stored for this capture")
                with db.tx() as conn:
                    index_seal(conn, capture_id, facts, float(stored["received_at"]))
                return 200, capture_status(db, capture_id)  # type: ignore[return-value]
            beyond = db.one("SELECT MAX(chunk_sequence) AS m FROM chunks WHERE capture_id=?", (capture_id,))
            if beyond["m"] is not None and beyond["m"] > seal.last_chunk_sequence:
                raise ApiError(409, "chunks_beyond_seal", "chunks above last_chunk_sequence are already stored")
            self._writable()
            now = self.clock()
            Vault.write_json(path, {"body": raw, "received_at": now}, pretty=False)
            try:
                with db.tx() as conn:
                    index_seal(conn, capture_id, facts, now)
            except BaseException:
                self._dirty.add((seal.device_id, capture_id))
                raise
        return 200, capture_status(db, capture_id)  # type: ignore[return-value]

    # -- events ----------------------------------------------------------------------------------

    def put_event(self, event_id: str, raw: Any) -> tuple[int, dict]:
        _check_uuid(event_id, "event_id")
        facts = validate_event(raw)
        with _lock:
            existing = self.db.one("SELECT body_json FROM events WHERE event_id=?", (event_id,))
            if existing is None and event_id in self._pending_events:
                body, received = self._pending_events[event_id]
                if body != facts.canonical:
                    raise ApiError(409, "event_conflict", "a different event is already stored under this id")
                with self.db.tx() as conn:
                    index_event(conn, event_id, facts, received)
                del self._pending_events[event_id]
                return 200, {"event_id": event_id, "stored": True, "duplicate": True}
            if existing is not None:
                if existing["body_json"] == facts.canonical:
                    return 200, {"event_id": event_id, "stored": True, "duplicate": True}
                raise ApiError(409, "event_conflict", "a different event is already stored under this id")
            self._writable()
            now = self.clock()
            Vault.append_jsonl(self.vault.events_path(now), {"event_id": event_id, "received_at": now, "body": raw})
            try:
                with self.db.tx() as conn:
                    index_event(conn, event_id, facts, now)
            except BaseException:
                self._pending_events[event_id] = (facts.canonical, now)
                raise
        return 201, {"event_id": event_id, "stored": True, "duplicate": False}


def capture_status(db: Database, capture_id: str) -> dict | None:
    capture = db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
    if capture is None:
        return None
    seqs = [r["chunk_sequence"] for r in db.query(
        "SELECT chunk_sequence FROM chunks WHERE capture_id=? ORDER BY chunk_sequence", (capture_id,)
    )]
    ranges: list[list[int]] = []
    for s in seqs:
        if ranges and s == ranges[-1][1] + 1:
            ranges[-1][1] = s
        else:
            ranges.append([s, s])
    return {
        "capture_id": capture_id,
        "source": capture["source"],
        "sealed": capture["seal_json"] is not None,
        "last_chunk_sequence": capture["last_chunk_sequence"],
        "received_ranges": ranges,
        "processed_through": capture["processed_through"],
    }


def seal_end_epoch(capture) -> float | None:
    """Monotonic end of a sealed capture (`capture_started_at + end_offset_us`), else `ended_at`."""
    if capture["seal_json"] is None:
        return None
    offset = capture["seal_end_offset_us"]
    if offset is not None and capture["capture_started_at"] is not None:
        return capture["capture_started_at"] + offset / 1e6
    return capture["ended_at"]
