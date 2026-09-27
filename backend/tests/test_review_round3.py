"""Regressions from the review of the vault + speaker-learning commit (919f7c4)."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
import uuid

import numpy as np
import pytest
from fastapi.testclient import TestClient
from typer.testing import CliRunner

from omi_notes import api as api_mod
from omi_notes import rebuild as rebuild_mod
from omi_notes.api import create_app
from omi_notes.cli import app as cli
from omi_notes.db import Database
from omi_notes.lock import api_lock, worker_lock
from omi_notes.pipeline import conversations as conversations_mod
from omi_notes.pipeline.worker import Worker
from omi_notes.providers.fake import FakeStt
from omi_notes.rebuild import open_index
from omi_notes.speakers import enroll
from omi_notes.speakers import match as speaker_match
from omi_notes.speakers.service import SpeakerService
from omi_notes.util import canonical_json, sha256_hex
from omi_notes.vault import Vault, VaultError

from .conftest import AUTH, cli_env, make_settings
from .helpers import STARTED, T0, convs, replay, silence
from .test_enrollment import CountingStt, start_event
from .test_enrollment import voice as reading
from .test_speaker_learning import ALAN, PRIYA, RAVI, CountingLlm, FakeEmbedder, dialogue, name_label, new_person, talk


def make_env(settings):
    app = create_app(settings, start_worker=False)
    client = TestClient(app)
    worker = Worker(settings, Database(settings.db_path))
    worker.providers._embedder = FakeEmbedder()
    worker.providers._llm = CountingLlm()
    CountingStt.calls = 0
    worker.providers._stt = CountingStt()
    app.state.speakers = SpeakerService(worker.pipeline)
    return client, worker


@pytest.fixture
def env(tmp_path):
    settings = make_settings(tmp_path)
    client, worker = make_env(settings)
    return settings, client, worker


def acknowledge(client, unknown: bool = False) -> None:
    body = {"acknowledged_at": "2026-09-26T12:00:00Z", "unknown_voices_enabled": unknown}
    assert client.put("/v1/speakers/settings", json=body, headers=AUTH).status_code == 200


def voices_file(worker, conv_id: str) -> dict:
    (path,) = worker.vault.conversation_dir(conv_id).glob("voices-*.json")
    return json.loads(path.read_text())


def labels(client, conv_id: str) -> dict:
    return {x["label"]: x for x in client.get(f"/v1/conversations/{conv_id}/speakers", headers=AUTH).json()["labels"]}


# -- 1. one writer per vault ------------------------------------------------------------------------


def test_a_second_backend_on_one_vault_refuses_to_start_even_with_another_index(tmp_path):
    settings = make_settings(tmp_path)
    other = make_settings(tmp_path, index_dir=tmp_path / "another-index")
    with TestClient(create_app(settings, start_worker=False)):
        with pytest.raises(VaultError, match="already serving this vault"):
            with TestClient(create_app(other, start_worker=False)):
                pass
    with TestClient(create_app(other, start_worker=False)):  # free again once the first one stopped
        pass


def test_serve_with_a_worker_refuses_while_a_separate_worker_runs(tmp_path):
    settings = make_settings(tmp_path)
    create_app(settings, start_worker=False)  # creates the vault
    lock = worker_lock(Vault.open(settings))
    assert lock.acquire()
    try:
        with pytest.raises(VaultError, match="worker"):
            with TestClient(create_app(settings, start_worker=True)):
                pass
    finally:
        lock.release()


# -- 2 & 4. enrollment audio is never transcribed ------------------------------------------------------


def test_an_enrollment_that_never_ended_is_still_never_transcribed(env):
    _, client, worker = env
    eid = str(uuid.uuid4())
    capture = replay(client, np.concatenate([silence(2), reading(40, 150), silence(4)]))
    start_event(client, eid, capture, 1.0)  # the phone crashed before writing the end
    worker.tick(T0 + 400)
    later = time.time() + enroll.OPEN_MAX_SECONDS + 60
    worker.tick(later)
    worker.tick(later + 10)
    (row,) = convs(worker)
    assert row["status"] == "discarded" and row["enrollment_id"] == eid, dict(row)
    assert CountingStt.calls == 0
    assert client.get(f"/v1/speakers/enrollments/{eid}", headers=AUTH).json()["state"] == "interrupted"


def enrolled(client, worker) -> dict:
    from .test_enrollment import end_event

    eid = str(uuid.uuid4())
    capture = replay(client, np.concatenate([silence(2), reading(40, 150), silence(4)]))
    start_event(client, eid, capture, 1.0)
    end_event(client, eid, capture, 43.5)
    worker.tick(T0 + 400)
    worker.tick(T0 + 410)
    (row,) = convs(worker)
    assert row["status"] == "discarded" and row["enrollment_id"] == eid
    return row


def test_reprocessing_or_resummarizing_an_enrollment_never_transcribes_it(env):
    _, client, worker = env
    row = enrolled(client, worker)
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1, force_llm = 1")
    worker.tick(T0 + 500)
    worker.tick(T0 + 510)
    (after,) = convs(worker)
    assert after["status"] == "discarded" and CountingStt.calls == 0
    r = client.post(f"/v1/conversations/{row['id']}/resummarize", headers=AUTH)
    assert r.status_code == 409 and r.json()["error"] == "voice_enrollment"


# -- 5, 6, 10. voice vectors follow consent ----------------------------------------------------------


def test_naming_someone_without_consent_never_stores_their_voice(env):
    _, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    priya = new_person(client, "Priya")  # no acknowledgment, no attestation
    assert name_label(client, row["id"], "S2", priya).json()["sample"] == "not_acknowledged"
    me = new_person(client, "Alan", me=True)
    assert name_label(client, row["id"], "S1", me).json()["sample"] == "created"
    stored = voices_file(worker, row["id"])["labels"]
    assert "vector_b64" in stored["S1"] and "vector_b64" not in stored["S2"]
    assert worker.db.one("SELECT vector FROM voices WHERE conversation_id=? AND label='S2'", (row["id"],))["vector"] is None


def test_forgetting_a_person_removes_their_voice_everywhere(env):
    _, client, worker = env
    acknowledge(client, unknown=True)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    priya = new_person(client, "Priya", attest_knows=True)
    assert name_label(client, row["id"], "S2", priya).json()["sample"] == "created"
    assert client.delete(f"/v1/people/{priya}", headers=AUTH).status_code == 200
    stored = voices_file(worker, row["id"])["labels"]
    assert "vector_b64" not in stored["S2"], "even with unknown voices on, a forgotten voice is not kept"
    assert worker.db.one("SELECT vector FROM voices WHERE conversation_id=? AND label='S2'", (row["id"],))["vector"] is None
    worker.tick(T0 + 1000)  # a later pass (relabel, suggestions) does not bring it back
    assert "vector_b64" not in voices_file(worker, row["id"])["labels"]["S2"]


def test_forgetting_me_keeps_the_enrollment_decision_without_the_voice(env):
    _, client, worker = env
    enrolled(client, worker)
    (me,) = [p for p in client.get("/v1/people", headers=AUTH).json()["people"] if p["me"]]
    assert client.delete(f"/v1/people/{me['id']}", headers=AUTH).status_code == 200
    (result,) = (worker.vault.omi / "speakers" / "enrollments").glob("*.json")
    data = json.loads(result.read_text())
    assert data["state"] == "accepted" and data.get("forgotten") is True
    assert "person_id" not in data and "sample_id" not in data
    worker.tick(T0 + 2000)
    people = client.get("/v1/people", headers=AUTH).json()["people"]
    assert [p["samples"] for p in people if p["me"]] == [0], "the note stays; the voice is not learned again"


def test_vector_cleanup_is_restartable(env):
    _, client, worker = env
    acknowledge(client, unknown=True)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    assert "vector_b64" in voices_file(worker, row["id"])["labels"]["S2"]
    worker.pipeline.speakers.update_settings(unknown_voices_enabled=False)  # crashed before pruning
    worker.retention(T0 + 600)
    stored = voices_file(worker, row["id"])["labels"]
    assert "vector_b64" in stored["S1"] and "vector_b64" not in stored["S2"]


def test_unknown_vectors_expire_with_raw_audio_even_after_a_crash(env):
    _, client, worker = env
    acknowledge(client, unknown=True)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    worker.db.execute("UPDATE chunks SET raw_deleted=1")  # raw deleted, crashed before _prune_voices
    worker.retention(T0 + 600)
    stored = voices_file(worker, row["id"])["labels"]
    assert "vector_b64" in stored["S1"] and "vector_b64" not in stored["S2"]


# -- 7. speaker files are recovered ------------------------------------------------------------------


def test_a_label_change_whose_index_write_failed_is_recovered_on_retry(env, monkeypatch):
    _, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    store = client.app.state.speakers.store
    real = store.index_labels
    calls = {"n": 0}

    def failing(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("disk I/O error")
        return real(*args, **kwargs)

    monkeypatch.setattr(store, "index_labels", failing)
    revision = client.get(f"/v1/conversations/{row['id']}/speakers", headers=AUTH).json()["revision"]
    body = {"person_id": me, "expected_revision": revision, "request_id": "retry-me"}
    with pytest.raises(OSError):
        client.put(f"/v1/conversations/{row['id']}/speakers/S1", json=body, headers=AUTH)
    r = client.put(f"/v1/conversations/{row['id']}/speakers/S1", json=body, headers=AUTH)
    assert r.status_code == 200
    assert {x["label"]: x["person_id"] for x in r.json()["labels"]}["S1"] == me
    assert labels(client, row["id"])["S1"]["person_id"] == me


def test_the_startup_sweep_indexes_speaker_files_a_crash_left_behind(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    worker.db.execute("DELETE FROM speaker_labels")  # the index lost the label write…
    worker.db.execute("UPDATE conversations SET speakers_revision=0")
    worker.db.execute("DELETE FROM samples")  # …and the sample
    db = open_index(settings, Vault.open(settings))  # a restart reuses the index and sweeps
    assert db.one("SELECT person_id FROM speaker_labels WHERE conversation_id=? AND label='S1'", (row["id"],))["person_id"] == me
    assert db.one("SELECT COUNT(*) AS n FROM samples")["n"] == 1


# -- 8. background relabeling never overwrites a user correction ------------------------------------------


def test_relabeling_and_a_user_correction_are_serialized(env, monkeypatch):
    _, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    assert name_label(client, row["id"], "S1", me).json()["sample"] == "created"  # voices to relabel
    priya = new_person(client, "Priya")
    worker.db.set_meta("relabel_pending", "1")
    real = speaker_match.assign
    done = threading.Event()
    user_finished_early = {}

    def slow_assign(*args, **kwargs):
        states = real(*args, **kwargs)
        if not done.is_set():
            done.set()
            revision = client.get(f"/v1/conversations/{row['id']}/speakers", headers=AUTH).json()["revision"]
            body = {"person_id": priya, "expected_revision": revision, "request_id": "user-fix"}
            t = threading.Thread(target=lambda: client.put(f"/v1/conversations/{row['id']}/speakers/S2", json=body, headers=AUTH))
            t.start()
            t.join(0.3)
            user_finished_early["value"] = not t.is_alive()
            slow_assign.thread = t
        return states

    monkeypatch.setattr(conversations_mod.speaker_match, "assign", slow_assign)
    worker.pipeline.relabel(T0 + 700)
    slow_assign.thread.join(5)
    assert user_finished_early["value"] is False, "the correction waited for the relabel pass"
    assert labels(client, row["id"])["S2"]["person_id"] == priya


# -- 9 & 11. a new transcript --------------------------------------------------------------------------


def test_a_transcript_replaced_after_the_last_render_is_finished_after_a_rebuild(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    path = worker.vault.conversation_dir(row["id"]) / "transcript.json"
    transcript = json.loads(path.read_text())
    transcript["segments"][0]["text"] = "A newer transcript."  # forced re-STT wrote it, then the crash
    path.write_text(json.dumps(transcript))
    db = open_index(settings, Vault.open(settings), force_rebuild=True)
    fresh = db.one("SELECT * FROM conversations WHERE id=?", (row["id"],))
    assert fresh["status"] == "summarizing"
    assert fresh["transcript_sha"] == sha256_hex(canonical_json(transcript["segments"]).encode())
    worker2 = Worker(settings, db)
    worker2.providers._llm = CountingLlm()
    worker2.tick(T0 + 900)
    assert "A newer transcript." in (settings.vault_dir / row["note_path"]).read_text()


class LaterStt(FakeStt):
    """Misses the first turn: labels are numbered by first appearance, so Priya's voice is now S1."""

    def transcribe(self, request):
        response = super().transcribe(request)
        response["results"]["utterances"] = response["results"]["utterances"][1:]
        return response


def test_retranscription_moves_assignments_with_their_voice_not_their_label_number(env):
    _, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    worker.providers._stt = LaterStt()
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 800)
    worker.tick(T0 + 810)
    after = labels(client, row["id"])
    assert after["S1"]["person_id"] is None, "S1 is Priya's voice now"
    assert after["S2"]["person_id"] == me and after["S2"]["source"] == "user", "Alan's correction followed his voice"
    assert len(list(worker.vault.conversation_dir(row["id"]).glob("voices-*.json"))) == 1


# -- 12. renames re-render notes --------------------------------------------------------------------


def test_renaming_a_person_rerenders_their_notes(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    worker.tick(T0 + 1000)
    assert "[[Alan]]" in (settings.vault_dir / row["note_path"]).read_text()
    assert client.put(f"/v1/people/{me}", json={"name": "Alan Chen"}, headers=AUTH).status_code == 200
    worker.tick(T0 + 1100)
    note = (settings.vault_dir / row["note_path"]).read_text()
    assert "[[Alan Chen]]" in note and "[[Alan]]" not in note


# -- 13. a corrected assignment takes its sample back ---------------------------------------------------


def test_correcting_a_label_removes_the_mistaken_sample(env):
    _, client, worker = env
    acknowledge(client)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    bob = new_person(client, "Bob", attest_knows=True)
    me = new_person(client, "Alan", me=True)
    assert name_label(client, row["id"], "S1", bob).json()["sample"] == "created"
    assert name_label(client, row["id"], "S1", me).json()["sample"] == "created"
    people = {p["name"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}
    assert people["Bob"]["samples"] == 0 and people["Alan"]["samples"] == 1
    assert not list(worker.vault.person_dir(bob).glob("samples/*.json"))
    name_label(client, row["id"], "S1", None)
    people = {p["name"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}
    assert people["Alan"]["samples"] == 0


# -- 14. our own interrupted note write is not a user edit ------------------------------------------------


def test_a_crash_after_writing_a_note_is_not_mistaken_for_a_user_edit(env, monkeypatch):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    pipeline = worker.pipeline
    real = pipeline._commit
    state = {"failed": False}

    def crash_once(conv_id, **fields):
        if "written_sha" in fields and not state["failed"]:
            state["failed"] = True
            raise OSError("crashed after the note write")
        return real(conv_id, **fields)

    monkeypatch.setattr(pipeline, "_commit", crash_once)
    worker.tick(T0 + 1000)
    assert state["failed"] and "[[Alan]]" in (settings.vault_dir / row["note_path"]).read_text()
    worker.tick(T0 + 5000)
    (after,) = [r for r in convs(worker) if r["id"] == row["id"]]
    assert after["edited"] == 0 and after["needs_render"] == 0, dict(after)


# == second pass (review of 7e41e5a) ==================================================================


def test_a_rejected_second_server_writes_nothing(tmp_path, monkeypatch):
    settings = make_settings(tmp_path)
    with TestClient(create_app(settings, start_worker=False)):
        opened = []
        monkeypatch.setattr(api_mod, "open_index", lambda *a, **k: opened.append(1))
        other = make_settings(tmp_path, index_dir=tmp_path / "another-index", timezone="Europe/Berlin")
        with pytest.raises(VaultError, match="already serving"):
            create_app(other, start_worker=False)
        assert not opened, "no index sweep"
        assert "Europe/Berlin" not in (settings.vault_dir / "_omi" / "VAULT.json").read_text()


def test_rebuild_index_keeps_servers_out_while_it_runs(tmp_path, monkeypatch):
    settings = make_settings(tmp_path)
    create_app(settings, start_worker=False)
    seen = {}
    real = rebuild_mod.open_index

    def watching(*args, **kwargs):
        seen["serving_blocked"] = api_lock(Vault.open(settings)).held_elsewhere()
        return real(*args, **kwargs)

    monkeypatch.setattr(rebuild_mod, "open_index", watching)
    result = CliRunner().invoke(cli, ["rebuild-index"], env=cli_env(settings))
    assert result.exit_code == 0, result.output
    assert seen["serving_blocked"] is True


def test_a_forgotten_voice_stays_forgotten_after_retranscription(env):
    _, client, worker = env
    acknowledge(client, unknown=True)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    priya = new_person(client, "Priya", attest_knows=True)
    name_label(client, row["id"], "S2", priya)
    assert client.delete(f"/v1/people/{priya}", headers=AUTH).status_code == 200
    worker.providers._stt = LaterStt()  # Priya's voice is S1 now
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 800)
    worker.tick(T0 + 810)
    stored = voices_file(worker, row["id"])["labels"]
    assert "vector_b64" not in stored["S1"], "the forgotten voice was stored again under its new label"


def test_raw_expiry_resumes_after_a_crash_between_deleting_files_and_the_index(env, monkeypatch):
    settings, client, worker = env
    acknowledge(client, unknown=True)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    assert "vector_b64" in voices_file(worker, row["id"])["labels"]["S2"]
    later = time.time() + (settings.raw_retention_days + 1) * 86400
    real_tx = worker.db.tx
    calls = {"n": 0}

    def flaky():
        calls["n"] += 1
        if calls["n"] == 1:
            raise sqlite3.OperationalError("disk I/O error")
        return real_tx()

    monkeypatch.setattr(worker.db, "tx", flaky)
    worker.retention(later)
    assert not list(settings.vault_dir.rglob("*.omnc")), "the files were deleted…"
    assert worker.db.one("SELECT COUNT(*) AS n FROM chunks WHERE raw_deleted=0")["n"] > 0, "…the index commit was not"
    monkeypatch.setattr(worker.db, "tx", real_tx)
    worker.retention(later + 10)
    assert worker.db.one("SELECT COUNT(*) AS n FROM chunks WHERE raw_deleted=0")["n"] == 0
    stored = voices_file(worker, row["id"])["labels"]
    assert "vector_b64" in stored["S1"] and "vector_b64" not in stored["S2"]


def test_vector_reconciliation_waits_for_a_speaker_change_in_progress(env):
    _, _, worker = env
    store = worker.pipeline.speakers
    entered, release, finished = threading.Event(), threading.Event(), threading.Event()

    def holder():
        with store.lock:
            entered.set()
            release.wait(5)

    t = threading.Thread(target=holder)
    t.start()
    assert entered.wait(5)
    r = threading.Thread(target=lambda: (store.reconcile_vectors(), finished.set()))
    r.start()
    assert not finished.wait(0.3), "reconciliation ran while a speaker change held the lock"
    release.set()
    t.join(5)
    r.join(5)
    assert finished.is_set()


def test_a_retranscription_that_crashed_before_its_voices_stage_never_misnames_after_a_rebuild(env, monkeypatch):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    worker.tick(T0 + 700)
    assert "[[Alan]]" in (settings.vault_dir / row["note_path"]).read_text()
    worker.providers._stt = LaterStt()

    def crash(*args, **kwargs):
        raise OSError("crashed right after transcript.json")

    monkeypatch.setattr(worker.pipeline, "identify", crash)
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 800)
    db = open_index(settings, Vault.open(settings), force_rebuild=True)
    fresh = Worker(settings, db)
    fresh.providers._embedder, fresh.providers._llm = FakeEmbedder(), CountingLlm()
    fresh.tick(T0 + 900)
    fresh.tick(T0 + 910)
    assert db.one("SELECT person_id FROM speaker_labels WHERE conversation_id=? AND label='S1'", (row["id"],)) is None
    assert "[[Alan]]" not in (settings.vault_dir / row["note_path"]).read_text(), "Priya's voice is S1 now"
    assert not list(worker.vault.conversation_dir(row["id"]).glob("voices-*.json")), "the old voices no longer apply"


class ShorterStt(FakeStt):
    """Misses the last turn: a new transcript, but S1 is still the first voice."""

    def transcribe(self, request):
        response = super().transcribe(request)
        response["results"]["utterances"] = response["results"]["utterances"][:-1]
        return response


def test_a_retranscription_that_kept_the_voices_keeps_the_names_even_when_retried(env, monkeypatch):
    _, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    store = worker.pipeline.speakers
    real = store.write_labels
    calls = {"n": 0}

    def failing(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("crashed after the voices file")
        return real(*args, **kwargs)

    monkeypatch.setattr(store, "write_labels", failing)
    worker.providers._stt = ShorterStt()
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 800)
    worker.tick(T0 + 5000)
    worker.tick(T0 + 5010)
    assert calls["n"] >= 2
    after = labels(client, row["id"])
    assert after["S1"]["person_id"] == me and after["S1"]["source"] == "user", "same voice: the correction carried over"


def test_a_retried_voices_stage_finishes_the_label_move(env, monkeypatch):
    _, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    store = worker.pipeline.speakers
    real = store.write_labels
    calls = {"n": 0}

    def failing(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("crashed after the voices file")
        return real(*args, **kwargs)

    monkeypatch.setattr(store, "write_labels", failing)
    worker.providers._stt = LaterStt()
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 800)
    assert calls["n"] == 1
    worker.tick(T0 + 5000)
    worker.tick(T0 + 5010)
    assert labels(client, row["id"])["S1"]["person_id"] is None
    assert len(list(worker.vault.conversation_dir(row["id"]).glob("voices-*.json"))) == 1


def test_a_correction_during_a_render_is_rendered_too(env, monkeypatch):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    pipeline = worker.pipeline
    real = pipeline.voice_names
    raced = {}

    def racing(conv_id):
        names = real(conv_id)
        if not raced:
            raced["yes"] = True
            priya = new_person(client, "Priya")
            assert name_label(client, row["id"], "S2", priya).status_code == 200
        return names

    monkeypatch.setattr(pipeline, "voice_names", racing)
    worker.tick(T0 + 1000)  # renders the names read before the correction
    monkeypatch.setattr(pipeline, "voice_names", real)
    worker.tick(T0 + 1100)
    assert raced and "[[Priya]]" in (settings.vault_dir / row["note_path"]).read_text()


def test_a_label_request_that_failed_after_its_file_write_still_renders(env, monkeypatch):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    worker.tick(T0 + 600)
    pipeline = worker.pipeline
    real = pipeline._set
    failed = {}

    def failing(conv_id, **fields):
        if fields.get("needs_render") == 1 and not failed:
            failed["yes"] = True
            raise OSError("crashed before scheduling the render")
        return real(conv_id, **fields)

    monkeypatch.setattr(pipeline, "_set", failing)
    revision = client.get(f"/v1/conversations/{row['id']}/speakers", headers=AUTH).json()["revision"]
    body = {"person_id": me, "expected_revision": revision, "request_id": "once"}
    with pytest.raises(OSError):
        client.put(f"/v1/conversations/{row['id']}/speakers/S1", json=body, headers=AUTH)
    monkeypatch.setattr(pipeline, "_set", real)
    assert client.put(f"/v1/conversations/{row['id']}/speakers/S1", json=body, headers=AUTH).status_code == 200
    worker.tick(T0 + 1000)
    assert "[[Alan]]" in (settings.vault_dir / row["note_path"]).read_text()


def active_me(client, worker) -> tuple[str, list[dict]]:
    me = new_person(client, "Alan", me=True)
    rows = []
    for day in (6, 5, 4):
        row = talk(client, worker, dialogue(ALAN, RAVI, seed=day), day=day)
        assert name_label(client, row["id"], "S1", me).json()["sample"] == "created"
        rows.append(row)
    assert {p["name"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}["Alan"]["auto_active"]
    return me, rows


def test_taking_back_a_confirmation_withdraws_automatic_names_it_enabled(env):
    _, client, worker = env
    me, rows = active_me(client, worker)
    fresh = talk(client, worker, dialogue(ALAN, PRIYA, seed=40), day=1)
    assert labels(client, fresh["id"])["S1"]["person_id"] == me
    name_label(client, rows[0]["id"], "S1", None)  # Alan now has two confirmations: not active
    assert labels(client, fresh["id"])["S1"]["person_id"] is None


def test_an_enrollment_sample_whose_index_write_failed_is_not_duplicated(env, monkeypatch):
    _, client, worker = env
    store = worker.pipeline.speakers
    real = store._index_sample
    calls = {"n": 0}

    def flaky(data):
        calls["n"] += 1
        if calls["n"] == 1:
            raise sqlite3.OperationalError("disk I/O error")
        return real(data)

    monkeypatch.setattr(store, "_index_sample", flaky)
    enrolled(client, worker)
    worker.tick(T0 + 420)
    assert calls["n"] >= 2
    assert len(list(worker.vault.people.glob("*/samples/*.json"))) == 1


def test_identification_uses_the_voices_known_after_embedding(env, monkeypatch):
    _, client, worker = env
    me, _ = active_me(client, worker)
    real = conversations_mod.embed_voices
    forgot = {}

    def forgetting(*args, **kwargs):
        if not forgot:
            forgot["yes"] = True
            assert client.delete(f"/v1/people/{me}", headers=AUTH).status_code == 200
        return real(*args, **kwargs)

    monkeypatch.setattr(conversations_mod, "embed_voices", forgetting)
    fresh = talk(client, worker, dialogue(ALAN, PRIYA, seed=40), day=1)
    assert forgot and labels(client, fresh["id"])["S1"]["person_id"] is None


# == third pass (review of 00da03c) ===================================================================


def test_obsolete_voices_files_are_removed_by_the_sweep_and_by_forget(env):
    settings, client, worker = env
    acknowledge(client)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    priya = new_person(client, "Priya", attest_knows=True)
    assert name_label(client, row["id"], "S2", priya).json()["sample"] == "created"
    conv_dir = worker.vault.conversation_dir(row["id"])
    (current,) = conv_dir.glob("voices-*.json")
    stale = conv_dir / (current.name[: -len("00000000.json")] + "0badc0de.json")  # an earlier transcript's
    stale.write_bytes(current.read_bytes())  # left behind by a crash before the cleanup
    open_index(settings, Vault.open(settings))  # a restart sweeps it
    assert not stale.exists() and current.exists()
    stale.write_bytes(current.read_bytes())
    assert client.delete(f"/v1/people/{priya}", headers=AUTH).status_code == 200
    assert not stale.exists(), "forget covers every voices generation"


class OnlyFirstVoiceStt(FakeStt):
    """Transcribes only the first voice's turns (S1)."""

    def transcribe(self, request):
        response = super().transcribe(request)
        response["results"]["utterances"] = [u for u in response["results"]["utterances"] if u["speaker"] == 0]
        return response


def test_forgetting_survives_a_transcript_without_that_voice(env):
    _, client, worker = env
    acknowledge(client, unknown=True)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    priya = new_person(client, "Priya", attest_knows=True)
    name_label(client, row["id"], "S2", priya)
    assert client.delete(f"/v1/people/{priya}", headers=AUTH).status_code == 200

    def retranscribe(stt, at):
        worker.providers._stt = stt
        worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?",
                          (row["id"],))  # fmt: skip
        worker.tick(at)
        worker.tick(at + 10)

    retranscribe(OnlyFirstVoiceStt(), T0 + 800)  # Priya isn't in this transcript at all
    assert set(voices_file(worker, row["id"])["labels"]) == {"S1"}
    retranscribe(CountingStt(), T0 + 900)  # …and is back in this one, as S2
    stored = voices_file(worker, row["id"])["labels"]
    assert "vector_b64" not in stored["S2"], "the forgotten voice was stored again"


def test_relabeling_never_moves_labels_to_a_transcript_they_were_not_made_for(env, monkeypatch):
    settings, client, worker = env
    acknowledge(client, unknown=True)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    store = worker.pipeline.speakers
    real = store.write_labels
    calls = {"n": 0}

    def failing(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("crashed after the voices file")
        return real(*args, **kwargs)

    monkeypatch.setattr(store, "write_labels", failing)
    worker.providers._stt = LaterStt()  # Priya's voice becomes S1
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 800)
    assert calls["n"] == 1
    db = open_index(settings, Vault.open(settings), force_rebuild=True)
    fresh = Worker(settings, db)
    fresh.providers._embedder, fresh.providers._llm = FakeEmbedder(), CountingLlm()
    db.set_meta("relabel_pending", "1")  # relabel runs before the summary
    fresh.tick(T0 + 900)
    fresh.tick(T0 + 910)
    s1 = db.one("SELECT person_id FROM speaker_labels WHERE conversation_id=? AND label='S1'", (row["id"],))
    assert s1 is None or s1["person_id"] is None, "Priya's voice is S1 now"
    note = (settings.vault_dir / row["note_path"]).read_text()
    assert "'S1: [[Alan]]'" not in note and "'S2: [[Alan]]'" in note, "the correction followed Alan's voice"


# == fourth pass (review of 5749f76) ==================================================================


def test_a_second_voices_file_for_the_same_transcript_is_removed(env):
    """E.g. a new speaker model, crashed before its labels committed: only the referenced file counts."""
    settings, client, worker = env
    acknowledge(client)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    priya = new_person(client, "Priya", attest_knows=True)
    name_label(client, row["id"], "S2", priya)
    conv_dir = worker.vault.conversation_dir(row["id"])
    (current,) = conv_dir.glob("voices-*.json")
    orphan = conv_dir / current.name.replace("voices-fake-voice-", "voices-newer-model-")
    orphan.write_bytes(current.read_bytes())
    open_index(settings, Vault.open(settings))
    assert not orphan.exists() and current.exists()
    orphan.write_bytes(current.read_bytes())
    assert client.delete(f"/v1/people/{priya}", headers=AUTH).status_code == 200
    assert not orphan.exists()
    assert "vector_b64" not in json.loads(current.read_text())["labels"]["S2"]


def crash_first_label_write(monkeypatch, store) -> dict:
    real = store.write_labels
    calls = {"n": 0}

    def failing(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("crashed after the voices file")
        return real(*args, **kwargs)

    monkeypatch.setattr(store, "write_labels", failing)
    return calls


def test_a_pending_label_move_keeps_its_evidence_through_a_restart(env, monkeypatch):
    settings, client, worker = env
    acknowledge(client, unknown=True)
    me = new_person(client, "Alan", me=True)
    earlier = talk(client, worker, dialogue(ALAN, RAVI), day=3)
    name_label(client, earlier["id"], "S1", me)  # Alan has a voice, so voices are computed from now on
    row = talk(client, worker, dialogue(PRIYA, RAVI))
    assert voices_file(worker, row["id"])["labels"]["S1"].get("vector_b64")
    assert name_label(client, row["id"], "S1", None, not_person_id=me).status_code == 200  # "not Alan"
    calls = crash_first_label_write(monkeypatch, worker.pipeline.speakers)
    worker.providers._stt = ShorterStt()  # new words, same voices
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 800)
    assert calls["n"] == 1
    open_index(settings, Vault.open(settings))  # a restart sweeps before the move is retried
    worker.tick(T0 + 5000)
    worker.tick(T0 + 5010)
    s1 = worker.db.one("SELECT not_json FROM speaker_labels WHERE conversation_id=? AND label='S1'", (row["id"],))
    assert s1 is not None and me in json.loads(s1["not_json"]), "the block followed the unchanged voice"


def test_forgetting_during_an_interrupted_label_move_removes_the_right_voice(env, monkeypatch):
    _, client, worker = env
    acknowledge(client, unknown=True)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    priya = new_person(client, "Priya", attest_knows=True)
    name_label(client, row["id"], "S2", priya)
    calls = crash_first_label_write(monkeypatch, worker.pipeline.speakers)
    worker.providers._stt = LaterStt()  # Priya's voice becomes S1, Alan's S2
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 800)
    assert calls["n"] == 1
    assert client.delete(f"/v1/people/{priya}", headers=AUTH).status_code == 200  # before the worker retries
    files = list(worker.vault.conversation_dir(row["id"]).glob("voices-*.json"))
    assert len(files) == 1
    stored = json.loads(files[0].read_text())["labels"]
    assert "vector_b64" not in stored["S1"], "Priya's voice (now S1) is gone"
    assert "vector_b64" in stored["S2"], "Alan's voice (now S2) is kept"
    assert labels(client, row["id"])["S2"]["person_id"] == me


# == fifth pass (review of 32c1bb0) ===================================================================


def named_pair(client, worker, *, unknown: bool = True) -> tuple[dict, str, str]:
    acknowledge(client, unknown=unknown)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    priya = new_person(client, "Priya", attest_knows=True)
    name_label(client, row["id"], "S2", priya)
    return row, me, priya


def force_restt(worker, row, stt) -> None:
    worker.providers._stt = stt
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?", (row["id"],))


def test_forgetting_while_the_worker_embeds_a_new_transcript_never_keeps_that_voice(env, monkeypatch):
    _, client, worker = env
    row, _, priya = named_pair(client, worker)
    real = conversations_mod.embed_voices
    forgot = {}

    def forgetting(*args, **kwargs):
        if not forgot:  # the worker is embedding, outside the speaker lock
            forgot["status"] = client.delete(f"/v1/people/{priya}", headers=AUTH).status_code
        return real(*args, **kwargs)

    monkeypatch.setattr(conversations_mod, "embed_voices", forgetting)
    force_restt(worker, row, ShorterStt())  # new words; Priya is still S2
    worker.tick(T0 + 800)
    worker.tick(T0 + 810)
    assert forgot["status"] == 200
    stored = voices_file(worker, row["id"])["labels"]
    assert "vector_b64" not in stored["S2"], "the forgotten voice was stored as an unknown voice"


def test_forgetting_with_the_index_behind_the_labels_file_prunes_the_right_voice(env, monkeypatch):
    _, client, worker = env
    row, me, priya = named_pair(client, worker)
    store = worker.pipeline.speakers
    real = store.index_labels
    calls = {"n": 0}

    def failing(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("disk I/O error")
        return real(*args, **kwargs)

    monkeypatch.setattr(store, "index_labels", failing)
    force_restt(worker, row, LaterStt())  # Priya's voice becomes S1, Alan's S2
    worker.tick(T0 + 800)  # speakers.json committed the move; the index write failed
    assert calls["n"] == 1
    assert client.delete(f"/v1/people/{priya}", headers=AUTH).status_code == 200
    stored = voices_file(worker, row["id"])["labels"]
    assert "vector_b64" not in stored["S1"] and "vector_b64" in stored["S2"]
    assert labels(client, row["id"])["S2"]["person_id"] == me


def test_a_confirmation_can_be_taken_back_after_its_voice_moved_to_another_label(env):
    _, client, worker = env
    acknowledge(client)
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S2", me)  # Alan has a voice, so voices are compared on re-transcription
    bob = new_person(client, "Bob", attest_knows=True)
    assert name_label(client, row["id"], "S1", bob).json()["sample"] == "created"  # a mistake: S1 is Alan
    force_restt(worker, row, LaterStt())  # that voice is S2 now
    worker.tick(T0 + 800)
    worker.tick(T0 + 810)
    assert labels(client, row["id"])["S2"]["person_id"] == bob
    assert name_label(client, row["id"], "S2", None, not_person_id=bob).status_code == 200  # "not Bob"
    people = {p["name"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}
    assert people["Bob"]["samples"] == 0, "the repudiated sample was taken back"
