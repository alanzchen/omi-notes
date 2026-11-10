"""Regressions for Astra's third review of the Voices hub fixes."""

from __future__ import annotations

import pytest

from omi_notes.speakers import journal

from .conftest import AUTH
from .test_speaker_learning import ALAN, PRIYA, dialogue, env, name_label, new_person, talk  # noqa: F401
from .test_speaker_review_fixes import consented_priya, import_range, journal_files, monologue_row
from .test_speaker_review_fixes2 import crash_on
from .test_speaker_samples import MODEL, me_with_samples, review, decide, sample_file  # noqa: F401


def put_label(client, conv_id: str, label: str, person_id, request_id: str, **extra):
    speakers = client.get(f"/v1/conversations/{conv_id}/speakers", headers=AUTH).json()
    body = {"person_id": person_id, "expected_revision": speakers["revision"], "request_id": request_id} | extra
    return client.put(f"/v1/conversations/{conv_id}/speakers/{label}", json=body, headers=AUTH)


def interrupted_unreject(client, worker, monkeypatch, rows, ids):
    """A label-linked reject, then its undo interrupted before the label step."""
    item = next(i for i in review(client) if i.get("sample_id") == ids[0])
    assert decide(client, item["id"], "reject", "rj-1").status_code == 200
    real = journal._label_step

    def crash(store, op, request_id, change):
        if op["kind"] == "unreject":
            raise OSError("power cut")
        return real(store, op, request_id, change)

    monkeypatch.setattr(journal, "_label_step", crash)
    with pytest.raises(OSError):
        client.post("/v1/speakers/undo", json={"request_id": "rj-1", "undo_request_id": "u-1"}, headers=AUTH)
    return real


# -- 1: label assignments respect the recovery barrier; label-restoring replays are conditional --------------------


def test_a_label_assignment_waits_for_an_unfinished_operation_on_that_label(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    interrupted_unreject(client, worker, monkeypatch, rows, ids)  # recovery keeps failing (the patch stays)
    r = put_label(client, rows[0]["id"], "S1", priya, "pl-1")
    assert r.status_code == 409 and r.json()["error"] == "recovery_pending"


def test_a_replayed_label_restore_never_overwrites_a_newer_choice(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    real = interrupted_unreject(client, worker, monkeypatch, rows, ids)
    store = worker.pipeline.speakers
    states = store.labels(rows[0]["id"])  # a newer accepted choice, made by a process that didn't see the journal
    states["S1"] = states["S1"] | {"person_id": priya, "source": "user", "not": []}
    store.write_labels(rows[0]["id"], states)
    monkeypatch.setattr(journal, "_label_step", real)
    store.samples(*MODEL)  # recovery
    assert journal_files(settings) == []
    assert store.labels(rows[0]["id"])["S1"]["person_id"] == priya


# -- 2: an unfinished forget blocks new voice data for that person ---------------------------------------------------


def test_an_unfinished_forget_blocks_new_imports_moves_restores_and_naming(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    row = monologue_row(client, worker)
    pipeline = worker.pipeline
    real = pipeline.sync_labels_everywhere
    monkeypatch.setattr(pipeline, "sync_labels_everywhere", lambda: (_ for _ in ()).throw(OSError("power cut")))
    with pytest.raises(OSError):
        client.delete(f"/v1/people/{priya}", headers=AUTH)  # the forget began, then failed
    for r in (
        import_range(client, priya, row["id"], 0, 60, name="Priya"),
        client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": priya, "request_id": "fm-1"}, headers=AUTH),
        put_label(client, rows[1]["id"], "S2", priya, "fl-1"),
    ):
        assert r.status_code == 409 and r.json()["error"] == "forget_in_progress", r.text
    monkeypatch.setattr(pipeline, "sync_labels_everywhere", real)
    assert client.delete(f"/v1/people/{priya}", headers=AUTH).status_code == 200
    assert import_range(client, priya, row["id"], 0, 60, name="Priya").status_code == 409  # consent went with the voice


def test_a_restore_waits_for_an_unfinished_forget(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    assert client.post(f"/v1/samples/{ids[0]}/remove", json={"request_id": "r-1"}, headers=AUTH).status_code == 200
    pipeline = worker.pipeline
    monkeypatch.setattr(pipeline, "sync_labels_everywhere", lambda: (_ for _ in ()).throw(OSError("power cut")))
    with pytest.raises(OSError):
        client.delete(f"/v1/people/{me}", headers=AUTH)
    r = client.post(f"/v1/samples/{ids[0]}/restore", json={"request_id": "r-2"}, headers=AUTH)
    assert r.status_code == 409 and r.json()["error"] == "forget_in_progress"


# -- 3: a replay schedules the note's render even when the label part was already written ----------------------------


def test_render_scheduling_survives_a_crash_right_after_the_label_write(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    store = worker.pipeline.speakers
    real = store.write_labels

    def write_then_crash(*args, **kwargs):
        real(*args, **kwargs)
        raise OSError("power cut")

    monkeypatch.setattr(store, "write_labels", write_then_crash)
    with pytest.raises(OSError):
        client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": priya, "request_id": "rr-1"}, headers=AUTH)
    monkeypatch.setattr(store, "write_labels", real)
    worker.db.execute("UPDATE conversations SET needs_render=0")
    store.samples(*MODEL)  # recovery
    assert journal_files(settings) == []
    assert worker.db.one("SELECT needs_render FROM conversations WHERE id=?", (rows[0]["id"],))["needs_render"] == 1


# -- 4: past its commit point an operation rolls forward, never into a state with neither sample ------------------------


def test_an_unmove_past_its_commit_point_rolls_forward_after_consent_is_withdrawn(env, monkeypatch):
    settings, client, worker = env
    priya = consented_priya(client)
    ravi = new_person(client, "Ravi", attest_knows=True)
    row = talk(client, worker, dialogue(ALAN, PRIYA, seed=3), day=3)
    assert name_label(client, row["id"], "S2", priya).json()["sample"] == "created"
    (sid,) = worker.pipeline.speakers.labels(row["id"])["S2"]["samples"]
    assert client.post(f"/v1/samples/{sid}/move", json={"person_id": ravi, "request_id": "mv-1"}, headers=AUTH).status_code == 200
    copy = sample_file(settings, priya, sid)["moved_to"]["sample_id"]
    store = worker.pipeline.speakers
    real = journal.complete
    monkeypatch.setattr(journal, "complete", lambda store_, op: (_ for _ in ()).throw(OSError("power cut")))
    with pytest.raises(OSError):  # everything applied (copy deleted, original restored), not yet completed
        client.post("/v1/speakers/undo", json={"request_id": "mv-1", "undo_request_id": "u-mv"}, headers=AUTH)
    monkeypatch.setattr(journal, "complete", real)
    (store.person_dir(priya) / "consent.json").unlink()  # Priya's attestation withdrawn before recovery
    store.scan_people()
    store.samples(*MODEL)  # recovery
    assert journal_files(settings) == []
    states = [(sample_file(settings, priya, sid) or {}).get("state")]
    copy_left = (store.person_dir(ravi) / "samples" / f"{copy}.json").exists()
    assert states == ["active"] or copy_left, "one of the two must still hold the voice"
    assert states == ["active"] and not copy_left, "past the commit point it rolls forward"


# -- 5: moving an enrollment never doubles the destination's audio ------------------------------------------------------


def test_moving_an_enrollment_onto_the_same_audio_of_the_destination_is_refused(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    priya = consented_priya(client)
    row = monologue_row(client, worker)
    mine = import_range(client, me, row["id"], 0, 60).json()
    assert import_range(client, priya, row["id"], 0, 60, name="Priya").status_code == 201
    r = client.post(f"/v1/samples/{mine['sample_id']}/move", json={"person_id": priya, "request_id": "me-1"}, headers=AUTH)
    assert r.status_code == 409 and r.json()["error"] == "superseded"
    assert sample_file(settings, me, mine["sample_id"]).get("state", "active") == "active"
