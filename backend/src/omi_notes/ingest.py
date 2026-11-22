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
import logging
import os
import shutil
import sqlite3
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from collections.abc import Callable
from typing import Annotated, Any, Literal

import numpy as np
from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, StrictBool, StrictInt, StrictStr, ValidationError

from .audio import aac
from . import disk_alert
from .db import Database
from .envelope import EnvelopeError, EnvelopeHeader, parse_envelope
from .settings import Settings
from . import spool
from .spool import atomic_write_bytes, make_dirs_durable
from .util import UUID_RE, canonical_json, sha256_hex
from .vault import Vault

log = logging.getLogger(__name__)

# Below this much free space new audio is refused with 507 (the phone keeps it and retries), so SQLite, notes and the
# worker keep room to write: the index's WAL and checkpoints, transcripts, cached transcription requests and a burst of
# uploads fit in it. 256 MiB was not enough: on 2026-11-20 the disk filled and the worker's index writes failed.
MIN_FREE_BYTES = 2 * 1024 * 1024 * 1024
_lock = threading.Lock()
# AAC decodes (ffmpeg runs) at once for checks outside `_lock`: a resend burst can't take every core
UPLOAD_DECODES = 4
_decodes = threading.BoundedSemaphore(UPLOAD_DECODES)
PENDING_MAX = 10_000  # identities published in this process but not yet committed (DESIGN-05: refuse, never evict)
SAME_AUDIO_VERDICTS = 10_000  # remembered (capture, seq, sha256) comparisons; a stored chunk never changes


@dataclass
class ChunkPlan:
    """The decode one chunk upload needs before its locked commit (`Ingest.plan_chunk`), done by the API in its own
    bounded pool so decode-bound uploads never hold the shared request workers. `key` names a comparison, so
    simultaneous identical resends share one."""

    work: Callable[[], object] | None = None  # returns `decoded` (no key) or `same` (a comparison, keyed)
    key: tuple[str, int, str] | None = None
    decoded: bool | aac.AacError | None = None
    same: bool | _Unavailable | None = None


class _Unavailable:
    """A comparison that couldn't be made right now (a decode timed out, a file couldn't be read): neither the same
    nor different. Answered 503, never remembered (ASTRA-20261111-IT3-01: a 409 makes the phone quarantine it)."""

    def __repr__(self) -> str:
        return "COMPARISON_UNAVAILABLE"


COMPARISON_UNAVAILABLE = _Unavailable()


class NeedsComparison(Exception):
    """`put_chunk` with a plan found other bytes under the identity that the plan didn't compare (a writer stored
    them after planning): plan again and admit that comparison, rather than decode on a shared request worker."""


class _CompareFirst(Exception):
    """Other bytes under a stored identity whose comparison isn't known yet: done outside `_lock`, then again."""


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


def receipt_time(vault: Vault, device_id: str, capture_id: str, seq: int, digest: str) -> float | None:
    """The first receipt time for exactly these bytes (a line for other bytes never supplies one; DESIGN-03)."""
    for line in Vault.read_jsonl(vault.receipts_path(device_id, capture_id)):
        if line.get("seq") == seq and line.get("sha256") == digest and isinstance(line.get("received_at"), (int, float)):
            return float(line["received_at"])
    return None


def tombstone_header(tomb: dict) -> EnvelopeHeader:
    return EnvelopeHeader.model_validate(tomb["header"])


# -- ingest ----------------------------------------------------------------------------------------


def durable_existing(path, vault: Vault) -> None:
    """A file found on disk counts as stored only once it and its whole directory chain to the vault root are synced
    now: a matching hash proves its content, not that it was durably published (a crash or a failed directory sync
    after the rename, on this or an earlier attempt, may have left it only in the page cache; ASTRA-20261121-IT3-01,
    IT5-01, ASTRA-20261122-DESIGN-01/02). Raises OSError; nothing is rewritten."""
    vault.confirm(path)


def _disk_full_error(exc: BaseException | None) -> bool:
    """ENOSPC or SQLITE_FULL, by code (not message), on the error or what it was raised from/during."""
    seen = 0
    while exc is not None and seen < 5:
        if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
            return True
        if isinstance(exc, sqlite3.Error) and (getattr(exc, "sqlite_errorcode", None) or 0) & 0xFF == sqlite3.SQLITE_FULL:
            return True
        exc, seen = exc.__cause__ or exc.__context__, seen + 1
    return False


class Ingest:
    """HTTP ingest against one vault + index. One process-wide lock serializes identity checks."""

    def __init__(self, db: Database, vault: Vault, settings: Settings, *, read_only: callable = lambda: None,
                 clock=time.time) -> None:  # fmt: skip
        self.db = db
        self.vault = vault
        self.settings = settings
        self.read_only = read_only  # () -> reason or None
        self.clock = clock  # receipt times (injectable for tests)
        # Identities whose publication started in this process and isn't committed yet: (capture, seq, digest) ->
        # [receipt time chosen before any file was written, whether that receipt line is confirmed]. A retry reuses
        # the time; dropped only after the outer COMMIT (DESIGN-03). Bounded: refuse new work beyond PENDING_MAX.
        self._pending: dict[tuple[str, int, str], list] = {}
        # Disk evidence for /v1/status (DESIGN-07/08): a local latch set before the alert file is even tried (it may be
        # unwritable on a full disk), cleared only by a witnessed publication begun after the last local failure.
        self.down_latch: float | None = None
        self._failures = 0
        self.healthy_at: float | None = None  # this process measured every volume with room after a real publication
        self._pending_events: dict[str, tuple[str, float]] = {}
        # (capture_id, seq, sha256 of other bytes) -> same audio as the stored chunk
        self._verdicts: dict[tuple[str, int, str], bool] = {}

    def _writable(self) -> None:
        reason = self.read_only()
        if reason:
            raise ApiError(503, "vault_read_only", reason)

    def _resolve_saved_seal(self, header, capture_id: str, capture):
        """The capture's one saved seal.json, if its index row is missing: authoritative for chunk bounds, so it is
        validated, confirmed and indexed before this chunk's bounds are decided (DESIGN-04). Unreadable, malformed or
        unconfirmable is unresolved (retryable), never "no seal"."""
        path = self.vault.seal_path(header.device_id, capture_id)
        if not path.exists():  # one stat, only for an unsealed capture
            return capture
        try:
            stored = Vault.read_json(path)
            facts = validate_seal(stored["body"])
            received = float(stored["received_at"])
        except (OSError, ValueError, KeyError, TypeError, ApiError) as exc:
            raise ApiError(503, "seal_unresolved", f"this capture's saved seal can't be read right now ({exc}); send it again") from exc
        if facts.seal.device_id != header.device_id or facts.seal.source != header.source:
            raise ApiError(409, "capture_identity_conflict", "device_id/source differ from this capture's seal")
        durable_existing(path, self.vault)
        with self.db.tx() as conn:
            index_seal(conn, capture_id, facts, received)
        return self.db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))

    def _evidence_snapshot(self) -> tuple[int, int]:
        try:
            return disk_alert.revision(self.settings.logs_dir), self._failures
        except Exception:
            return -1, self._failures

    def _witness(self, snapshot: tuple[int, int]) -> None:
        """After a durable publication and its outer COMMIT (never a duplicate 200): recovery evidence, if nothing failed
        since `snapshot`. Never changes the answer."""
        try:
            rev, failures = snapshot
            if rev < 0:
                return
            ok = disk_alert.witness(self.settings.logs_dir, [self.vault.raw, self.db.path.parent], floor_bytes=MIN_FREE_BYTES,
                                    now=self.clock(), since_revision=rev)  # fmt: skip
            if ok is True and failures == self._failures:
                self.down_latch = None
                self.healthy_at = self.clock()
        except Exception:
            log.exception("disk evidence after a publication failed")

    def _note_high_water(self, capture_id: str, seq: int) -> None:
        from .rebuild import recovery_state

        hw = recovery_state(self.vault).high_water
        if seq > hw.get(capture_id, -1):
            hw[capture_id] = seq

    # -- chunks ----------------------------------------------------------------------------------

    def plan_chunk(self, capture_id: str, seq: int, body: bytes, sha_header: str | None) -> ChunkPlan:
        """Cheap (one indexed lookup, an envelope parse): which decode `put_chunk` will need, as work to run first.
        Nothing for a request `put_chunk` will refuse anyway, an identical resend or a remembered comparison."""
        digest = sha256_hex(body)
        if not sha_header or digest != sha_header.lower() or seq < 0 or not UUID_RE.fullmatch(capture_id):
            return ChunkPlan()
        row = self.db.one("SELECT sha256 FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq))
        plan = ChunkPlan()
        if row is None:
            try:
                aac_part = parse_envelope(body, capture_id=capture_id, chunk_sequence=seq).header.payload_format == "aac_m4a_v1"
            except EnvelopeError:
                return plan
            if aac_part:
                plan.work = lambda: self._check_aac(capture_id, seq, body)
        elif row["sha256"] != digest and (capture_id, seq, digest) not in self._verdicts:
            plan.work, plan.key = (lambda: self._compare(capture_id, seq, body, digest)), (capture_id, seq, digest)
        return plan

    def put_chunk(self, capture_id: str, seq: int, body: bytes, sha_header: str | None,
                  plan: ChunkPlan | None = None) -> tuple[int, dict]:  # fmt: skip
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

        # Decoding is the slow part (ffmpeg, 0.15-0.3 s for a 60 s AAC part) and needs no lock: a new AAC part
        # is checked before taking it, and other bytes under a stored identity are compared outside it.
        # With a `plan`, the API already ran that decode in its own pool; otherwise (direct callers) it runs here.
        decoded: bool | aac.AacError | None = plan.decoded if plan is not None else None
        if plan is None and self.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq)) is None:
            decoded = self._check_aac(capture_id, seq, body)
        try:
            try:
                return self._put_chunk_locked(capture_id, seq, body, digest, ok, decoded, plan.same if plan is not None else None)
            except _CompareFirst:
                if plan is not None:
                    raise NeedsComparison from None
                same = self._compare(capture_id, seq, body, digest)
                return self._put_chunk_locked(capture_id, seq, body, digest, ok, decoded, same)
        except (ApiError, NeedsComparison):
            raise
        except Exception as exc:
            # a full disk anywhere on the way (recovering an orphan, adopting it, the index) is 507: the phone keeps the
            # part and sends it again; nothing was acknowledged (ASTRA-20261121-IT1-01)
            if _disk_full_error(exc):
                self._disk_full(f"storing a chunk failed: {exc}")
                raise ApiError(507, "storage_full", "server disk is full") from exc
            raise

    @staticmethod
    def _check_aac(capture_id: str, seq: int, body: bytes) -> bool | aac.AacError | None:
        """Whether a new AAC part decodes (True, or the error); None when it isn't one (or not an envelope)."""
        try:
            env = parse_envelope(body, capture_id=capture_id, chunk_sequence=seq)
        except EnvelopeError:
            return None
        if env.header.payload_format != "aac_m4a_v1":
            return None
        try:
            with _decodes:
                aac.decode(env.payload, env.header.record_count)
        except aac.AacError as exc:
            return exc
        return True

    def _put_chunk_locked(self, capture_id: str, seq: int, body: bytes, digest: str, ok, decoded,
                          same: bool | _Unavailable | None = None) -> tuple[int, dict]:  # fmt: skip
        db, vault = self.db, self.vault
        with _lock:
            # Only this identity: a file left without its row is adopted below (`_adopt_orphan`, after syncing that one
            # file). The capture's other orphans are not this request's work; the startup sweep (and a seal) indexes them
            # (ASTRA-20261121-IT5-02: a dirty capture's PUT synced every orphan under the global lock).
            existing = db.one("SELECT sha256 FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq))
            if existing is not None:
                if existing["sha256"] == digest:
                    return ok(200, True)
                return ok(200, True) if self._same_audio_again(capture_id, seq, body, digest, same) else self._conflict()

            try:
                env = parse_envelope(body, capture_id=capture_id, chunk_sequence=seq)
            except EnvelopeError as exc:
                raise ApiError(422, "invalid_envelope", str(exc)) from exc
            if env.header.payload_format == "aac_m4a_v1":
                # refuse a file we can't decode before acknowledging it (the phone keeps refused ones)
                if decoded is not True and not isinstance(decoded, aac.AacError):  # not checked before the lock
                    try:
                        aac.decode(env.payload, env.header.record_count)
                        decoded = True
                    except aac.AacError as exc:
                        decoded = exc
                # a decoder that couldn't run says nothing about the audio: send it again (the phone retries a 503;
                # it quarantines a 422), never "invalid"
                if isinstance(decoded, aac.AacUnavailable):
                    raise ApiError(503, "decoder_unavailable", f"the server couldn't check this audio right now ({decoded}); send it again") from decoded
                if isinstance(decoded, aac.AacError):
                    raise ApiError(422, "invalid_audio", str(decoded)) from decoded
            header = env.header

            capture = db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
            started = header.capture_started_at.timestamp()
            if capture is not None:
                if capture["device_id"] != header.device_id or capture["source"] != header.source:
                    raise ApiError(409, "capture_identity_conflict", "device_id/source differ from this capture")
                if capture["capture_started_at"] is not None and abs(capture["capture_started_at"] - started) > 0.0015:
                    raise ApiError(409, "capture_identity_conflict", "capture_started_at differs from earlier chunks")

            if capture is None or capture["seal_json"] is None:
                capture = self._resolve_saved_seal(header, capture_id, capture)
            # the seal bounds every way in, adoption of an existing file included (an orphan above it is kept, not used)
            if capture is not None and capture["last_chunk_sequence"] is not None and seq > capture["last_chunk_sequence"]:
                raise ApiError(409, "beyond_seal", "chunk_sequence is above the sealed last_chunk_sequence")
            path = vault.chunk_path(header.device_id, capture_id, seq)
            tomb_path = path.with_suffix(".gone")
            if path.exists() or tomb_path.exists():
                return ok(*self._adopt_orphan(env, digest, len(body), path, tomb_path))

            self._writable()
            snapshot = self._evidence_snapshot()
            self._ensure_space()
            key = (capture_id, seq, digest)
            if key not in self._pending and len(self._pending) >= PENDING_MAX:
                raise ApiError(503, "recovery_backlog", "too many uploads are waiting to be confirmed; send it again later")
            pending = self._pending.setdefault(key, [self.clock(), False])  # the receipt time, chosen before writing
            try:
                vault.publish_bytes(path, body)  # file + chain to the vault root, never replacing a file
            except OSError as exc:
                if path.exists():
                    self._note_high_water(capture_id, seq)  # on disk, unconfirmed: a seal must not end before it
                if exc.errno == errno.ENOSPC:
                    self._disk_full("a chunk write hit ENOSPC")
                    raise ApiError(507, "storage_full", "server disk is full") from exc
                raise
            self._note_high_water(capture_id, seq)
            now = pending[0]
            try:
                vault.append_confirmed(vault.receipts_path(header.device_id, capture_id),
                                       {"seq": seq, "sha256": digest, "received_at": now})  # fmt: skip
                pending[1] = True
                with db.tx() as conn:
                    index_chunk(conn, header, digest=digest, size=len(body), path=vault.relpath(path), received_at=now,
                                ring=ring_record_hashes(env))  # fmt: skip
            except BaseException as exc:
                # the file is durable but not indexed (an orphan a retry with the same bytes adopts, with this same
                # receipt time): a full disk here is 507 like any other, so the phone keeps the part (2026-11-21)
                if _disk_full_error(exc):
                    self._disk_full(f"storing a chunk's receipt/index failed: {exc}")
                    raise ApiError(507, "storage_full", "server disk is full") from exc
                raise
            self._pending.pop(key, None)
            self._witness(snapshot)  # after the outer COMMIT
        return ok(201, False)

    @staticmethod
    def _conflict():
        raise ApiError(409, "chunk_conflict", "different content is already stored under this identity")

    def _same_audio_again(self, capture_id: str, seq: int, body: bytes, digest: str,
                          same: bool | _Unavailable | None = None) -> bool:  # fmt: skip
        """Other bytes under a stored chunk's identity (caller holds the lock). They are always kept, beside the
        stored chunk in `alternates/` (vault first; nothing is overwritten or dropped). True when they are the
        same audio encoded another way, e.g. a Watch part stored as PCM by an old phone build and relayed
        again as the Watch's own AAC after its acknowledgement was lost: same timing, and the decoded audio
        matches. Then the stored (lossless) chunk stays the chunk and the sender is told it is stored."""
        row = self.db.one("SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq))
        try:
            env = parse_envelope(body, capture_id=capture_id, chunk_sequence=seq)
        except EnvelopeError:
            return False
        if row is None:
            return False
        key = (capture_id, seq, digest)
        if same is None:
            same = self._verdicts.get(key)
        if same is None and (self.vault.root / row["path"]).exists():
            raise _CompareFirst  # nothing written yet: `put_chunk` compares outside the lock and comes back
        stored_path = self.vault.root / row["path"]
        alternate = stored_path.parent / "alternates" / f"{seq}-{digest[:16]}.omnc"
        if alternate.exists() and sha256_hex(alternate.read_bytes()) != digest:  # damaged: these bytes again, durably
            log.warning("chunk %s/%d: alternate copy %s was damaged; writing it again", capture_id, seq, alternate.name)
            self._writable()
            atomic_write_bytes(alternate, body)  # a damaged non-canonical copy: replaced, then confirmed below
        if alternate.exists():
            durable_existing(alternate, self.vault)  # a copy found on disk is kept only once its chain is synced now
        else:
            self._writable()
            self._ensure_space()
            self.vault.publish_bytes(alternate, body)
            self.vault.append_confirmed(self.vault.receipts_path(env.header.device_id, capture_id),
                                        {"alternate_of_seq": seq, "sha256": digest, "received_at": self.clock()})  # fmt: skip
        if not stored_path.exists():  # audio deleted before 2026-11-08: nothing to compare with
            return False
        if same is COMPARISON_UNAVAILABLE:  # the copy is kept above; the phone keeps its own and sends it again
            raise ApiError(503, "comparison_unavailable",
                           "the server couldn't compare this copy with the stored one right now; send it again")
        return bool(same)

    def _compare(self, capture_id: str, seq: int, body: bytes, digest: str) -> bool | _Unavailable:
        """Whether other bytes are the same audio as the chunk stored under their identity, compared without
        `_lock` (that chunk is never overwritten). The verdict is remembered, so a resend of the same bytes is a
        lookup however often it comes. A comparison that couldn't be made right now (a decode error or timeout, an
        unreadable file) is `COMPARISON_UNAVAILABLE`: a 503, not remembered, tried again next time. Bytes that
        can't be compared at all (not an envelope, no comparison for their format) are "not the same"."""
        row = self.db.one("SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq))
        if row is None:
            return False
        try:
            env = parse_envelope(body, capture_id=capture_id, chunk_sequence=seq)
            stored = parse_envelope((self.vault.root / row["path"]).read_bytes(), capture_id=capture_id, chunk_sequence=seq)
            with _decodes:
                same = same_audio(stored, env)
        except (OSError, aac.AacError) as exc:
            log.warning("chunk %s/%d: could not compare a second copy with the stored one now: %s", capture_id, seq, exc)
            return COMPARISON_UNAVAILABLE
        except (EnvelopeError, ValueError) as exc:
            log.warning("chunk %s/%d: a second copy can't be compared with the stored one: %s", capture_id, seq, exc)
            return False
        log.warning("chunk %s/%d: other bytes under a stored identity (%s → %s): %s", capture_id, seq,
                    stored.header.payload_format, env.header.payload_format, "same audio" if same else "different audio")  # fmt: skip
        with _lock:
            if len(self._verdicts) >= SAME_AUDIO_VERDICTS:
                self._verdicts.pop(next(iter(self._verdicts)))
            self._verdicts[(capture_id, seq, digest)] = same
        return same

    def _adopt_orphan(self, env, digest: str, size: int, path, tomb_path) -> tuple[int, bool]:
        """A durable file for this identity exists without an index row: same bytes → index it
        (200), different bytes → 409. Never overwritten."""
        header = env.header
        snapshot = self._evidence_snapshot()
        if path.exists():
            data = path.read_bytes()
            if sha256_hex(data) != digest:
                raise ApiError(409, "chunk_conflict", "different content is already stored under this identity")
            deleted = False
            durable_existing(path, self.vault)  # before any receipt, row or 2xx (ENOSPC -> 507 in put_chunk)
        else:
            tomb = json.loads(tomb_path.read_text())
            if tomb.get("sha256") != digest:
                raise ApiError(409, "chunk_conflict", "different content was stored (and expired) under this identity")
            deleted = True
            durable_existing(tomb_path, self.vault)  # the actual .gone, not the missing .omnc
            evidence = self.vault.capture_json_path(header.device_id, header.capture_id)
            if evidence.exists():
                durable_existing(evidence, self.vault)  # the legacy coverage facts it brings back
        from .rebuild import UNREADABLE, apply_capture_evidence, recovery_state

        ids = (header.device_id, header.capture_id)
        key = (header.capture_id, header.chunk_sequence, digest)
        receipts = self.vault.receipts_path(*ids)
        state = recovery_state(self.vault)
        pending = self._pending.get(key)
        if pending is None:
            # not published by this process: only the startup sweep's prepared facts may say when it arrived; nothing
            # here scans the capture's receipts or evidence (DESIGN-03)
            prepared = state.receipts.get(ids)
            if prepared is None:
                raise ApiError(503, "unresolved_identity",
                               "this part's earlier copy can't be checked by this server process yet; send it again later")
            line = prepared.get((header.chunk_sequence, digest))
            pending = self._pending.setdefault(key, [line if line is not None else self.clock(), line is not None])
        evidence = None
        if deleted:
            evidence = state.evidence.get(ids)
            if evidence is UNREADABLE:
                raise ApiError(503, "unresolved_identity", "this capture's evidence can't be read right now; send it again later")
        received = pending[0]
        if pending[1]:
            durable_existing(receipts, self.vault)  # a readable earlier append may have failed its sync
        else:
            self._writable()
            self.vault.append_confirmed(receipts, {"seq": header.chunk_sequence, "sha256": digest, "received_at": received})
            pending[1] = True
        with self.db.tx() as conn:
            index_chunk(conn, header, digest=digest, size=size, path=self.vault.relpath(path), received_at=received,
                        raw_deleted=deleted, ring=ring_record_hashes(env))  # fmt: skip
            if deleted:
                apply_capture_evidence(conn, self.vault, *ids, only_seq=header.chunk_sequence, evidence=evidence or {})
        self._pending.pop(key, None)
        self._witness(snapshot)  # a real publication and COMMIT (not the duplicate fast path)
        return 200, True

    def _ensure_space(self) -> None:
        make_dirs_durable(self.vault.raw)
        free = shutil.disk_usage(self.vault.raw).free
        if free < MIN_FREE_BYTES:
            self._disk_full("free space below the upload floor", free, kind="space")
            raise ApiError(507, "storage_full", "server disk is nearly full")

    def _disk_full(self, reason: str, free: int | None = None, kind: str = "write") -> None:
        """Note the alert; never let the alert itself change the answer (ASTRA-20261121-IT1-02). The local latch first:
        the alert file may be exactly what can't be written."""
        self._failures += 1
        if self.down_latch is None:
            self.down_latch = self.clock()
        self.healthy_at = None
        try:
            if free is None:
                free = shutil.disk_usage(self.vault.raw).free
            disk_alert.note_down(self.settings.logs_dir, free_bytes=free, floor_bytes=MIN_FREE_BYTES, reason=reason,
                                 now=self.clock(), kind=kind)  # fmt: skip
        except Exception:
            log.exception("couldn't note the disk alert")

    # -- seals -----------------------------------------------------------------------------------

    def put_seal(self, capture_id: str, raw: Any) -> tuple[int, dict]:
        _check_uuid(capture_id, "capture_id")
        facts = validate_seal(raw)
        seal = facts.seal
        db, vault = self.db, self.vault
        with _lock:
            # no capture sweep here (DESIGN-04): files without rows are bounded by the high-water mark below
            capture = db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
            if capture is not None and capture["seal_json"] is not None:
                if capture["seal_json"] == facts.canonical:
                    return 200, capture_status(db, capture_id)  # type: ignore[return-value]
                raise ApiError(409, "seal_conflict", "a different seal is already stored for this capture")
            if capture is not None and (capture["device_id"] != seal.device_id or capture["source"] != seal.source):
                raise ApiError(409, "capture_identity_conflict", "device_id/source differ from this capture")
            path = vault.seal_path(seal.device_id, capture_id)
            stored = Vault.read_json(path)
            if stored is not None:  # a seal file without an index row: trusted once its chain is confirmed
                if canonical_json(stored.get("body")) != facts.canonical:
                    raise ApiError(409, "seal_conflict", "a different seal is already stored for this capture")
                durable_existing(path, vault)
                with db.tx() as conn:
                    index_seal(conn, capture_id, facts, float(stored["received_at"]))
                return 200, capture_status(db, capture_id)  # type: ignore[return-value]
            from .rebuild import recovery_state

            beyond = db.one("SELECT MAX(chunk_sequence) AS m FROM chunks WHERE capture_id=?", (capture_id,))["m"]
            on_disk = recovery_state(vault).high_water.get(capture_id)  # files without rows (startup + this process)
            highest = max(x for x in (beyond, on_disk, -1) if x is not None)
            if highest > seal.last_chunk_sequence:
                raise ApiError(409, "chunks_beyond_seal", "chunks above last_chunk_sequence are already stored")
            self._writable()
            now = self.clock()
            Vault.write_json(path, {"body": raw, "received_at": now}, pretty=False)
            vault.confirm(path)
            with db.tx() as conn:  # a failure leaves the confirmed seal.json: the next chunk or seal PUT indexes it
                index_seal(conn, capture_id, facts, now)
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


SAME_AUDIO_CORRELATION = 0.9  # decoded copies of one recording (lossless vs 32 kbit/s AAC) correlate well above this
SAME_AUDIO_MAX_LAG = 2400  # samples (0.15 s): codec priming and padding
SAME_AUDIO_WINDOW = 16000  # every aligned second with sound must match on its own...
SAME_AUDIO_WINDOW_CORRELATION = 0.8  # ... at least this well (32 kbit/s AAC of the same second is far above)


def _samples(env) -> np.ndarray:
    if env.header.payload_format == "aac_m4a_v1":
        return aac.decode(env.payload, env.header.record_count).astype(np.float64)
    if env.header.payload_format == "pcm16le_v1":
        return np.frombuffer(env.payload, dtype="<i2").astype(np.float64)
    raise ValueError(f"no audio comparison for {env.header.payload_format}")


def same_audio(a, b) -> bool:
    """Whether two envelopes under one identity hold the same recording: same device, source, start and timing
    (within 20 ms / 100 ms), and decoded audio of the same length whose best alignment within 0.15 s
    correlates at least SAME_AUDIO_CORRELATION (two silent copies are the same)."""
    ha, hb = a.header, b.header
    if (ha.device_id, ha.source) != (hb.device_id, hb.source) or abs((ha.capture_started_at - hb.capture_started_at).total_seconds()) > 0.0015:
        return False
    if abs(ha.chunk_start_offset_us - hb.chunk_start_offset_us) > 20_000 or abs(ha.chunk_end_offset_us - hb.chunk_end_offset_us) > 100_000:
        return False
    x, y = _samples(a), _samples(b)
    if abs(len(x) - len(y)) > 1600:
        return False
    n = min(len(x), len(y))
    longer = x if len(x) > n else y
    x, y = x[:n] - x[:n].mean(), y[:n] - y[:n].mean()
    ex, ey = float(np.sqrt((x**2).mean())), float(np.sqrt((y**2).mean()))
    # what the longer copy has past the shorter one's end is cut off below: it may only be quiet padding
    tail = longer[n:] - longer[:n].mean()
    if len(tail) and float(np.sqrt((tail**2).mean())) >= max(1.0, 0.05 * max(ex, ey)):
        return False
    if ex < 1.0 and ey < 1.0:
        return True
    if ex < 1.0 or ey < 1.0:
        return False
    size = 1 << (2 * n - 1).bit_length()
    corr = np.fft.irfft(np.fft.rfft(x, size) * np.conj(np.fft.rfft(y, size)), size)
    lags = np.concatenate([corr[: SAME_AUDIO_MAX_LAG + 1], corr[-SAME_AUDIO_MAX_LAG:]])
    if float(lags.max()) / (n * ex * ey) < SAME_AUDIO_CORRELATION:
        return False
    # the whole can match while a part differs (two replaced seconds of sixty still correlate 0.97 overall):
    # aligned, every second where either copy has sound must match too
    best = int(np.argmax(lags))
    lag = best if best <= SAME_AUDIO_MAX_LAG else best - len(lags)
    xa, ya = (x[lag:], y[: n - lag]) if lag >= 0 else (x[: n + lag], y[-lag:])
    floor = 0.05 * max(ex, ey)
    # what the alignment trims off either copy's edges may only be codec padding: quiet
    edges = (x[:lag], y[n - lag :]) if lag > 0 else (y[:-lag], x[n + lag :]) if lag < 0 else ()
    if any(len(e) and float(np.sqrt((e**2).mean())) >= floor for e in edges):
        return False
    # every aligned window, the last partial one too (a tail under 0.1 s joins the window before it)
    bounds = list(range(0, len(xa), SAME_AUDIO_WINDOW)) + [len(xa)]
    if len(bounds) > 2 and bounds[-1] - bounds[-2] < SAME_AUDIO_WINDOW // 10:
        bounds.pop(-2)
    for a, b in zip(bounds, bounds[1:], strict=False):
        wx, wy = xa[a:b], ya[a:b]
        rx, ry = float(np.sqrt((wx**2).mean())), float(np.sqrt((wy**2).mean()))
        if rx < floor and ry < floor:
            continue
        if min(rx, ry) < 0.5 * max(rx, ry) or float(wx @ wy) / (len(wx) * rx * ry) < SAME_AUDIO_WINDOW_CORRELATION:
            return False
    return True
