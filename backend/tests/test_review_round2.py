"""Regression tests for the second backend review round (numbered like its defect list)."""

from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from typer.testing import CliRunner

from omi_notes import db as dbmod
from omi_notes import spool
from omi_notes.api import create_app
from omi_notes.audio.vad import EnergyVad, VadChoice
from omi_notes.cli import app as cli
from omi_notes.db import Database
from omi_notes.devtools import live_envelopes, pcm_envelopes, ring_envelopes, synth_speech_like
from omi_notes.envelope import build_envelope, parse_envelope
from omi_notes.lock import WorkerLock
from omi_notes.pipeline.worker import Worker
from omi_notes.providers.fake import FakeLlm

from .conftest import AUTH, DEVICE, cli_env, make_settings, put_chunk, upload_all
from .helpers import STARTED, T0, convs, event, iso, live, live_seal, replay, ring_seal, ring_sync, silence

SPEECH = np.concatenate([silence(1), synth_speech_like(10), silence(2)])


# 1 -----------------------------------------------------------------------------------------------


def test_r1_split_speech_keeps_its_identity_when_the_next_chunk_extends_it(client, worker):
    capture = str(uuid.uuid4())
    envs = live_envelopes(np.concatenate([synth_speech_like(90), silence(3)]), capture_id=capture, device_id=DEVICE,
                          started_at=STARTED, offline_storage=False)  # fmt: skip
    assert len(envs) == 2
    put_chunk(client, capture, 0, envs[0])
    event(client, "button", at=T0 + 30, capture_id=capture, offset_us=30_000_000, data={"code": 2})
    worker.tick(T0 + 300)
    assert [c["status"] for c in convs(worker)] == ["done", "open"]
    put_chunk(client, capture, 1, envs[1])
    live_seal(client, capture, envs)
    worker.tick(T0 + 600)
    rows = convs(worker)
    assert [(round(r["start"] - T0), r["late_audio"]) for r in rows] == [(0, 0), (30, 0)]
    assert rows[0]["end"] == pytest.approx(T0 + 30) and rows[1]["end"] > T0 + 89


def test_r1_late_seal_does_not_duplicate_a_finalized_utterance(client, worker):
    capture = str(uuid.uuid4())
    envs = live_envelopes(synth_speech_like(2), capture_id=capture, device_id=DEVICE, started_at=STARTED,
                          offline_storage=False)  # fmt: skip
    upload_all(client, capture, envs)
    worker.tick(T0 + 100)
    worker.tick(T0 + 2000)  # provisional close while the capture is still unsealed
    assert [(c["status"], c["provisional"]) for c in convs(worker)] == [("done", 1)]
    live_seal(client, capture, envs)
    worker.tick(T0 + 2100)
    assert len(convs(worker)) == 1


# 2 -----------------------------------------------------------------------------------------------


def test_r2_a_hole_in_ring_sequences_is_never_bridged(client, worker):
    first, second = str(uuid.uuid4()), str(uuid.uuid4())
    envs_a, n_a = ring_envelopes(synth_speech_like(2, seed=1), capture_id=first, device_id=DEVICE, started_at=STARTED,
                                 audio_start_epoch=int(T0) - 4000, first_sequence=1000)  # fmt: skip
    upload_all(client, first, envs_a)
    ring_sync(client, T0 - 3000, last_chunk_sequence=len(envs_a) - 1, capture=first, info_read_seq=1000)
    hole_end = 1520  # records 1000+n_a .. 1519 never reach the server
    envs_b, n_b = ring_envelopes(synth_speech_like(2, seed=2), capture_id=second, device_id=DEVICE, started_at=STARTED,
                                 audio_start_epoch=int(T0) - 2500, first_sequence=hole_end)  # fmt: skip
    upload_all(client, second, envs_b)
    ring_sync(client, T0 - 2000, last_chunk_sequence=len(envs_b) - 1, capture=second, info_read_seq=hole_end)
    ring_sync(client, T0, info_read_seq=hole_end + n_b)  # connect-time sync, empty
    live(client, np.concatenate([silence(1), synth_speech_like(20), silence(4)]), offline_storage=True)
    ring_sync(client, T0 + 300, info_read_seq=hole_end + n_b)
    worker.tick(T0 + 400)
    assert [c["status"] for c in convs(worker) if c["start"] > T0 - 10] == ["open"]


# 3 -----------------------------------------------------------------------------------------------


def v1_database(path: Path) -> None:
    conn = sqlite3.connect(path, isolation_level=None)
    conn.executescript("BEGIN;" + dbmod.MIGRATIONS[0] + "; PRAGMA user_version=1; COMMIT;")
    rows = [
        ("live-legacy", "live_ble", {"last_chunk_sequence": 3, "reason": "ble_disconnected", "end_offset_us": 311025000,
                                     "ended_at": "x", "device_id": DEVICE, "source": "live_ble"}),
        ("live-string", "live_ble", {"last_chunk_sequence": 0, "reason": "user_stopped", "end_offset_us": "5000000",
                                     "ended_at": "x", "device_id": DEVICE, "source": "live_ble"}),
        ("live-none", "live_ble", {"last_chunk_sequence": 0, "reason": "user_stopped", "ended_at": "x",
                                   "device_id": DEVICE, "source": "live_ble"}),
        ("live-bad", "live_ble", {"last_chunk_sequence": 0, "reason": "user_stopped", "end_offset_us": "abc",
                                  "ended_at": "x", "device_id": DEVICE, "source": "live_ble"}),
        ("ring-legacy", "device_ring", {"last_chunk_sequence": 1, "reason": "sync_complete", "ended_at": "x",
                                        "device_id": DEVICE, "source": "device_ring",
                                        "ring": {"generation": 3, "info_read_seq": 1200, "dropped": 7}}),
    ]  # fmt: skip
    for capture_id, source, seal in rows:
        conn.execute(
            """INSERT INTO captures (capture_id, device_id, source, created_at, capture_started_at, seal_json, seal_reason,
                   last_chunk_sequence, ended_at) VALUES (?,?,?,?,?,?,?,?,?)""",
            (capture_id, DEVICE, source, T0, T0, json.dumps(seal), seal["reason"], seal["last_chunk_sequence"], T0 - 7200),
        )
    conn.close()


def test_r3_migration_backfills_normalized_seal_values(tmp_path):
    path = tmp_path / "v1.sqlite3"
    v1_database(path)
    db = Database(path)
    by_id = {r["capture_id"]: r for r in db.query("SELECT * FROM capture_times")}
    assert by_id["live-legacy"]["seal_end_offset_us"] == 311025000
    assert by_id["live-legacy"]["seal_end"] == pytest.approx(T0 + 311.025)  # monotonic, not the stepped wall clock
    assert by_id["live-string"]["seal_end_offset_us"] == 5_000_000  # v1 accepted (coerced) numeric strings
    assert by_id["live-none"]["seal_end_offset_us"] is None and by_id["live-none"]["seal_end"] == T0 - 7200
    assert by_id["live-bad"]["seal_end_offset_us"] is None
    ring = by_id["ring-legacy"]
    assert (ring["ring_generation"], ring["ring_info_read_seq"], ring["ring_dropped"]) == (3, 1200, 7)


# 4 -----------------------------------------------------------------------------------------------


def test_r4_first_http_upload_makes_every_new_directory_durable(tmp_path, monkeypatch):
    synced: list[Path] = []
    monkeypatch.setattr(spool, "fsync_dir", lambda p: synced.append(Path(p)))
    data = tmp_path / "a" / "b" / "data"
    settings = make_settings(tmp_path, data_dir=data)
    client = TestClient(create_app(settings, start_worker=False))
    capture = str(uuid.uuid4())
    body = live_envelopes(synth_speech_like(1), capture_id=capture, device_id=DEVICE, started_at=STARTED)[0]
    assert put_chunk(client, capture, 0, body).status_code == 201
    raw = data / "raw"
    for created in (tmp_path / "a", tmp_path / "a" / "b", data, raw, raw / DEVICE, raw / DEVICE / capture):
        assert created.parent in synced, created


# 5 -----------------------------------------------------------------------------------------------


class BlockingLlm(FakeLlm):
    def __init__(self) -> None:
        self.calls = 0
        self.started = threading.Event()
        self.release = threading.Event()

    def summarize(self, request):
        self.calls += 1
        if self.calls == 1:
            self.started.set()
            assert self.release.wait(10)
        return super().summarize(request)


def test_r5_reprocess_request_during_a_running_stage_is_kept(client, worker, settings):
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    llm = BlockingLlm()
    worker.providers._llm = llm
    lock = WorkerLock(settings.data_dir)
    assert lock.acquire()  # a worker is "running": the CLI only queues
    try:
        runner = CliRunner()
        assert runner.invoke(cli, ["reprocess", row["id"], "--force-llm"], env=cli_env(settings)).exit_code == 0
        stage = threading.Thread(target=worker.pipeline.advance, args=(row["id"], T0 + 300))
        stage.start()
        assert llm.started.wait(10)
        result = runner.invoke(cli, ["reprocess", row["id"], "--force-llm"], env=cli_env(settings))
        assert result.exit_code == 0 and "queued" in result.output
        llm.release.set()
        stage.join(10)
        worker.tick(T0 + 400)
        assert llm.calls == 2
        after = worker.db.one("SELECT * FROM conversations WHERE id=?", (row["id"],))
        assert after["status"] == "done" and after["force_llm"] == 0
        assert after["reprocess_request"] == after["reprocess_handled"]
    finally:
        llm.release.set()
        lock.release()


# 6 -----------------------------------------------------------------------------------------------


def test_r6_an_interrupted_move_is_finished_on_restart(client, worker, settings, monkeypatch):
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    current = settings.notes_dir / row["note_path"]
    old = settings.notes_dir / "_discarded" / "2026-09-26 1400 abc123.md"
    old.parent.mkdir(parents=True, exist_ok=True)
    old.write_text(current.read_text())
    worker.db.execute("UPDATE conversations SET stale_note_path=? WHERE id=?", ("_discarded/2026-09-26 1400 abc123.md", row["id"]))
    synced: list[Path] = []
    real = spool.fsync_dir
    monkeypatch.setattr(spool, "fsync_dir", lambda p: (synced.append(Path(p)), real(p)))
    Worker(settings, Database(settings.db_path)).tick(T0 + 300)
    assert not old.exists() and current.exists()
    assert old.parent in synced
    assert convs(worker)[0]["stale_note_path"] is None


# 7 -----------------------------------------------------------------------------------------------


def ring_capture_with_dropped(client, *, offset: float, first_sequence: int, dropped: int) -> tuple[str, int]:
    capture = str(uuid.uuid4())
    envs, _ = ring_envelopes(synth_speech_like(2, seed=int(offset) % 5), capture_id=capture, device_id=DEVICE,
                             started_at=STARTED, audio_start_epoch=int(T0 + offset), first_sequence=first_sequence)  # fmt: skip
    bodies = []
    for body in envs:
        env = parse_envelope(body)
        header = env.header.model_dump(mode="json")
        header["ring"]["dropped"] = dropped
        header["capture_started_at"] = iso(T0 + offset + 100)
        bodies.append(build_envelope(header, env.payload))
    upload_all(client, capture, bodies)
    return capture, len(bodies)


def test_r7_dropped_counter_is_reconciled_once_the_generation_is_known(client, worker):
    gen1, n1 = ring_capture_with_dropped(client, offset=-5000, first_sequence=0, dropped=100)
    assert ring_seal(client, gen1, last_chunk_sequence=n1 - 1, covers_until=T0 - 4800, info_read_seq=0).status_code == 200
    worker.tick(T0 - 4700)
    gen2, n2 = ring_capture_with_dropped(client, offset=0, first_sequence=0, dropped=100)  # storage was reset
    worker.tick(T0 + 150)  # processed before its seal: generation still unknown
    r = ring_seal(client, gen2, last_chunk_sequence=n2 - 1, covers_until=T0 + 200, info_read_seq=0, ring={"generation": 2})
    assert r.status_code == 200
    worker.tick(T0 + 250)
    losses = [(r["capture_id"], r["count"]) for r in worker.db.query("SELECT * FROM losses WHERE kind='ring_dropped'")]
    assert sorted(losses) == sorted([(gen1, 100), (gen2, 100)])
    worker.tick(T0 + 260)  # idempotent
    assert len(worker.db.query("SELECT * FROM losses WHERE kind='ring_dropped'")) == 2


# 8 -----------------------------------------------------------------------------------------------


class RnnStyleVad(EnergyVad):
    """A recurrent backend whose state has a different shape than the energy detector's."""

    name = "rnn-style"
    version = "test-1"

    def initial_state(self) -> dict:
        return {"rnn": [0.0]}

    def classify(self, windows, state):
        probs, _ = super().classify(windows, {"floor": -90.0})
        return probs, {"rnn": [state["rnn"][0] + 1]}


def test_r8_changing_vad_backend_between_chunks_keeps_processing(client, settings):
    capture = str(uuid.uuid4())
    pcm = np.concatenate([silence(50), synth_speech_like(20), silence(5)])  # speech straddles the 60 s rotation
    envs = pcm_envelopes(pcm, capture_id=capture, device_id=DEVICE, started_at=STARTED)
    put_chunk(client, capture, 0, envs[0])
    Worker(settings, Database(settings.db_path), vad=VadChoice(EnergyVad(), None)).tick(T0 + 61)
    for seq, body in enumerate(envs[1:], start=1):
        put_chunk(client, capture, seq, body)
    end_us = parse_envelope(envs[-1]).header.chunk_end_offset_us
    seal = {"last_chunk_sequence": len(envs) - 1, "reason": "replay_complete", "ended_at": iso(T0),
            "end_offset_us": end_us, "device_id": DEVICE, "source": "wav_replay"}  # fmt: skip
    assert client.put(f"/v1/captures/{capture}/seal", json=seal, headers=AUTH).status_code == 200
    second = Worker(settings, Database(settings.db_path), vad=VadChoice(RnnStyleVad(), None))
    second.tick(T0 + 400)
    assert [r["status"] for r in second.db.query("SELECT status FROM chunks ORDER BY chunk_sequence")] == ["processed"] * len(envs)
    (row,) = convs(second)
    assert row["start"] == pytest.approx(T0 + 50, abs=0.1) and row["end"] == pytest.approx(T0 + 70, abs=0.3)


def test_r8_same_backend_restores_its_state(settings):
    from omi_notes.audio.vad import VadStream

    stream = VadStream(RnnStyleVad())
    stream.feed(np.zeros(3200, np.int16), 0.0)
    restored = VadStream(RnnStyleVad(), stream.to_state())
    assert restored.model_state == stream.model_state
    assert VadStream(EnergyVad(), stream.to_state()).model_state == EnergyVad().initial_state()
