"""Carbon's review of R2 (IT2, cd6bca1): the three blockers as expected truths, written before the fixes."""

from __future__ import annotations

import json
import threading
import uuid

from fastapi.testclient import TestClient

from omi_notes.api import create_app

from .test_astra_it2b_generation import setup_moved
from .test_carbon_it1_20261126 import AUTH, _settings, _setup_person
from .test_speaker_policy import Env


def _people(client):
    return {p["id"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}


def _restart(tmp_path, client):
    client.app.state.db.close()
    return TestClient(create_app(_settings(tmp_path), start_worker=False))


# -- IT2-01: the stored snapshot never brings back a forgotten person or an opted-out wearer ------------------------


def test_a_restart_before_the_first_build_serves_no_forgotten_person(tmp_path):
    client, svc, store, pid, vec, conv, _ = _setup_person(tmp_path, unknown_voices=True)
    svc.warm(now=2000)  # people.json now lists Gigi
    assert pid in _people(client)
    assert client.delete(f"/v1/people/{pid}?delete_note=true", headers=AUTH).status_code == 200
    fresh = _restart(tmp_path, client)  # no warm yet: the stored snapshot is all there is
    assert pid not in _people(fresh)
    assert all(s.get("person_id") != pid for s in fresh.get("/v1/speakers/suggestions", headers=AUTH).json()["suggestions"])
    fresh.app.state.db.close()


def test_a_restart_before_the_first_build_serves_no_opted_out_wearer(tmp_path):
    client, svc, store, old, vec, conv, _ = _setup_person(tmp_path, unknown_voices=True, me=True)
    svc.warm(now=2000)
    assert _people(client)[old]["me"] and _people(client)[old]["auto_active"]
    assert client.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH).status_code == 200
    new = str(uuid.uuid4())
    assert client.put(f"/v1/people/{new}", json={"name": "New wearer", "me": True}, headers=AUTH).status_code == 201
    fresh = _restart(tmp_path, client)
    card = _people(fresh)[old]
    assert card["me"] is False and card["auto_active"] is False
    assert _people(fresh)[new]["me"] is True
    fresh.app.state.db.close()


def test_a_put_paused_after_its_write_never_undoes_a_later_forget(tmp_path):
    client, svc, store, pid, vec, conv, _ = _setup_person(tmp_path)
    svc.warm(now=2000)
    paused, resume, written = threading.Event(), threading.Event(), threading.local()
    real_person, real_put = store.person, store.put_person

    def put_person(*a, **k):  # the PUT's note and row are written; mark this request's thread
        out = real_put(*a, **k)
        written.yes = True
        return out

    def person(person_id):  # the next lookup in that request pauses it (before or inside its overlay update)
        if getattr(written, "yes", False) and not paused.is_set():
            paused.set()
            resume.wait(5)
        return real_person(person_id)

    store.put_person, store.person = put_person, person
    put = threading.Thread(target=lambda: client.put(f"/v1/people/{pid}", json={"name": "Gigi"}, headers=AUTH))
    put.start()
    assert paused.wait(5)
    forget = threading.Thread(target=lambda: client.delete(f"/v1/people/{pid}", headers=AUTH))  # the note stays
    forget.start()
    forget.join(0.5)  # with the PUT's overlay written under the speaker lock, the forget waits for it
    resume.set()
    put.join(10)
    forget.join(10)
    store.person, store.put_person = real_person, real_put
    card = _people(client)[pid]
    assert card["auto_active"] is False and not card.get("samples"), "the PUT brought back a forgotten voice"


def test_forgetting_a_voice_but_keeping_the_note_keeps_the_card(tmp_path):
    client, svc, store, pid, vec, conv, _ = _setup_person(tmp_path)
    svc.warm(now=2000)
    assert client.delete(f"/v1/people/{pid}", headers=AUTH).status_code == 200  # delete_note=false: the person stays
    card = _people(client).get(pid)
    assert card is not None, "the kept person vanished until the next build"
    assert card["auto_active"] is False and not card.get("samples")


# -- IT2-02: the review page never names an opted-out or forgotten person ------------------------------------------


def _review_with(e, monkeypatch, entries):
    """A built review snapshot holding `entries`; items render as playable (audio isn't what is under test)."""
    review = e.svc.review
    review._snapshot = {"entries": entries, "evidence": {}}
    monkeypatch.setattr(review, "_sample_item", lambda v: {"kind": "sample", "person_id": v["person_id"], "sample_id": v["sample_id"],
                                                           "reasons": [], "playable": True, "clip": {"id": "c"}})
    monkeypatch.setattr(review, "_label_still_open", lambda v: (v,))
    monkeypatch.setattr(review, "_label_item", lambda v, evidence: {"kind": "label", "person_id": v["person_id"],
                                                                    "reasons": v["reasons"], "playable": True, "clip": {"id": "c"}})


def _served(e):
    return [(i["kind"], i["person_id"]) for i in e.client.get("/v1/speakers/review", headers=AUTH).json()["items"]]


def test_review_serves_no_sample_card_of_an_opted_out_person(tmp_path, monkeypatch):
    e = Env(tmp_path)
    row = e.store.db.one("SELECT id, revision FROM samples WHERE person_id=? LIMIT 1", (e.gigi,))
    _review_with(e, monkeypatch, [("sample", {"sample_id": row["id"], "revision": row["revision"], "person_id": e.gigi})])
    assert _served(e) == [("sample", e.gigi)]
    assert e.client.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH).status_code == 200
    assert _served(e) == [], "a non-wearer's sample card after the acknowledgment was withdrawn"


def test_review_serves_no_possible_hint_for_a_forgotten_voice(tmp_path, monkeypatch):
    for delete_note in (False, True):
        e = Env(tmp_path / str(delete_note), unknown_voices=True)
        _review_with(e, monkeypatch, [("label", {"person_id": e.gigi, "reasons": ["possible"]})])
        assert _served(e) == [("label", e.gigi)]
        assert e.client.delete(f"/v1/people/{e.gigi}?delete_note={str(delete_note).lower()}", headers=AUTH).status_code == 200
        assert _served(e) == [], f"a hint naming a forgotten voice (delete_note={delete_note})"
        e.client.app.state.db.close()


# -- IT2-03: a revision from before a re-transcription is stale; no assignment while a move is deferred -------------


def test_an_assignment_read_before_a_retranscription_is_stale(tmp_path):
    e = Env(tmp_path)
    tsha = setup_moved(e)  # (its own label write is part of the earlier transcript's history)
    seen = e.store.db.one("SELECT speakers_revision FROM conversations WHERE id=?", (e.conv,))[0]  # a client's view of T1
    # now the new transcript is published; its label move hasn't run
    e.store.db.execute("UPDATE conversations SET transcript_sha=? WHERE id=?", (tsha, e.conv))
    priya = str(uuid.uuid4())
    assert e.client.put(f"/v1/people/{priya}", json={"name": "Priya", "attest_knows": True}, headers=AUTH).status_code == 201
    r = e.client.put(f"/v1/conversations/{e.conv}/speakers/S1",
                     json={"person_id": priya, "expected_revision": seen, "request_id": str(uuid.uuid4())}, headers=AUTH)
    assert r.status_code == 409, r.text  # what that client saw as S1 was the earlier transcript's S1


def test_no_assignment_is_written_while_its_label_move_is_deferred(tmp_path):
    e = Env(tmp_path)
    old_sha = e.store.labels_transcript(e.conv)
    tsha = setup_moved(e)
    e.store.db.execute("UPDATE conversations SET transcript_sha=? WHERE id=?", (tsha, e.conv))
    e.tear_consent()  # Gigi is FROZEN: the move is deferred
    seen = e.client.get(f"/v1/conversations/{e.conv}/speakers", headers=AUTH).json()["revision"]
    priya = str(uuid.uuid4())
    assert e.client.put(f"/v1/people/{priya}", json={"name": "Priya", "attest_knows": True}, headers=AUTH).status_code == 201
    r = e.client.put(f"/v1/conversations/{e.conv}/speakers/S1",
                     json={"person_id": priya, "expected_revision": seen, "request_id": str(uuid.uuid4())}, headers=AUTH)
    assert r.status_code == 409 and r.json()["error"] == "recovery_pending", r.text
    assert e.store.labels_transcript(e.conv) == old_sha
    assert json.loads((e.store.conv_dir(e.conv) / "speakers.json").read_text())["transcript_sha"] == old_sha
