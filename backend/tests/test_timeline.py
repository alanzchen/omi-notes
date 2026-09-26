from datetime import UTC, datetime

import numpy as np
import pytest

from omi_notes.audio.opus import OpusDecoder, OpusEncoder
from omi_notes.audio.timeline import SAMPLE_RATE, CaptureTimeline
from omi_notes.device.ble_frames import encode_notification
from omi_notes.device.ring_records import pack_records
from omi_notes.devtools import base_header, pcm_envelopes, ring_envelopes
from omi_notes.envelope import FLAG_SESSION_START, build_envelope, encode_ble_record, parse_envelope

CAPTURE = "0b6f3c1e-8f7a-4d2b-9c1e-2a3b4c5d6e7f"
STARTED = datetime(2026, 9, 26, 19, 0, 0, tzinfo=UTC)
T0 = STARTED.timestamp()


def tone(frames: int, freq: float = 440.0) -> list[bytes]:
    enc = OpusEncoder()
    t = np.arange(frames * 320) / SAMPLE_RATE
    pcm = (np.sin(2 * np.pi * freq * t) * 8000).astype(np.int16)
    return [enc.encode(pcm[i * 320 : (i + 1) * 320]) for i in range(frames)]


def live_env(records: list[tuple[int, int, bytes]], *, seq: int = 0, start_us: int = 0, end_us: int = 60_000_000):
    payload = b"".join(encode_ble_record(t - start_us, data, flags) for t, flags, data in records)
    header = base_header(capture_id=CAPTURE, seq=seq, device_id="d", source="live_ble",
                         payload_format="ble_notifications_v1", codec_id=21, started_at=STARTED,
                         start_us=start_us, end_us=end_us, record_count=len(records))  # fmt: skip
    return parse_envelope(build_envelope(header, payload))


def notifications(packets: list[bytes], times_us: list[int], first_seq: int = 0) -> list[tuple[int, int, bytes]]:
    return [
        (t, FLAG_SESSION_START if i == 0 else 0, encode_notification((first_seq + i) & 0xFFFF, 0, p))
        for i, (p, t) in enumerate(zip(packets, times_us, strict=True))
    ]


def test_continuous_live_is_one_run():
    packets = tone(150)
    env = live_env(notifications(packets, [100_000 + i * 20_000 for i in range(150)]))
    result = CaptureTimeline(320).decode_chunk(env, final=True)
    assert len(result.pieces) == 1
    piece = result.pieces[0]
    assert piece.start == pytest.approx(T0 + 0.1)
    assert len(piece.pcm) == 150 * 320
    assert result.stats["frames"] == 150


def test_bursty_arrivals_do_not_move_timing():
    packets = tone(100)
    # delivered in bursts of 10 frames every 200 ms, all stamped with the burst time
    times = [100_000 + (i // 10) * 200_000 for i in range(100)]
    result = CaptureTimeline(320).decode_chunk(live_env(notifications(packets, times)), final=True)
    assert len(result.pieces) == 1
    assert result.pieces[0].start == pytest.approx(T0 + 0.1)
    assert len(result.pieces[0].pcm) == 100 * 320


def test_silence_sleep_gap_starts_new_run():
    packets = tone(100)
    times = [i * 20_000 for i in range(50)] + [5_000_000 + i * 20_000 for i in range(50)]
    result = CaptureTimeline(320).decode_chunk(live_env(notifications(packets, times)), final=True)
    assert [round(p.start - T0, 3) for p in result.pieces] == [0.0, 5.0]
    assert [len(p.pcm) for p in result.pieces] == [50 * 320, 50 * 320]
    assert result.pieces[1].continues is False


def test_small_arrival_jitter_stays_in_run():
    packets = tone(100)
    times = [i * 20_000 for i in range(50)] + [1_000_000 + 1_400_000 + i * 20_000 for i in range(50)]
    result = CaptureTimeline(320).decode_chunk(live_env(notifications(packets, times)), final=True)
    assert len(result.pieces) == 1  # 1.4 s late is within the 1.5 s tolerance


def test_plc_keeps_sample_timing():
    packets = tone(60)
    times = [i * 20_000 for i in range(60)]
    records = [r for i, r in enumerate(notifications(packets, times)) if i not in (20, 21, 22)]
    result = CaptureTimeline(320).decode_chunk(live_env(records), final=True)
    assert len(result.pieces) == 1
    # frame 19 is still decoded; the 3 lost notifications → 3 frames concealed
    assert result.stats["plc_frames"] == 3
    assert len(result.pieces[0].pcm) == 60 * 320


def test_carry_across_chunks_reproduces_timing():
    packets = tone(100)
    notes = notifications(packets, [i * 20_000 for i in range(100)])
    first = live_env(notes[:50], seq=0, start_us=0, end_us=1_000_000)
    second = live_env(notes[50:], seq=1, start_us=1_000_000, end_us=2_000_000)
    tl = CaptureTimeline(320)
    a = tl.decode_chunk(first)
    b = tl.decode_chunk(second, final=True)
    # the pending (last) frame of chunk 0 is emitted by chunk 1
    assert len(a.pieces[0].pcm) == 49 * 320
    assert b.pieces[0].continues and b.pieces[0].start == pytest.approx(a.pieces[0].end)
    restored = CaptureTimeline(320, a.carry).decode_chunk(second, final=True)
    assert restored.pieces[0].start == pytest.approx(b.pieces[0].start)
    assert len(restored.pieces[0].pcm) == len(b.pieces[0].pcm)


def test_session_start_resets_and_reanchors():
    packets = tone(20)
    notes = notifications(packets[:10], [i * 20_000 for i in range(10)], first_seq=100)
    notes += notifications(packets[10:], [30_000_000 + i * 20_000 for i in range(10)], first_seq=5000)
    result = CaptureTimeline(320).decode_chunk(live_env(notes), final=True)
    assert [round(p.start - T0, 2) for p in result.pieces] == [0.0, 30.0]
    assert result.stats["resets"] >= 2


def test_corrupt_packet_becomes_lost_frame():
    packets = tone(10)
    packets[5] = b"\xff" * 3  # not a valid Opus packet for this stream
    result = CaptureTimeline(320).decode_chunk(live_env(notifications(packets, [i * 20_000 for i in range(10)])), final=True)
    assert len(result.pieces[0].pcm) == 10 * 320


def test_ring_second_resolution_timestamps():
    pcm = (np.sin(np.arange(16000 * 3) / 5) * 6000).astype(np.int16)
    envs, n = ring_envelopes(pcm, capture_id=CAPTURE, device_id="d", started_at=STARTED, audio_start_epoch=int(T0) + 100)
    result = CaptureTimeline(320).decode_chunk(parse_envelope(envs[0]))
    assert len(result.pieces) == 1
    assert result.pieces[0].start == pytest.approx(T0 + 100)
    assert len(result.pieces[0].pcm) == 150 * 320
    assert len(result.ring_records) == n


def test_ring_timestamp_jump_starts_new_run():
    enc_packets = tone(100)
    frames = [(int(T0) + i // 50, p) for i, p in enumerate(enc_packets[:50])]
    frames += [(int(T0) + 60 + i // 50, p) for i, p in enumerate(enc_packets[50:])]
    records = pack_records(frames)
    header = base_header(capture_id=CAPTURE, seq=0, device_id="d", source="device_ring", payload_format="ring_records_v1",
                         codec_id=21, started_at=STARTED, start_us=0, end_us=1, record_count=len(records),
                         clock_quality="device_seconds")  # fmt: skip
    header["ring"] = {"first_sequence": 7, "record_size": 444}
    result = CaptureTimeline(320).decode_chunk(parse_envelope(build_envelope(header, b"".join(records))))
    assert [round(p.start - T0) for p in result.pieces] == [0, 60]


def test_ring_dedupe_skips_seen_records():
    pcm = (np.sin(np.arange(16000 * 2) / 5) * 6000).astype(np.int16)
    envs, n = ring_envelopes(pcm, capture_id=CAPTURE, device_id="d", started_at=STARTED, audio_start_epoch=int(T0))
    seen = set()
    first = CaptureTimeline(320, ring_seen=lambda s, h: (s, h) in seen).decode_chunk(parse_envelope(envs[0]))
    seen.update(first.ring_records)
    again = CaptureTimeline(320, ring_seen=lambda s, h: (s, h) in seen).decode_chunk(parse_envelope(envs[0]))
    assert again.pieces == [] and again.stats["ring_duplicates"] == n


def test_pcm_chunks_are_continuous():
    pcm = (np.arange(16000 * 3) % 1000).astype(np.int16)
    envs = pcm_envelopes(pcm, capture_id=CAPTURE, device_id="d", started_at=STARTED, chunk_seconds=1.0)
    tl = CaptureTimeline(0)
    pieces = [p for e in envs for p in tl.decode_chunk(parse_envelope(e)).pieces]
    assert [p.continues for p in pieces] == [False, True, True]
    assert np.array_equal(np.concatenate([p.pcm for p in pieces]), pcm)


def test_opus_plc_produces_frame_sized_output():
    dec = OpusDecoder()
    (packet,) = tone(1)
    assert len(dec.decode(packet)) == 320
    assert len(dec.conceal(320)) == 320
    assert len(dec.conceal(160)) == 160
