"""Regressions for Astra's fourth review of the Voices hub fixes."""

from __future__ import annotations

import json

import pytest

from omi_notes.speakers import journal
from omi_notes.vault import Vault

from .conftest import AUTH
from .test_speaker_learning import ALAN, PRIYA, dialogue, env, name_label, new_person, talk  # noqa: F401
from .test_speaker_review_fixes import consented_priya, import_range, journal_files, monologue_row
from .test_speaker_review_fixes2 import crash_on
from .test_speaker_samples import MODEL, me_with_samples, review, decide, sample_file  # noqa: F401


def unfinished_forget(client, worker, monkeypatch, person_id):
    pipeline = worker.pipeline
    real = pipeline.sync_labels_everywhere
    monkeypatch.setattr(pipeline, "sync_labels_everywhere", lambda: (_ for _ in ()).throw(OSError("power cut")))
    with pytest.raises(OSError):
        client.delete(f"/v1/people/{person_id}", headers=AUTH)
    monkeypatch.setattr(pipeline, "sync_labels_everywhere", real)


# -- 1: an assignment's revision check uses the revision after recovery ------------------------------------------------


def test_an_assignment_expecting_the_revision_before_recovery_is_stale(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    store = worker.pipeline.speakers
    restore = crash_on(monkeypatch, store, "set_sample_state", "move")
    with pytest.raises(OSError):
        client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": priya, "request_id": "a-1"}, headers=AUTH)
    restore()
    seen = worker.db.one("SELECT speakers_revision FROM conversations WHERE id=?", (rows[0]["id"],))[0]
    body = {"person_id": None, "not_person_id": priya, "expected_revision": seen, "request_id": "a-2"}
    r = client.put(f"/v1/conversations/{rows[0]['id']}/speakers/S1", json=body, headers=AUTH)
    assert r.status_code == 409 and r.json()["error"] == "stale_revision", r.text  # recovery renamed the label meanwhile


# -- 2: an undo never restores voice data for a person whose forget is unfinished ---------------------------------------


def test_undo_of_a_remove_waits_for_an_unfinished_forget(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    assert client.post(f"/v1/samples/{ids[0]}/remove", json={"request_id": "u-r"}, headers=AUTH).status_code == 200
    unfinished_forget(client, worker, monkeypatch, me)
    undo = client.post("/v1/speakers/undo", json={"request_id": "u-r", "undo_request_id": "u-1"}, headers=AUTH).json()
    assert undo["samples"]["undone"] == [] and sample_file(settings, me, ids[0])["state"] == "removed"


def test_undo_of_a_naming_waits_for_an_unfinished_forget_of_the_earlier_person(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    assert name_label(client, rows[0]["id"], "S1", priya, request_id="n-1").status_code == 200  # Alan's sample withdrawn
    unfinished_forget(client, worker, monkeypatch, me)
    undo = client.post("/v1/speakers/undo", json={"request_id": "n-1", "undo_request_id": "u-n"}, headers=AUTH).json()
    assert undo["undone"] == [] and undo["skipped"] == [rows[0]["id"]]
    assert not (Vault.open(settings).person_dir(me) / "samples" / f"{ids[0]}.json").exists()


# -- 3: an import retry never answers over an unfinished recovery ----------------------------------------------------


def test_an_import_retry_is_refused_while_its_merge_is_unfinished(env, monkeypatch):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    row = monologue_row(client, worker)
    import_range(client, me, row["id"], 0, 60)
    real = journal._set_pending

    def stuck(store, person_id, sample_id, op_id):  # the result is written; the union never starts counting
        if op_id is None:
            raise OSError("still broken")
        return real(store, person_id, sample_id, op_id)

    monkeypatch.setattr(journal, "_set_pending", stuck)
    with pytest.raises(OSError):
        import_range(client, me, row["id"], 0, 70)
    for start, end in ((0, 70), (5, 50)):  # the same import, and one the unfinished union covers
        r = import_range(client, me, row["id"], start, end)
        assert r.status_code == 409 and r.json()["error"] == "recovery_pending", r.text


# -- 4: a moved enrollment is a real import of the person it moved to --------------------------------------------------


def test_a_moved_enrollment_has_its_own_import_identity_and_merges_later(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    priya = consented_priya(client)
    row = monologue_row(client, worker)
    mine = import_range(client, me, row["id"], 0, 60).json()
    assert client.post(f"/v1/samples/{mine['sample_id']}/move", json={"person_id": priya, "request_id": "m-1"},
                       headers=AUTH).status_code == 200  # fmt: skip
    copy_id = sample_file(settings, me, mine["sample_id"])["moved_to"]["sample_id"]
    copy = sample_file(settings, priya, copy_id)
    vault = Vault.open(settings)
    assert copy["enrollment_id"] and copy["enrollment_id"] != mine["import_id"]
    assert (vault.person_dir(priya) / "enrollment" / f"{copy['enrollment_id']}.omiaudio").exists()
    result = json.loads((vault.person_dir(priya) / "enrollments" / f"{copy['enrollment_id']}.json").read_text())
    assert (result["person_id"], result["sample_id"]) == (priya, copy_id)
    union = import_range(client, priya, row["id"], 0, 70, name="Priya")
    assert union.status_code == 201, union.text
    assert union.json()["merged"] == [copy["enrollment_id"]]


# -- self-audit: the same classes elsewhere -------------------------------------------------------------------------


def test_a_pendant_enrollment_waits_while_the_wearers_forget_is_unfinished(env, monkeypatch):
    import uuid

    import numpy as np

    from .helpers import T0, replay, silence
    from .test_enrollment import end_event, start_event, voice

    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    unfinished_forget(client, worker, monkeypatch, me)
    eid = str(uuid.uuid4())
    capture = replay(client, np.concatenate([silence(2), voice(40, 150), silence(4)]))
    start_event(client, eid, capture, 1.0)
    end_event(client, eid, capture, 43.5)
    worker.tick(T0 + 400)
    assert worker.db.one("SELECT COUNT(*) AS n FROM samples")["n"] == 0
    assert client.get(f"/v1/speakers/enrollments/{eid}", headers=AUTH).json()["state"] != "accepted"
    assert client.delete(f"/v1/people/{me}", headers=AUTH).status_code == 200  # the forget finishes; then it is decided
    worker.tick(T0 + 410)
    assert client.get(f"/v1/speakers/enrollments/{eid}", headers=AUTH).json()["state"] == "accepted"


def test_no_vector_is_kept_for_a_person_whose_forget_is_unfinished(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6,))
    unfinished_forget(client, worker, monkeypatch, me)
    store = worker.pipeline.speakers
    assert store.vector_labels({"S1": {"person_id": me, "source": "user"}}, {"S1"}, raw=True) == set()


def test_undoing_a_naming_needs_the_earlier_persons_current_consent(env):
    settings, client, worker = env
    priya = consented_priya(client)
    ravi = new_person(client, "Ravi", attest_knows=True)
    row = talk(client, worker, dialogue(ALAN, PRIYA, seed=3), day=3)
    assert name_label(client, row["id"], "S2", priya).json()["sample"] == "created"
    assert name_label(client, row["id"], "S2", ravi, request_id="nn-1").status_code == 200  # Priya's withdrawn
    (worker.pipeline.speakers.person_dir(priya) / "consent.json").unlink()
    worker.pipeline.speakers.scan_people()
    undo = client.post("/v1/speakers/undo", json={"request_id": "nn-1", "undo_request_id": "u-nn"}, headers=AUTH).json()
    assert undo["undone"] == [] and undo["skipped"] == [row["id"]]
    assert worker.pipeline.speakers.labels(row["id"])["S2"]["person_id"] == ravi


def test_undoing_a_moved_enrollment_takes_its_import_files_too(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    priya = consented_priya(client)
    row = monologue_row(client, worker)
    mine = import_range(client, me, row["id"], 0, 60).json()
    assert client.post(f"/v1/samples/{mine['sample_id']}/move", json={"person_id": priya, "request_id": "m-2"},
                       headers=AUTH).status_code == 200  # fmt: skip
    iid = sample_file(settings, priya, sample_file(settings, me, mine["sample_id"])["moved_to"]["sample_id"])["enrollment_id"]
    undo = client.post("/v1/speakers/undo", json={"request_id": "m-2", "undo_request_id": "u-m2"}, headers=AUTH).json()
    assert undo["samples"]["undone"] == [mine["sample_id"]], undo
    vault = Vault.open(settings)
    assert not (vault.person_dir(priya) / "enrollments" / f"{iid}.json").exists()
    assert not (vault.person_dir(priya) / "enrollment" / f"{iid}.omiaudio").exists()
    assert (vault.person_dir(me) / "enrollment" / f"{mine['import_id']}.omiaudio").exists()
