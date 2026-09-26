import struct

import pytest

from omi_notes.device.ring_records import AUDIO_BYTES, RECORD_SIZE, pack_records, parse_audio_payload, parse_record


def test_basic_packing_and_padding():
    audio = bytes([3, 1, 2, 3, 0, 0, 2, 9, 9]) + bytes(AUDIO_BYTES - 9)
    assert parse_audio_payload(audio) == [b"\x01\x02\x03", b"\x09\x09"]


def test_dangling_length_byte_and_stale_tail_are_ignored():
    # 434 bytes used, then a length byte 80 that cannot fit (434 + 1 + 80 >= 440), then stale data
    # that happens to look like a valid frame
    used = bytes([100]) + bytes(100) + bytes([100]) + bytes(100) + bytes([100]) + bytes(100) + bytes([130]) + bytes(130)
    assert len(used) == 434
    audio = used + bytes([80]) + bytes([2, 7, 7, 0, 0])
    assert len(audio) == AUDIO_BYTES
    frames = parse_audio_payload(audio)
    assert [len(f) for f in frames] == [100, 100, 100, 130]


def test_exact_fit_frame_is_kept():
    # offset + 1 + len == 439 is still inside the block
    audio = bytes([200]) + bytes(200) + bytes([237]) + bytes(237) + bytes(1)
    assert len(audio) == AUDIO_BYTES
    assert [len(f) for f in parse_audio_payload(audio)] == [200, 237]


def test_parse_record_timestamp_big_endian():
    record = struct.pack(">I", 1_790_000_000) + bytes([1, 42]) + bytes(AUDIO_BYTES - 2)
    parsed = parse_record(record)
    assert parsed.timestamp == 1_790_000_000
    assert parsed.frames == [b"\x2a"]
    with pytest.raises(ValueError):
        parse_record(record[:-1])


def test_packer_matches_parser_including_boundary_quirk():
    frames = [(1_790_000_000 + i // 50, bytes([i % 256]) * (60 + i % 40)) for i in range(300)]
    records = pack_records(frames)
    assert all(len(r) == RECORD_SIZE for r in records)
    recovered = [f for r in records for f in parse_record(r).frames]
    assert recovered == [f for _, f in frames]
    # at least one record ended with a dangling length byte followed by stale bytes
    assert any(parse_record(r).frames and sum(len(f) + 1 for f in parse_record(r).frames) < AUDIO_BYTES - 1 for r in records)
