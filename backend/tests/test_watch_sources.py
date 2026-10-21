"""Apple Watch recordings (`watch_mic`, relayed by the phone) next to the pendant: the same event
recorded twice gets one note (the Watch audio kept as an alternate recording), while separate
speech on the two devices stays two notes. Synthetic audio; fake providers."""

from __future__ import annotations

import json
import uuid
from datetime import timedelta

import numpy as np

from omi_notes.devtools import pcm_envelopes, synth_speech_like

from .conftest import put_chunk, upload_all
from .helpers import STARTED, T0, convs, live, replay, silence

WATCH = "watch-0f3a9c2e"


def by_device(worker):
    rows = convs(worker)
    return [r for r in rows if r["device_id"] != WATCH], [r for r in rows if r["device_id"] == WATCH]


def decision(worker, row):
    return json.loads((worker.pipeline.conv_dir(row["id"]) / "source.json").read_text())


def run(worker, until: float):
    for t in range(int(T0) + 300, int(until), 60):
        worker.tick(t)


def talk(seconds: float, seed: int) -> np.ndarray:
    """Speech-like audio with irregular words and pauses (synth_speech_like alone is periodic, so
    any two would line up at some lag)."""
    rng = np.random.default_rng(seed)
    gate = np.zeros(int(seconds * 16000))
    i = 0
    while i < len(gate):
        word = int(rng.uniform(0.2, 1.2) * 16000)
        gate[i:i + word] = 1
        i += word + int(rng.uniform(0.15, 0.9) * 16000)
    return (synth_speech_like(seconds, seed=seed).astype(np.float64) * gate).astype(np.int16)


def heard_by_watch(pcm: np.ndarray, seed: int = 9) -> np.ndarray:
    """The same sound on another microphone: quieter, with its own noise."""
    noise = np.random.default_rng(seed).normal(0, 300, len(pcm))
    return np.clip(0.55 * pcm.astype(np.float64) + noise, -32768, 32767).astype(np.int16)


def test_a_watch_recording_alone_becomes_a_note(client, worker, settings):
    replay(client, np.concatenate([silence(1), talk(30, 3), silence(2)]), source="watch_mic", device=WATCH)
    run(worker, T0 + 900)
    (row,) = convs(worker)
    assert row["status"] == "done" and row["note_path"]
    assert decision(worker, row)["decision"] == "distinct"


def test_the_same_conversation_on_both_devices_is_one_note(client, worker, settings):
    speech = np.concatenate([silence(1), talk(45, 1), silence(2)])
    live(client, speech, offline_storage=False)
    # the Watch's clock is 4 s ahead of the phone's: its copy of the same sound is stamped later
    replay(client, heard_by_watch(speech), start=STARTED + timedelta(seconds=4), source="watch_mic", device=WATCH)
    run(worker, T0 + 1200)
    (pendant,), (watch,) = by_device(worker)
    assert pendant["status"] == "done" and pendant["note_path"]
    d = decision(worker, watch)
    assert d["decision"] == "alternate" and d["of"] == [pendant["id"]] and d["correlation"] >= 0.6, d
    assert abs(abs(d["lag_seconds"]) - 4) <= 0.3, d
    assert watch["status"] == "discarded" and watch["note_path"].startswith("_discarded/"), "no second note for the same event"
    daily = next(settings.vault_dir.glob("Daily/*.md")).read_text()
    assert "also recorded by the pendant" in daily, "listed with its reason; the audio is kept"


def test_separate_speech_at_the_same_time_stays_two_notes(client, worker):
    live(client, np.concatenate([silence(1), talk(45, 1), silence(2)]), offline_storage=False)
    replay(client, np.concatenate([silence(1), talk(45, 7), silence(2)]), source="watch_mic", device=WATCH)
    run(worker, T0 + 1200)
    (pendant,), (watch,) = by_device(worker)
    assert pendant["note_path"] and watch["note_path"] and watch["status"] == "done"
    assert decision(worker, watch)["decision"] in ("distinct", "uncertain")


def test_a_watch_recording_longer_than_the_pendants_keeps_its_note(client, worker):
    speech = np.concatenate([silence(1), talk(60, 1), silence(2)])
    live(client, speech[: 20 * 16000], offline_storage=False)  # the pendant got only the first 20 s
    replay(client, heard_by_watch(speech), source="watch_mic", device=WATCH)
    run(worker, T0 + 1200)
    _, (watch,) = by_device(worker)
    d = decision(worker, watch)
    assert d["decision"] in ("partial", "uncertain", "distinct") and watch["note_path"], d


def test_a_watch_recording_still_going_gets_notes_without_stop(client, worker, settings):
    """All-day recording: the wearer never taps Stop (no seal), yet each conversation becomes a note
    once the parts after it have arrived."""
    capture = str(uuid.uuid4())
    pcm = np.concatenate([silence(1), talk(30, 3), silence(269), talk(30, 5), silence(270)])  # 10 one-minute parts
    envs = pcm_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED, chunk_seconds=60.0, source="watch_mic")
    upload_all(client, capture, envs[:5])
    run(worker, T0 + 900)
    (first,) = convs(worker)
    assert first["status"] == "done" and first["note_path"], "a note before Stop"
    for seq in range(5, len(envs)):  # the next five minutes, still not stopped
        assert put_chunk(client, capture, seq, envs[seq]).status_code == 201
    run(worker, T0 + 1500)
    rows = convs(worker)
    assert len(rows) == 2 and all(r["status"] == "done" and r["note_path"] for r in rows), rows
    assert worker.pipeline.db.one("SELECT seal_json FROM captures WHERE capture_id=?", (capture,))["seal_json"] is None
