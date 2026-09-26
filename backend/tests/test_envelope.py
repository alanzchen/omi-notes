import json
import struct
from datetime import UTC, datetime

import pytest

from omi_notes.device.ble_frames import encode_notification
from omi_notes.envelope import (
    MAGIC,
    EnvelopeError,
    build_envelope,
    encode_ble_record,
    iso_utc,
    parse_envelope,
)

CAPTURE = "0b6f3c1e-8f7a-4d2b-9c1e-2a3b4c5d6e7f"
STARTED = datetime(2026, 9, 26, 19, 32, 5, 123000, tzinfo=UTC)


def header(**overrides) -> dict:
    h = {
        "schema_version": 1,
        "capture_id": CAPTURE,
        "chunk_sequence": 0,
        "device_id": "dev",
        "source": "live_ble",
        "payload_format": "ble_notifications_v1",
        "codec_id": 21,
        "sample_rate": 16000,
        "channels": 1,
        "capture_started_at": iso_utc(STARTED),
        "chunk_start_offset_us": 0,
        "chunk_end_offset_us": 60_000_000,
        "clock_quality": "phone_anchored",
        "record_count": 1,
    }
    h.update(overrides)
    return h


def live_body(**overrides) -> bytes:
    payload = encode_ble_record(1000, encode_notification(7, 0, b"\x01\x02\x03"), flags=1)
    return build_envelope(header(**overrides), payload)


def test_roundtrip_live():
    env = parse_envelope(live_body(), capture_id=CAPTURE, chunk_sequence=0)
    assert env.header.chunk_start_epoch == pytest.approx(STARTED.timestamp())
    assert env.header.chunk_end_epoch == pytest.approx(STARTED.timestamp() + 60)
    assert env.header.frame_samples == 320
    (rec,) = env.ble_records()
    assert rec.t_offset_us == 1000 and rec.session_start and rec.data[:3] == b"\x07\x00\x00"


def test_iso_utc_format():
    assert iso_utc(STARTED) == "2026-09-26T19:32:05.123Z"


def test_unknown_header_fields_ignored():
    body = live_body(future_field={"x": 1})
    assert parse_envelope(body).header.capture_id == CAPTURE


def test_ring_and_pcm_payloads():
    ring = build_envelope(
        header(source="device_ring", payload_format="ring_records_v1", record_count=2,
               ring={"first_sequence": 10, "record_size": 444}),
        bytes(888),
    )  # fmt: skip
    assert len(parse_envelope(ring).ring_records()) == 2
    pcm = build_envelope(header(source="wav_replay", payload_format="pcm16le_v1", codec_id=0, record_count=3), bytes(6))
    assert parse_envelope(pcm).header.record_count == 3


@pytest.mark.parametrize(
    "mutate, message",
    [
        (lambda b: b"NOTOMI01" + b[8:], "magic"),
        (lambda b: b[:8] + struct.pack("<I", 0) + b[12:], "header_len"),
        (lambda b: b[:8] + struct.pack("<I", 10**6) + b[12:], "header_len"),
        (lambda b: b[:-1], "payload"),
        (lambda b: b + b"x", "payload"),
        (lambda b: b[:-2] + bytes([b[-2] ^ 0xFF]) + b[-1:], "CRC"),
    ],
)
def test_malformed(mutate, message):
    with pytest.raises(EnvelopeError, match=message):
        parse_envelope(mutate(live_body()))


@pytest.mark.parametrize(
    "overrides",
    [
        {"schema_version": 2},
        {"codec_id": 1},  # PCM over BLE is unsupported in v1
        {"codec_id": 0},
        {"source": "device_ring"},  # source/format mismatch
        {"payload_format": "ring_records_v1", "source": "device_ring"},  # ring info missing
        {"sample_rate": 8000},
        {"capture_started_at": "2026-09-26T19:32:05"},  # naive timestamp
        {"chunk_end_offset_us": -1},
        {"chunk_start_offset_us": 10, "chunk_end_offset_us": 5},
        {"record_count": 2},
    ],
)
def test_invalid_headers(overrides):
    with pytest.raises(EnvelopeError):
        parse_envelope(live_body(**overrides))


def test_identity_must_match_url():
    with pytest.raises(EnvelopeError, match="capture_id"):
        parse_envelope(live_body(), capture_id="ffffffff-8f7a-4d2b-9c1e-2a3b4c5d6e7f")
    with pytest.raises(EnvelopeError, match="chunk_sequence"):
        parse_envelope(live_body(), chunk_sequence=3)


def test_header_not_json():
    raw = b"{not json"
    with pytest.raises(EnvelopeError, match="JSON"):
        parse_envelope(MAGIC + struct.pack("<I", len(raw)) + raw)
    arr = json.dumps([1]).encode()
    with pytest.raises(EnvelopeError, match="object"):
        parse_envelope(MAGIC + struct.pack("<I", len(arr)) + arr)
