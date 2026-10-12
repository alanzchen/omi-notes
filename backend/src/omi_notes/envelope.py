"""OMINOTE1 capture envelope: parse, validate, build. Spec: docs/capture-format-v1.md."""

from __future__ import annotations

import json
import struct
import zlib
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

MAGIC = b"OMINOTE1"
MAX_HEADER_BYTES = 16 * 1024
MAX_BODY_BYTES = 8 * 1024 * 1024
RING_RECORD_SIZE = 444

OPUS_CODECS = {20: 160, 21: 320}  # codec id -> samples per frame at 16 kHz
FLAG_SESSION_START = 0x01

Source = Literal["live_ble", "device_ring", "wav_replay", "watch_mic"]
PayloadFormat = Literal["ble_notifications_v1", "ring_records_v1", "pcm16le_v1"]

_SOURCE_FORMAT = {
    "live_ble": "ble_notifications_v1",
    "device_ring": "ring_records_v1",
    "wav_replay": "pcm16le_v1",
    "watch_mic": "pcm16le_v1",
}


class EnvelopeError(ValueError):
    """The body is not a valid envelope (HTTP 422)."""


class RingInfo(BaseModel):
    model_config = ConfigDict(extra="ignore")
    first_sequence: int = Field(ge=0)
    record_size: int = RING_RECORD_SIZE
    read_seq: int | None = None
    write_seq: int | None = None
    dropped: int | None = None


class EnvelopeHeader(BaseModel):
    model_config = ConfigDict(extra="ignore")

    schema_version: Literal[1]
    capture_id: str
    chunk_sequence: int = Field(ge=0)
    device_id: str = Field(min_length=1, max_length=128)
    device_name: str | None = None
    model_number: str | None = None
    firmware_revision: str | None = None
    hardware_revision: str | None = None
    source: Source
    payload_format: PayloadFormat
    codec_id: int
    sample_rate: Literal[16000]
    channels: Literal[1]
    capture_started_at: datetime
    chunk_start_offset_us: int = Field(ge=0)
    chunk_end_offset_us: int = Field(ge=0)
    clock_quality: Literal["phone_anchored", "device_seconds", "unknown"] = "unknown"
    timezone: str | None = None
    record_count: int = Field(ge=0)
    payload_bytes: int = Field(ge=0)
    offline_storage: bool | None = None
    ring: RingInfo | None = None
    app_version: str | None = None

    @model_validator(mode="after")
    def _consistent(self) -> EnvelopeHeader:
        if _SOURCE_FORMAT[self.source] != self.payload_format:
            raise ValueError(f"source {self.source} requires payload_format {_SOURCE_FORMAT[self.source]}")
        if self.payload_format == "pcm16le_v1":
            if self.codec_id != 0:
                raise ValueError("pcm16le_v1 requires codec_id 0")
        elif self.codec_id not in OPUS_CODECS:
            raise ValueError(f"unsupported codec_id {self.codec_id} (v1 supports Opus 20 and 21)")
        if self.payload_format == "ring_records_v1":
            if self.ring is None:
                raise ValueError("ring_records_v1 requires ring")
            if self.ring.record_size != RING_RECORD_SIZE:
                raise ValueError(f"unsupported ring record_size {self.ring.record_size}")
        if self.capture_started_at.tzinfo is None:
            raise ValueError("capture_started_at must include a timezone (use Z)")
        if self.chunk_end_offset_us < self.chunk_start_offset_us:
            raise ValueError("chunk_end_offset_us < chunk_start_offset_us")
        if self.chunk_end_offset_us - self.chunk_start_offset_us >= 2**32:
            raise ValueError("chunk spans more than 4294 s")
        return self

    @property
    def frame_samples(self) -> int:
        return OPUS_CODECS.get(self.codec_id, 0)

    @property
    def chunk_start_epoch(self) -> float:
        return self.capture_started_at.timestamp() + self.chunk_start_offset_us / 1e6

    @property
    def chunk_end_epoch(self) -> float:
        return self.capture_started_at.timestamp() + self.chunk_end_offset_us / 1e6


@dataclass(frozen=True)
class BleRecord:
    t_offset_us: int
    flags: int
    data: bytes

    @property
    def session_start(self) -> bool:
        return bool(self.flags & FLAG_SESSION_START)


@dataclass(frozen=True)
class Envelope:
    header: EnvelopeHeader
    payload: bytes

    def ble_records(self) -> list[BleRecord]:
        return parse_ble_records(self.payload, self.header.record_count)

    def ring_records(self) -> list[bytes]:
        size = self.header.ring.record_size if self.header.ring else RING_RECORD_SIZE
        return [self.payload[i : i + size] for i in range(0, len(self.payload), size)]


def parse_envelope(body: bytes, *, capture_id: str | None = None, chunk_sequence: int | None = None) -> Envelope:
    if len(body) > MAX_BODY_BYTES:
        raise EnvelopeError(f"body exceeds {MAX_BODY_BYTES} bytes")
    if len(body) < 12 or body[:8] != MAGIC:
        raise EnvelopeError("bad magic")
    (header_len,) = struct.unpack_from("<I", body, 8)
    if header_len == 0 or header_len > MAX_HEADER_BYTES:
        raise EnvelopeError(f"bad header_len {header_len}")
    if 12 + header_len > len(body):
        raise EnvelopeError("truncated header")
    try:
        raw = json.loads(body[12 : 12 + header_len].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EnvelopeError(f"header is not JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise EnvelopeError("header is not a JSON object")
    try:
        header = EnvelopeHeader.model_validate(raw)
    except ValidationError as exc:
        raise EnvelopeError(f"invalid header: {exc.errors(include_url=False)}") from exc

    payload = body[12 + header_len :]
    if len(payload) != header.payload_bytes:
        raise EnvelopeError(f"payload is {len(payload)} bytes, header says {header.payload_bytes}")
    if capture_id is not None and header.capture_id != capture_id:
        raise EnvelopeError("capture_id does not match URL")
    if chunk_sequence is not None and header.chunk_sequence != chunk_sequence:
        raise EnvelopeError("chunk_sequence does not match URL")

    env = Envelope(header=header, payload=payload)
    fmt = header.payload_format
    if fmt == "ble_notifications_v1":
        records = env.ble_records()  # validates framing + CRCs
        duration = header.chunk_end_offset_us - header.chunk_start_offset_us
        previous = 0
        for index, record in enumerate(records):
            if record.t_offset_us < previous:
                raise EnvelopeError(f"record {index}: t_offset_us goes backwards")
            if record.t_offset_us > duration:
                raise EnvelopeError(f"record {index}: t_offset_us is past the chunk end")
            previous = record.t_offset_us
    elif fmt == "ring_records_v1":
        size = header.ring.record_size  # type: ignore[union-attr]
        if len(payload) != header.record_count * size:
            raise EnvelopeError("ring payload length != record_count * record_size")
    elif fmt == "pcm16le_v1":
        if len(payload) != 2 * header.record_count:
            raise EnvelopeError("pcm payload length != 2 * record_count")
    return env


def parse_ble_records(payload: bytes, expected_count: int | None = None) -> list[BleRecord]:
    records: list[BleRecord] = []
    off = 0
    n = len(payload)
    while off < n:
        if off + 7 > n:
            raise EnvelopeError(f"truncated record header at byte {off}")
        t_offset_us, length, flags = struct.unpack_from("<IHB", payload, off)
        end = off + 7 + length
        if end + 4 > n:
            raise EnvelopeError(f"truncated record at byte {off}")
        (crc,) = struct.unpack_from("<I", payload, end)
        if zlib.crc32(payload[off:end]) != crc:
            raise EnvelopeError(f"record CRC mismatch at byte {off}")
        records.append(BleRecord(t_offset_us, flags, bytes(payload[off + 7 : end])))
        off = end + 4
    if expected_count is not None and len(records) != expected_count:
        raise EnvelopeError(f"{len(records)} records, header says {expected_count}")
    return records


def encode_ble_record(t_offset_us: int, data: bytes, flags: int = 0) -> bytes:
    head = struct.pack("<IHB", t_offset_us, len(data), flags) + data
    return head + struct.pack("<I", zlib.crc32(head))


def build_envelope(header: dict, payload: bytes) -> bytes:
    """Serialize an envelope. `payload_bytes` is filled in automatically."""
    header = dict(header)
    header["payload_bytes"] = len(payload)
    raw = json.dumps(header, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return MAGIC + struct.pack("<I", len(raw)) + raw + payload


def iso_utc(dt: datetime) -> str:
    """ISO-8601 UTC with millisecond precision and a Z suffix, as the contract requires."""
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"
