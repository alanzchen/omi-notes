"""Offline-storage ring records (device-protocol.md, "Offline storage").

Record (444 bytes): `[unix_ts:u32 BE][440 bytes: repeated [len:u8][opus frame], zero padded]`.
Parse rule, matching Omi's `RingProtocol.parseAudioPayload` and the firmware's
`write_to_storage()`: a `0` length byte is padding; stop when `offset + 1 + len >= 440` because
at a block boundary the firmware writes a dangling length byte and puts the whole frame into the
next record, leaving stale bytes from the previous block behind it.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

RECORD_SIZE = 444
AUDIO_BYTES = 440


@dataclass(frozen=True)
class RingRecord:
    timestamp: int
    frames: list[bytes]


def parse_audio_payload(audio: bytes) -> list[bytes]:
    frames: list[bytes] = []
    offset = 0
    limit = len(audio)
    while offset < limit - 1:
        size = audio[offset]
        if size == 0:
            offset += 1
            continue
        if offset + 1 + size >= limit:
            break
        frames.append(bytes(audio[offset + 1 : offset + 1 + size]))
        offset += 1 + size
    return frames


def parse_record(record: bytes) -> RingRecord:
    if len(record) != RECORD_SIZE:
        raise ValueError(f"ring record must be {RECORD_SIZE} bytes, got {len(record)}")
    (timestamp,) = struct.unpack_from(">I", record, 0)
    return RingRecord(timestamp=timestamp, frames=parse_audio_payload(record[4:]))


def pack_records(frames: list[tuple[int, bytes]]) -> list[bytes]:
    """Emulate the firmware packer for tests/fixtures: `(unix_ts, opus_frame)` in order → records.

    Reproduces the boundary quirk: when a frame does not fit, a dangling length byte is written
    and the rest of the block keeps stale bytes from the previous block (the firmware reuses its
    buffer without clearing it). Each record takes the timestamp of its first frame.
    """
    records: list[bytes] = []
    block = bytearray(AUDIO_BYTES)
    offset = 0
    block_ts: int | None = None
    for ts, frame in frames:
        size = len(frame)
        if not 0 < size < AUDIO_BYTES - 1:
            raise ValueError("frame size out of range")
        if block_ts is None:
            block_ts = ts
        packet = size + 1
        if offset + packet > AUDIO_BYTES - 1:
            block[offset] = size  # dangling length byte; the frame goes to the next record
            records.append(struct.pack(">I", block_ts) + bytes(block))
            block_ts = ts
            block[0] = size
            block[1 : 1 + size] = frame
            offset = packet
        elif offset + packet == AUDIO_BYTES - 1:
            block[offset] = size
            block[offset + 1 : offset + 1 + size] = frame
            records.append(struct.pack(">I", block_ts) + bytes(block))
            block_ts = None
            offset = 0
        else:
            block[offset] = size
            block[offset + 1 : offset + 1 + size] = frame
            offset += packet
    if offset and block_ts is not None:
        tail = bytearray(block)
        tail[offset:] = bytes(AUDIO_BYTES - offset)  # a final flush is zero padded
        records.append(struct.pack(">I", block_ts) + bytes(tail))
    return records
