"""Listening to a note's recording (`/v1/conversations/{id}/recording`, capture-format-v1.md).

The playable audio is everything retained from the conversation's start to its end, in order
(quiet between speech included), never another conversation's; wall-clock time with no recorded
audio is reported as a gap, not filled in."""

from __future__ import annotations

import io
import time
from datetime import timedelta

import numpy as np
import soundfile as sf

from .conftest import AUTH
from .helpers import STARTED, T0, convs, replay, silence

SR = 16000


def pitch(f: float, seconds: float, level: int = 9000) -> np.ndarray:
    t = np.arange(int(seconds * SR)) / SR
    env = np.clip(np.sin(2 * np.pi * 3 * t), 0, None) ** 0.5  # syllable-like, so VAD calls it speech
    return (np.sin(2 * np.pi * f * t) * env * level).astype(np.int16)


def dominant(pcm: np.ndarray) -> float:
    spectrum = np.abs(np.fft.rfft(pcm.astype(float) * np.hanning(len(pcm))))
    return float(np.fft.rfftfreq(len(pcm), 1 / SR)[np.argmax(spectrum)])


def meta(client, conv_id):
    r = client.get(f"/v1/conversations/{conv_id}/recording", headers=AUTH)
    return r.status_code, r.json()


def wav(client, conv_id, headers=None):
    return client.get(f"/v1/conversations/{conv_id}/recording.wav", headers=AUTH | (headers or {}))


# 3 s at 440 Hz, 4 s of quiet, 3 s at 880 Hz: distinguishable sections with known offsets
KNOWN = np.concatenate([silence(1), pitch(440, 3), silence(4), pitch(880, 3), silence(1)])


def test_the_recording_is_the_whole_conversation_in_order_with_its_quiet(client, worker):
    replay(client, KNOWN, chunk_seconds=2.0)  # several chunks
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    code, m = meta(client, row["id"])
    assert code == 200 and m["available"] is True and m["gaps"] == [] and m["partial"] is False
    span = row["end"] - row["start"]
    assert abs(m["duration_s"] - span) < 0.05 and abs(m["span"]["seconds"] - span) < 0.05
    r = wav(client, row["id"])
    assert r.status_code == 200 and r.headers["content-type"] == "audio/wav" and r.headers["accept-ranges"] == "bytes"
    pcm, rate = sf.read(io.BytesIO(r.content), dtype="int16")
    assert rate == SR and abs(len(pcm) / SR - m["duration_s"]) < 0.01
    # the quiet between the two sections is kept, so each section is where the clock says it is
    offset = m["timemap"][0][1] - (STARTED.timestamp())  # wall start of the playable audio vs the capture
    at = lambda wall: int((wall - offset) * SR)  # noqa: E731 — capture seconds → playable sample
    assert abs(dominant(pcm[at(1.5):at(3.5)]) - 440) < 15
    assert abs(dominant(pcm[at(8.5):at(10.5)]) - 880) < 15
    assert np.abs(pcm[at(5.0):at(7.0)]).max() < 300  # the quiet part is quiet, not removed


def test_byte_ranges_let_the_phone_stream_and_seek(client, worker):
    replay(client, KNOWN, chunk_seconds=2.0)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    whole = wav(client, row["id"]).content
    part = wav(client, row["id"], {"Range": "bytes=10000-19999"})
    assert part.status_code == 206 and part.content == whole[10000:20000]
    assert part.headers["content-range"] == f"bytes 10000-19999/{len(whole)}"
    assert client.get(f"/v1/conversations/{row['id']}/recording.wav").status_code == 401  # never without the token


def test_another_conversation_is_never_part_of_this_recording(client, worker):
    replay(client, np.concatenate([silence(1), pitch(440, 3), silence(1)]))
    replay(client, np.concatenate([silence(1), pitch(880, 3), silence(1)]), start=STARTED + timedelta(minutes=10))
    worker.tick(T0 + 1200)
    first, second = sorted(convs(worker), key=lambda r: r["start"])
    for row, f in ((first, 440), (second, 880)):
        _, m = meta(client, row["id"])
        pcm, _ = sf.read(io.BytesIO(wav(client, row["id"]).content), dtype="int16")
        assert abs(m["duration_s"] - (row["end"] - row["start"])) < 0.05
        assert abs(dominant(pcm) - f) < 15  # only its own section


def test_time_without_recorded_audio_is_a_gap_not_filled_in(client, worker):
    replay(client, np.concatenate([silence(1), pitch(440, 3)]))
    replay(client, np.concatenate([pitch(880, 3), silence(1)]), start=STARTED + timedelta(seconds=12))  # 8 s unrecorded
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    _, m = meta(client, row["id"])
    assert m["available"] is True and m["partial"] is True and len(m["gaps"]) == 1
    gap = m["gaps"][0]
    assert abs(gap["seconds"] - 8.0) < 0.1
    assert abs(m["duration_s"] - (m["span"]["seconds"] - 8.0)) < 0.1  # playable time says so
    assert len(m["timemap"]) == 2  # where each playable part sits on the clock


def test_expired_audio_is_said_plainly(client, worker):
    replay(client, KNOWN)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert meta(client, row["id"])[1]["available"] is True
    worker.retention(time.time() + 400 * 86400)
    code, m = meta(client, row["id"])
    assert code == 200 and m["available"] is False and m["reason"] == "expired" and m["duration_s"] is None
    r = wav(client, row["id"])
    assert r.status_code == 410 and r.json()["error"] == "audio_expired"


def test_unknown_and_unfinished_conversations(client, worker):
    assert client.get("/v1/conversations/01a0aaaa-0000-7000-8000-000000000000/recording", headers=AUTH).status_code == 404
    replay(client, KNOWN)
    assert meta(client, "nope")[0] == 404
