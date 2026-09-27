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

from omi_notes import legacy as dbmod  # the pre-vault ledger (migrate-vault reads it)
from omi_notes import spool
from omi_notes.api import create_app
from omi_notes.audio.vad import EnergyVad, VadChoice
from omi_notes.cli import app as cli
from omi_notes.db import Database
from omi_notes.devtools import live_envelopes, pcm_envelopes, ring_envelopes, synth_speech_like
from omi_notes.envelope import build_envelope, parse_envelope
from omi_notes.lock import worker_lock
from omi_notes.pipeline.worker import Worker
from omi_notes.providers.fake import FakeLlm
from omi_notes.vault import Vault

from .conftest import AUTH, DEVICE, cli_env, make_settings, put_chunk, upload_all
from .helpers import STARTED, T0, convs, event, iso, live, live_seal, replay, ring_seal, ring_sync, silence, timedelta

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
    db = dbmod.open_legacy(path)
    by_id = {r["capture_id"]: r for r in db.execute("SELECT * FROM capture_times").fetchall()}
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
    vault = tmp_path / "a" / "b" / "vault"
    settings = make_settings(tmp_path, vault_dir=vault)
    client = TestClient(create_app(settings, start_worker=False))
    capture = str(uuid.uuid4())
    body = live_envelopes(synth_speech_like(1), capture_id=capture, device_id=DEVICE, started_at=STARTED)[0]
    assert put_chunk(client, capture, 0, body).status_code == 201
    raw = vault / "_omi" / "raw"
    for created in (tmp_path / "a", tmp_path / "a" / "b", vault, vault / "_omi", raw, raw / DEVICE, raw / DEVICE / capture):
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
    lock = worker_lock(Vault.open(settings))
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
    current = settings.vault_dir / row["note_path"]
    old = settings.vault_dir / "_discarded" / "2026-09-26 1400 abc123.md"
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


# round 2 follow-up ---------------------------------------------------------------------------------


def test_r2b_1_an_undeletable_stale_note_never_blocks_other_work(client, worker, settings):
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    old = settings.vault_dir / "_discarded" / "undeletable.md"
    old.parent.mkdir(exist_ok=True)
    old.write_text("old copy")
    worker.db.execute("UPDATE conversations SET stale_note_path=? WHERE id=?", ("_discarded/undeletable.md", row["id"]))
    later = replay(client, SPEECH, start=STARTED + timedelta(hours=1))
    old.parent.chmod(0o555)  # a real permission error, not a mocked remover
    try:
        worker.tick(T0 + 4000)
        worker.tick(T0 + 4005)
        statuses = [r["status"] for r in worker.db.query("SELECT status FROM chunks WHERE capture_id=?", (later,))]
        assert statuses and set(statuses) == {"processed"}
        assert worker.db.one("SELECT stale_note_path FROM conversations WHERE id=?", (row["id"],))[0] is not None
        assert "undeletable.md" in (settings.vault_dir / "_status.md").read_text()
    finally:
        old.parent.chmod(0o755)
    worker.tick(T0 + 4010)  # still backing off
    assert old.exists()
    worker.tick(T0 + 4100)
    assert not old.exists()
    assert worker.db.one("SELECT stale_note_path, error FROM conversations WHERE id=?", (row["id"],))[:] == (None, None)


@pytest.mark.parametrize("step", ["segment_device", "advance"])
def test_r2b_1_one_bad_row_does_not_stall_the_rest(client, worker, monkeypatch, step):
    replay(client, SPEECH)
    replay(client, SPEECH, start=STARTED + timedelta(hours=1))
    if step == "segment_device":
        other = "22222222-2222-4333-8444-555555555555"
        capture = str(uuid.uuid4())
        envs = pcm_envelopes(SPEECH, capture_id=capture, device_id=other, started_at=STARTED)
        upload_all(client, capture, envs)
        real = worker.segment_device
        monkeypatch.setattr(worker, "segment_device", lambda d, now: (_ for _ in ()).throw(RuntimeError("boom"))
                            if d == DEVICE else real(d, now))  # fmt: skip
        worker.tick(T0 + 5000)
        assert [r["device_id"] for r in convs(worker)] == [other]
    else:
        worker.pipeline.run = lambda now, limit=20: 0
        worker.tick(T0 + 5000)
        del worker.pipeline.run
        first, second = convs(worker)
        real = worker.pipeline._advance
        monkeypatch.setattr(worker.pipeline, "_advance", lambda cid, now: (_ for _ in ()).throw(PermissionError("cache"))
                            if cid == first["id"] else real(cid, now))  # fmt: skip
        worker.tick(T0 + 5010)
        assert [r["status"] for r in convs(worker)] == ["closed", "done"]


def test_r2b_2_migration_turns_queued_force_flags_into_requests(tmp_path):
    path = tmp_path / "v2.sqlite3"
    conn = sqlite3.connect(path, isolation_level=None)
    conn.executescript("BEGIN;" + dbmod.MIGRATIONS[0] + "; PRAGMA user_version=1; COMMIT;")
    conn.executescript("BEGIN;" + dbmod.MIGRATIONS[1] + "; PRAGMA user_version=2; COMMIT;")
    for cid, flags in (("queued-llm", (0, 1)), ("queued-stt", (1, 0)), ("idle", (0, 0))):
        conn.execute(
            """INSERT INTO conversations (id, device_id, start, end, status, created_at, updated_at, force_restt, force_llm)
               VALUES (?,?,1,2,'summarizing',1,1,?,?)""",
            (cid, DEVICE, *flags),
        )
    conn.close()
    db = dbmod.open_legacy(path)
    rows = {r["id"]: (r["reprocess_request"], r["reprocess_handled"]) for r in db.execute("SELECT * FROM conversations")}
    assert rows == {"queued-llm": (1, 0), "queued-stt": (1, 0), "idle": (0, 0)}


class CountingLlm(FakeLlm):
    calls = 0

    def summarize(self, request):
        CountingLlm.calls += 1
        return super().summarize(request)


def test_r2b_3_late_loss_evidence_updates_a_finalized_note_without_provider_calls(client, worker, settings):
    gen1, n1 = ring_capture_with_dropped(client, offset=-5000, first_sequence=0, dropped=100)
    ring_seal(client, gen1, last_chunk_sequence=n1 - 1, covers_until=T0 - 4800, info_read_seq=0)
    worker.tick(T0 - 4700)
    gen2, n2 = ring_capture_with_dropped(client, offset=0, first_sequence=0, dropped=100)
    CountingLlm.calls = 0
    worker.providers._llm = CountingLlm()
    worker.tick(T0 + 1600)  # finalized provisionally before its seal says "generation 2"
    row = next(r for r in convs(worker) if r["start"] >= T0)
    assert row["status"] == "done" and row["lost_seconds"] == 0
    calls = CountingLlm.calls
    ring_seal(client, gen2, last_chunk_sequence=n2 - 1, covers_until=T0 + 200, info_read_seq=0, ring={"generation": 2})
    worker.tick(T0 + 1700)
    row = next(r for r in convs(worker) if r["start"] >= T0)
    assert row["lost_seconds"] > 5 and json.loads(row["gaps_json"])
    text = (settings.vault_dir / row["note_path"]).read_text()
    assert "Audio missing" in text and "audio_lost_s: 0.0" not in text
    assert CountingLlm.calls == calls and row["revision"] == 2


# round 3 follow-up ---------------------------------------------------------------------------------


def test_r3b_2_migration_4_repairs_force_flags_stranded_by_an_earlier_migration_3(tmp_path):
    path = tmp_path / "v3.sqlite3"
    conn = sqlite3.connect(path, isolation_level=None)
    for version, migration in enumerate(dbmod.MIGRATIONS[:3], start=1):
        if callable(migration):
            conn.execute("BEGIN")
            migration(conn)
            conn.execute(f"PRAGMA user_version={version}")
            conn.execute("COMMIT")
        else:
            conn.executescript(f"BEGIN;{migration}; PRAGMA user_version={version}; COMMIT;")
    # What the earlier migration 3 left behind: a force flag with no pending request.
    conn.execute(
        """INSERT INTO conversations (id, device_id, start, end, status, created_at, updated_at, force_llm,
           reprocess_request, reprocess_handled) VALUES ('stranded', ?, 1, 2, 'done', 1, 1, 1, 0, 0)""",
        (DEVICE,),
    )
    conn.execute(
        """INSERT INTO conversations (id, device_id, start, end, status, created_at, updated_at, force_llm,
           reprocess_request, reprocess_handled) VALUES ('pending', ?, 1, 2, 'done', 1, 1, 1, 3, 2)""",
        (DEVICE,),
    )
    conn.close()
    db = dbmod.open_legacy(path)
    rows = {r["id"]: (r["reprocess_request"], r["reprocess_handled"]) for r in db.execute("SELECT * FROM conversations")}
    assert rows == {"stranded": (1, 0), "pending": (3, 2)}


def test_r3b_3_crash_before_refresh_does_not_skip_the_late_loss_update(client, worker, settings, monkeypatch):
    gen1, n1 = ring_capture_with_dropped(client, offset=-5000, first_sequence=0, dropped=100)
    ring_seal(client, gen1, last_chunk_sequence=n1 - 1, covers_until=T0 - 4800, info_read_seq=0)
    worker.tick(T0 - 4700)
    gen2, n2 = ring_capture_with_dropped(client, offset=0, first_sequence=0, dropped=100)
    worker.tick(T0 + 1600)  # finalized before its seal says "generation 2"
    ring_seal(client, gen2, last_chunk_sequence=n2 - 1, covers_until=T0 + 200, info_read_seq=0, ring={"generation": 2})

    # Crash right after the loss rows are committed, before finalized conversations are refreshed.
    real = worker.refresh_losses
    monkeypatch.setattr(worker, "refresh_losses", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("crash")))
    worker.tick(T0 + 1700)
    assert worker.db.one("SELECT dropped_reconciled FROM captures WHERE capture_id=?", (gen2,))["dropped_reconciled"] == 0
    monkeypatch.setattr(worker, "refresh_losses", real)

    worker.tick(T0 + 1800)  # "after restart": the evidence is complete, so the refresh is redone
    row = next(r for r in convs(worker) if r["start"] >= T0)
    assert row["lost_seconds"] > 5 and json.loads(row["gaps_json"])
    assert "Audio missing" in (settings.vault_dir / row["note_path"]).read_text()
    assert worker.db.one("SELECT dropped_reconciled FROM captures WHERE capture_id=?", (gen2,))["dropped_reconciled"] == 1


def test_r4_crash_while_a_loss_estimate_shrinks_leaves_no_stale_warning(client, worker, settings, monkeypatch):
    # No earlier capture is known yet, so gen2's cumulative dropped counter reads as 100 new losses.
    gen2, n2 = ring_capture_with_dropped(client, offset=0, first_sequence=0, dropped=100)
    worker.tick(T0 + 1600)
    row = next(r for r in convs(worker) if r["start"] >= T0)
    assert row["status"] == "done" and row["lost_seconds"] > 5

    # The earlier capture of the same generation arrives: its counter was already 100, so the
    # estimate shrinks to nothing. Crash while refreshing the finalized note.
    gen1, n1 = ring_capture_with_dropped(client, offset=-5000, first_sequence=0, dropped=100)
    ring_seal(client, gen1, last_chunk_sequence=n1 - 1, covers_until=T0 - 4800, info_read_seq=0)
    real = worker.refresh_losses
    monkeypatch.setattr(worker, "refresh_losses", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("crash")))
    worker.tick(T0 + 1700)
    monkeypatch.setattr(worker, "refresh_losses", real)

    worker.tick(T0 + 1800)  # "after restart"
    row = next(r for r in convs(worker) if r["start"] >= T0)
    assert row["lost_seconds"] == 0, "the shrunk loss must be removed from the finalized note"
    assert "Audio missing" not in (settings.vault_dir / row["note_path"]).read_text()
