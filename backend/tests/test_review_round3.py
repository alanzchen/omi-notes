"""Regressions from the review of the vault + speaker-learning commit (919f7c4)."""

from __future__ import annotations

import json
import threading
import time
import uuid

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.lock import worker_lock
from omi_notes.pipeline import conversations as conversations_mod
from omi_notes.pipeline.worker import Worker
from omi_notes.providers.fake import FakeStt
from omi_notes.rebuild import open_index
from omi_notes.speakers import enroll
from omi_notes.speakers import match as speaker_match
from omi_notes.speakers.service import SpeakerService
from omi_notes.util import canonical_json, sha256_hex
from omi_notes.vault import Vault, VaultError

from .conftest import AUTH, make_settings
from .helpers import STARTED, T0, convs, replay, silence
from .test_enrollment import CountingStt, start_event
from .test_enrollment import voice as reading
from .test_speaker_learning import ALAN, PRIYA, CountingLlm, FakeEmbedder, dialogue, name_label, new_person, talk


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


def test_retranscription_recomputes_voices_and_drops_assignments_of_the_old_labels(env):
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
    assert after["S2"]["distance"] < after["S1"]["distance"], "the voices were recomputed for the new labels"


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
