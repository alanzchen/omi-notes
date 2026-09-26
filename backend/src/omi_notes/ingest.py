"""Phone → server ingest: chunks, seals, events, capture status (capture-format-v1.md, "HTTP API").

Ordering guarantee for chunks: validate → durable spool write (fsync) → ledger commit
(`synchronous=FULL`) → only then report success. Everything is idempotent by identity + content.
"""

from __future__ import annotations

import errno
import shutil
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, StrictBool, StrictInt, StrictStr, ValidationError

from .db import Database
from .envelope import EnvelopeError, parse_envelope
from .settings import Settings
from .spool import make_dirs_durable, store_chunk
from .util import UUID_RE, canonical_json, sha256_hex

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
    """Validated strictly (no string→number coercion): only the normalized values are persisted,
    while the raw body is kept solely for the immutability comparison."""

    model_config = ConfigDict(extra="allow")
    last_chunk_sequence: Annotated[StrictInt, Field(ge=-1)]
    reason: SealReason
    ended_at: IsoTime
    end_offset_us: Count | None = None
    device_id: Annotated[StrictStr, Field(min_length=1, max_length=128)]
    source: Literal["live_ble", "device_ring", "wav_replay"]
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


# -- chunks --------------------------------------------------------------------------------------


def put_chunk(
    db: Database, settings: Settings, capture_id: str, seq: int, body: bytes, sha_header: str | None
) -> tuple[int, dict]:
    _check_uuid(capture_id, "capture_id")
    if seq < 0:
        raise ApiError(422, "invalid_chunk_sequence", "chunk_sequence must be >= 0")
    if not sha_header or len(sha_header) != 64:
        raise ApiError(400, "missing_sha256", "X-Content-SHA256 header with a hex SHA-256 is required")
    digest = sha256_hex(body)
    if digest != sha_header.lower():
        raise ApiError(400, "checksum_mismatch", "body SHA-256 does not match X-Content-SHA256")

    def ok(status: int, duplicate: bool) -> tuple[int, dict]:
        return status, {
            "capture_id": capture_id,
            "chunk_sequence": seq,
            "sha256": digest,
            "stored": True,
            "duplicate": duplicate,
        }

    with _lock:
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
        header = env.header

        capture = db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
        started = header.capture_started_at.timestamp()
        if capture is not None:
            if capture["device_id"] != header.device_id or capture["source"] != header.source:
                raise ApiError(409, "capture_identity_conflict", "device_id/source differ from this capture")
            if capture["capture_started_at"] is not None and abs(capture["capture_started_at"] - started) > 0.0015:
                raise ApiError(409, "capture_identity_conflict", "capture_started_at differs from earlier chunks")
            if capture["last_chunk_sequence"] is not None and seq > capture["last_chunk_sequence"]:
                raise ApiError(409, "beyond_seal", "chunk_sequence is above the sealed last_chunk_sequence")

        _ensure_space(settings)
        try:
            path = store_chunk(settings.raw_dir, header.device_id, capture_id, seq, body)
        except OSError as exc:
            if exc.errno == errno.ENOSPC:
                raise ApiError(507, "storage_full", "server disk is full") from exc
            raise

        now = time.time()
        with db.tx() as conn:
            if capture is None:
                conn.execute(
                    "INSERT INTO captures (capture_id, device_id, source, created_at) VALUES (?,?,?,?)",
                    (capture_id, header.device_id, header.source, now),
                )
            conn.execute(
                """UPDATE captures SET payload_format=?, codec_id=?, capture_started_at=?,
                       offline_storage=COALESCE(?, offline_storage), device_name=COALESCE(?, device_name),
                       model_number=COALESCE(?, model_number), firmware_revision=COALESCE(?, firmware_revision),
                       hardware_revision=COALESCE(?, hardware_revision), timezone=COALESCE(?, timezone),
                       ring_dropped=COALESCE(?, ring_dropped)
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
                    capture_id,
                ),
            )
            conn.execute(
                """INSERT INTO chunks (capture_id, chunk_sequence, device_id, source, sha256, size, path,
                       received_at, start_epoch, end_epoch, start_offset_us, end_offset_us)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    capture_id,
                    seq,
                    header.device_id,
                    header.source,
                    digest,
                    len(body),
                    str(path),
                    now,
                    header.chunk_start_epoch,
                    header.chunk_end_epoch,
                    header.chunk_start_offset_us,
                    header.chunk_end_offset_us,
                ),
            )
            _touch_device(conn, header.device_id, now, header.device_name, header.model_number, header.firmware_revision)
    return ok(201, False)


def _ensure_space(settings: Settings) -> None:
    make_dirs_durable(settings.raw_dir)
    if shutil.disk_usage(settings.raw_dir).free < MIN_FREE_BYTES:
        raise ApiError(507, "storage_full", "server disk is nearly full")


def _touch_device(conn, device_id: str, now: float, name=None, model=None, firmware=None) -> None:
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


# -- seals ---------------------------------------------------------------------------------------


def put_seal(db: Database, capture_id: str, raw: Any) -> tuple[int, dict]:
    _check_uuid(capture_id, "capture_id")
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
    canonical = canonical_json(raw)

    with _lock:
        capture = db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
        if capture is not None:
            if capture["seal_json"] is not None:
                if capture["seal_json"] == canonical:
                    return 200, capture_status(db, capture_id)  # type: ignore[return-value]
                raise ApiError(409, "seal_conflict", "a different seal is already stored for this capture")
            if capture["device_id"] != seal.device_id or capture["source"] != seal.source:
                raise ApiError(409, "capture_identity_conflict", "device_id/source differ from this capture")
            beyond = db.one(
                "SELECT MAX(chunk_sequence) AS m FROM chunks WHERE capture_id=?", (capture_id,)
            )
            if beyond["m"] is not None and beyond["m"] > seal.last_chunk_sequence:
                raise ApiError(409, "chunks_beyond_seal", "chunks above last_chunk_sequence are already stored")
        now = time.time()
        with db.tx() as conn:
            if capture is None:
                conn.execute(
                    "INSERT INTO captures (capture_id, device_id, source, created_at) VALUES (?,?,?,?)",
                    (capture_id, seal.device_id, seal.source, now),
                )
            # Only sync_complete carries coverage evidence; app_recovered/sync_interrupted never do.
            conn.execute(
                """UPDATE captures SET seal_json=?, seal_reason=?, last_chunk_sequence=?, sealed_at=?,
                       ended_at=?, seal_end_offset_us=?, ring_covers_until=?, ring_generation=?,
                       ring_info_read_seq=?, ring_dropped=COALESCE(ring_dropped, ?)
                   WHERE capture_id=?""",
                (canonical, seal.reason, seal.last_chunk_sequence, now, ended_at, seal.end_offset_us, covers_until,
                 ring.generation, ring.info_read_seq, ring.dropped, capture_id),
            )  # fmt: skip
            _touch_device(conn, seal.device_id, now)
    return 200, capture_status(db, capture_id)  # type: ignore[return-value]


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


# -- events --------------------------------------------------------------------------------------


def put_event(db: Database, event_id: str, raw: Any) -> tuple[int, dict]:
    _check_uuid(event_id, "event_id")
    if not isinstance(raw, dict):
        raise ApiError(422, "invalid_body", "event body must be a JSON object")
    try:
        event = EventBody.model_validate(raw)
    except ValidationError as exc:
        raise ApiError(422, "invalid_body", str(exc.errors(include_url=False, include_input=False))) from exc
    at = _aware_epoch(event.at, "at")
    canonical = canonical_json(raw)
    code = event.data.get("code") if event.type == "button" else None
    if code is not None and not isinstance(code, int):
        raise ApiError(422, "invalid_body", "button data.code must be an integer")

    with _lock:
        existing = db.one("SELECT body_json FROM events WHERE event_id=?", (event_id,))
        if existing is not None:
            if existing["body_json"] == canonical:
                return 200, {"event_id": event_id, "stored": True, "duplicate": True}
            raise ApiError(409, "event_conflict", "a different event is already stored under this id")
        now = time.time()
        with db.tx() as conn:
            conn.execute(
                """INSERT INTO events (event_id, device_id, type, at, capture_id, offset_us, code, body_json, received_at)
                   VALUES (?,?,?,?,?,?,?,?,?)""",
                (event_id, event.device_id, event.type, at, event.capture_id, event.offset_us, code, canonical, now),
            )
            _touch_device(conn, event.device_id, now)
            if event.type == "heartbeat":
                data = event.data
                conn.execute(
                    """UPDATE devices SET heartbeat_json=?,
                           firmware_revision=COALESCE(?, firmware_revision),
                           model_number=COALESCE(?, model_number)
                       WHERE device_id=?""",
                    (
                        canonical_json({"at": at, **data}),
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
                    if (
                        isinstance(cap, str)
                        and UUID_RE.match(cap)
                        and isinstance(through, int)
                        and through >= 0
                        and isinstance(requires, int)
                    ):
                        conn.execute(
                            """INSERT INTO coverage (device_id, kind, capture_id, through_offset_us, requires_chunk, event_id)
                               VALUES (?,?,?,?,?,?)""",
                            (event.device_id, "heartbeat", cap, through, requires, event_id),
                        )
    return 201, {"event_id": event_id, "stored": True, "duplicate": False}
