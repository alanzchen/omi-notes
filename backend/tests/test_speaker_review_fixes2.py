"""Regressions for Astra's re-review (round 2) of the Voices hub fixes."""

from __future__ import annotations

import json

import pytest

from omi_notes.vault import Vault

from .conftest import AUTH
from .helpers import T0
from .test_speaker_learning import ALAN, PRIYA, dialogue, env, name_label, new_person, talk, vec  # noqa: F401
from .test_speaker_review_fixes import consented_priya, import_range, journal_files, monologue_row
from .test_speaker_samples import MODEL, me_with_samples, review, decide, sample_file  # noqa: F401


def crash_on(monkeypatch, store, name: str, action: str | None = None):
    real = getattr(store, name)

    def failing(*args, **kwargs):
        if action is None or kwargs.get("action") == action:
            raise OSError("power cut")
        return real(*args, **kwargs)

    monkeypatch.setattr(store, name, failing)
    return lambda: monkeypatch.setattr(store, name, real)


# -- 2: one sample's successful write never hides another's failed index write ------------------------------------


def test_a_later_successful_write_keeps_another_samples_failed_index_write_pending(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    store = worker.pipeline.speakers
    restore = crash_on(monkeypatch, store, "_index_sample")
    with pytest.raises(OSError), store.lock:
        store.set_sample_state(me, ids[0], "removed", action="remove", by="user", request_id="r1")
    restore()
    with store.lock:  # another sample changes fine (its index row written)
        store.set_sample_state(me, ids[1], "removed", action="remove", by="user", request_id="r2")
    assert ids[0] not in {s.id for s in store.samples(*MODEL)}, "the first change is still reconciled"


# -- 3: a journaled label change schedules its note's re-render and a relabel ------------------------------------------


def test_a_journaled_label_change_queues_the_render_and_the_relabel(env):
    from omi_notes.speakers import journal

    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    store = worker.pipeline.speakers
    worker.db.execute("UPDATE conversations SET needs_render=0")
    worker.db.set_meta("relabel_pending", None)
    with store.lock:  # what recovery runs: no API layer around it
        journal.run(store, {"kind": "move", "request_id": "j-1", "by": "user", "from": me, "to": priya,
                            "pairs": [[ids[0], "11111111-1111-4111-8111-111111111111"]],
                            "label": {"conversation_id": rows[0]["id"], "label": "S1"}})  # fmt: skip
    assert store.labels(rows[0]["id"])["S1"]["person_id"] == priya
    assert worker.db.one("SELECT needs_render FROM conversations WHERE id=?", (rows[0]["id"],))["needs_render"] == 1
    assert worker.db.meta("relabel_pending") == "1"


# -- 5: a restore or undo never counts imported audio twice ------------------------------------------------------------


def test_restoring_any_import_that_overlaps_an_active_one_is_refused(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    row = monologue_row(client, worker)
    a = import_range(client, me, row["id"], 0, 60).json()
    b = import_range(client, me, row["id"], 0, 70).json()
    c = import_range(client, me, row["id"], 0, 80).json()
    assert b["merged"] == [a["import_id"]] and c["merged"] == [b["import_id"]]

    def restore(sample_id, rid):
        return client.post(f"/v1/samples/{sample_id}/restore", json={"request_id": rid}, headers=AUTH)

    assert restore(a["sample_id"], "x-a").json().get("error") == "superseded", "C covers A's audio"
    assert client.post(f"/v1/samples/{c['sample_id']}/remove", json={"request_id": "x-c"}, headers=AUTH).status_code == 200
    assert restore(b["sample_id"], "x-b").status_code == 200  # nothing active overlaps it now
    assert restore(c["sample_id"], "x-c2").json().get("error") == "superseded", "B is active again"
    # an undo that would bring C back is refused the same way
    undo = client.post("/v1/speakers/undo", json={"request_id": "x-c", "undo_request_id": "u-c"}, headers=AUTH).json()
    assert undo["samples"]["undone"] == [] and sample_file(settings, me, c["sample_id"])["state"] == "removed"


# -- 6: an import needs valid consent when it is authorized and again when it is written ------------------------------


def test_consent_revoked_right_after_the_authorization_check_never_enrolls(env, monkeypatch):
    from omi_notes.speakers.imports import Importer

    settings, client, worker = env
    priya = consented_priya(client)
    row = monologue_row(client, worker)
    store = worker.pipeline.speakers
    real = Importer._consent
    calls = []

    def revoke_then_capture(self, person_id):
        if not calls:  # consent withdrawn between the check and the snapshot
            (store.person_dir(person_id) / "consent.json").unlink()
            store.scan_people()
        calls.append(person_id)
        return real(self, person_id)

    monkeypatch.setattr(Importer, "_consent", revoke_then_capture)
    r = import_range(client, priya, row["id"], 0, 60, name="Priya")
    assert r.status_code == 409 and r.json()["error"] == "consent_required", r.text
    assert worker.db.one("SELECT COUNT(*) AS n FROM samples WHERE person_id=?", (priya,))["n"] == 0


# -- 4: a transitive forget resumes the purge set it decided on ---------------------------------------------------------


def test_a_forget_interrupted_mid_lineage_resumes_the_same_purge_set(env, monkeypatch):
    from omi_notes.speakers import store as store_module

    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    ravi = new_person(client, "Ravi", attest_knows=True)
    assert client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": priya, "request_id": "f-1"}, headers=AUTH).status_code == 200
    copy = sample_file(settings, me, ids[0])["moved_to"]["sample_id"]
    assert client.post(f"/v1/samples/{copy}/move", json={"person_id": ravi, "request_id": "f-2"}, headers=AUTH).status_code == 200
    vault = Vault.open(settings)
    middle = vault.person_dir(priya) / "samples" / f"{copy}.json"
    first = vault.person_dir(me) / "samples" / f"{ids[0]}.json"
    real = store_module.remove

    def crash_after_middle(path):  # B's record goes, A's doesn't, then the process dies
        if path == first:
            return False
        done = real(path)
        if path == middle:
            raise OSError("power cut")
        return done

    monkeypatch.setattr(store_module, "remove", crash_after_middle)
    with pytest.raises(OSError):
        client.delete(f"/v1/people/{ravi}", headers=AUTH)
    monkeypatch.setattr(store_module, "remove", real)
    assert not middle.exists()
    assert client.delete(f"/v1/people/{ravi}", headers=AUTH).status_code == 200
    assert not first.exists(), "A's record (A→B→C) is purged by the resumed forget"
    assert not (settings.vault_dir / "_omi" / "speakers" / "forgetting").exists() or not any(
        (settings.vault_dir / "_omi" / "speakers" / "forgetting").iterdir())


# -- 7: a moved label keeps only the new person's samples -----------------------------------------------------------


def test_a_move_detaches_the_previous_persons_inactive_samples_from_the_label(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    store = worker.pipeline.speakers
    with store.lock:  # Alan confirmed twice on this label
        second = store.add_sample(me, vec(ALAN, 3), model=MODEL[0], model_sha=MODEL[1], source="user", seconds=8.0,
                                  day="2026-09-20", session=rows[0]["id"], conversation_id=rows[0]["id"], label="S1")  # fmt: skip
        states = store.labels(rows[0]["id"])
        states["S1"]["samples"] = sorted({ids[0], second})
        store.write_labels(rows[0]["id"], states)
    assert client.post(f"/v1/samples/{ids[0]}/remove", json={"request_id": "d-1"}, headers=AUTH).status_code == 200
    assert client.post(f"/v1/samples/{second}/move", json={"person_id": priya, "request_id": "d-2"}, headers=AUTH).status_code == 200
    label = store.labels(rows[0]["id"])["S1"]
    copy = sample_file(settings, me, second)["moved_to"]["sample_id"]
    assert (label["person_id"], label["samples"]) == (priya, [copy]), "no Alan sample stays on a label named Priya"
    undo = client.post("/v1/speakers/undo", json={"request_id": "d-2", "undo_request_id": "u-d"}, headers=AUTH).json()
    assert undo["undone"] == [rows[0]["id"]], undo
    label = store.labels(rows[0]["id"])["S1"]
    assert (label["person_id"], label["samples"]) == (me, sorted({ids[0], second}))
