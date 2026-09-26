"""Developer tooling: turn PCM into contract-conformant capture envelopes.

`live_envelopes` imitates the CV1 firmware + phone: firmware-like Opus (restricted-lowdelay,
32 kbps VBR, complexity 3) in 320-sample frames, real `[seq u16 LE][idx][opus]` notifications,
the mic's silence sleep (no notifications after ~10 s of quiet until sound returns), optional
random notification loss, and ~60 s chunks whose `[start, end]` offsets are coverage.
"""

from __future__ import annotations

import random
import shutil
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

import numpy as np
import soundfile as sf

from .audio.opus import OpusEncoder
from .device.ble_frames import encode_notification
from .device.ring_records import RECORD_SIZE, pack_records
from .envelope import FLAG_SESSION_START, build_envelope, encode_ble_record, iso_utc

SAMPLE_RATE = 16000
FRAME = 320
MIC_SLEEP_SECONDS = 10.0
MIC_QUIET_PEAK = 250  # firmware mic.c amplitude threshold
BLE_LATENCY_US = 25_000


def load_wav_16k(path: Path) -> np.ndarray:
    """Any audio file → 16 kHz mono int16 (ffmpeg when available, else soundfile + linear resampling)."""
    if shutil.which("ffmpeg"):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "a.wav"
            subprocess.run(
                ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(path), "-ac", "1", "-ar", "16000",
                 "-sample_fmt", "s16", str(out)],
                check=True,
            )  # fmt: skip
            pcm, _ = sf.read(out, dtype="int16")
            return np.asarray(pcm, dtype=np.int16)
    data, rate = sf.read(path, dtype="float32", always_2d=True)
    mono = data.mean(axis=1)
    if rate != SAMPLE_RATE:
        n = int(round(len(mono) * SAMPLE_RATE / rate))
        mono = np.interp(np.linspace(0, len(mono) - 1, n), np.arange(len(mono)), mono)
    return np.clip(mono * 32767, -32768, 32767).astype(np.int16)


def base_header(
    *,
    capture_id: str,
    seq: int,
    device_id: str,
    source: str,
    payload_format: str,
    codec_id: int,
    started_at: datetime,
    start_us: int,
    end_us: int,
    record_count: int,
    offline_storage: bool | None = None,
    clock_quality: str = "phone_anchored",
) -> dict:
    return {
        "schema_version": 1,
        "capture_id": capture_id,
        "chunk_sequence": seq,
        "device_id": device_id,
        "device_name": "Omi",
        "model_number": "Omi CV 1",
        "firmware_revision": "3.0.21",
        "hardware_revision": "5.0",
        "source": source,
        "payload_format": payload_format,
        "codec_id": codec_id,
        "sample_rate": SAMPLE_RATE,
        "channels": 1,
        "capture_started_at": iso_utc(started_at),
        "chunk_start_offset_us": start_us,
        "chunk_end_offset_us": end_us,
        "clock_quality": clock_quality,
        "timezone": None,
        "record_count": record_count,
        "offline_storage": offline_storage,
        "app_version": "omi-notes-devtools",
    }


def encode_frames(pcm: np.ndarray) -> list[tuple[int, bytes, int]]:
    """(frame index, opus packet, peak amplitude) for each 320-sample frame (last one zero padded)."""
    encoder = OpusEncoder()
    frames = []
    for i in range(0, len(pcm), FRAME):
        frame = pcm[i : i + FRAME]
        if len(frame) < FRAME:
            frame = np.concatenate([frame, np.zeros(FRAME - len(frame), dtype=np.int16)])
        frames.append((i // FRAME, encoder.encode(frame), int(np.abs(frame.astype(np.int32)).max())))
    encoder.close()
    return frames


def live_envelopes(
    pcm: np.ndarray,
    *,
    capture_id: str,
    device_id: str,
    started_at: datetime,
    chunk_seconds: float = 60.0,
    drop_rate: float = 0.0,
    seq_start: int = 0,
    mic_sleep: bool = True,
    offline_storage: bool | None = False,
    seed: int = 0,
) -> list[bytes]:
    rng = random.Random(seed)
    frame_us = FRAME * 1_000_000 // SAMPLE_RATE
    # The capture lasts until the last frame (the final one is zero padded) has been received.
    total_us = -(-len(pcm) // FRAME) * frame_us + BLE_LATENCY_US
    chunk_us = int(chunk_seconds * 1_000_000)
    n_chunks = max(1, -(-total_us // chunk_us))
    records: list[list[bytes]] = [[] for _ in range(n_chunks)]
    seq = seq_start
    quiet_us = 0
    asleep = False
    first = True
    for index, packet, peak in encode_frames(pcm):
        if mic_sleep:
            if peak < MIC_QUIET_PEAK:
                quiet_us += frame_us
                if quiet_us >= MIC_SLEEP_SECONDS * 1_000_000:
                    asleep = True
            else:
                quiet_us, asleep = 0, False
            if asleep:
                continue  # the mic is off: no frame, no sequence number
        this_seq = seq
        seq = (seq + 1) & 0xFFFF
        if not first and drop_rate and rng.random() < drop_rate:
            continue  # lost over the air: the sequence number was used
        recv_us = (index + 1) * frame_us + BLE_LATENCY_US
        chunk = min(recv_us // chunk_us, n_chunks - 1)
        flags = FLAG_SESSION_START if first else 0
        records[chunk].append(encode_ble_record(recv_us - chunk * chunk_us, encode_notification(this_seq, 0, packet), flags))
        first = False
    envelopes = []
    for c, recs in enumerate(records):
        start_us = c * chunk_us
        end_us = min((c + 1) * chunk_us, total_us)
        header = base_header(
            capture_id=capture_id, seq=c, device_id=device_id, source="live_ble",
            payload_format="ble_notifications_v1", codec_id=21, started_at=started_at, start_us=start_us,
            end_us=end_us, record_count=len(recs), offline_storage=offline_storage,
        )  # fmt: skip
        envelopes.append(build_envelope(header, b"".join(recs)))
    return envelopes


def pcm_envelopes(
    pcm: np.ndarray, *, capture_id: str, device_id: str, started_at: datetime, chunk_seconds: float = 60.0
) -> list[bytes]:
    step = int(chunk_seconds * SAMPLE_RATE)
    envelopes = []
    for c, i in enumerate(range(0, max(len(pcm), 1), step)):
        part = pcm[i : i + step].astype("<i2")
        header = base_header(
            capture_id=capture_id, seq=c, device_id=device_id, source="wav_replay", payload_format="pcm16le_v1",
            codec_id=0, started_at=started_at, start_us=i * 1_000_000 // SAMPLE_RATE,
            end_us=(i + len(part)) * 1_000_000 // SAMPLE_RATE, record_count=len(part),
        )  # fmt: skip
        envelopes.append(build_envelope(header, part.tobytes()))
    return envelopes


def ring_envelopes(
    pcm: np.ndarray,
    *,
    capture_id: str,
    device_id: str,
    started_at: datetime,
    audio_start_epoch: int,
    first_sequence: int = 0,
    records_per_chunk: int = 600,
) -> tuple[list[bytes], int]:
    """Offline-storage capture of `pcm` recorded from `audio_start_epoch` (device RTC seconds).
    Returns the envelopes and the number of records."""
    timed = [(audio_start_epoch + (index * FRAME) // SAMPLE_RATE, packet) for index, packet, _ in encode_frames(pcm)]
    records = pack_records(timed)
    envelopes = []
    for c, i in enumerate(range(0, len(records), records_per_chunk)):
        batch = records[i : i + records_per_chunk]
        header = base_header(
            capture_id=capture_id, seq=c, device_id=device_id, source="device_ring", payload_format="ring_records_v1",
            codec_id=21, started_at=started_at, start_us=c * 1_000_000, end_us=(c + 1) * 1_000_000,
            record_count=len(batch), clock_quality="device_seconds",
        )  # fmt: skip
        header["ring"] = {"first_sequence": first_sequence + i, "record_size": RECORD_SIZE,
                          "read_seq": first_sequence, "write_seq": first_sequence + len(records), "dropped": 0}  # fmt: skip
        envelopes.append(build_envelope(header, b"".join(batch)))
    return envelopes, len(records)


def synth_speech_like(seconds: float, *, seed: int = 0, level: float = 0.3) -> np.ndarray:
    """Syllable-shaped harmonic bursts (for energy-VAD tests; Silero does not call this speech)."""
    rng = np.random.default_rng(seed)
    n = int(seconds * SAMPLE_RATE)
    t = np.arange(n) / SAMPLE_RATE
    f0 = 140 + 30 * np.sin(2 * np.pi * 0.7 * t)
    phase = 2 * np.pi * np.cumsum(f0) / SAMPLE_RATE
    voice = sum(np.sin(k * phase) / k for k in range(1, 8))
    envelope = np.clip(np.sin(2 * np.pi * 4.0 * t + rng.uniform(0, np.pi)), 0, None) ** 0.5
    signal = voice * envelope * level + rng.normal(0, 0.002, n)
    return np.clip(signal * 32767 / 2.5, -32768, 32767).astype(np.int16)
