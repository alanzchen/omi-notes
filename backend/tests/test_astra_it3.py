"""Astra IT3 (2026-11-26, efe1acf) reproducers, ported unchanged in substance (fixed outcomes asserted), plus one
immediate-GET test per identity mutation (read-your-write through the overlays, before any worker pass)."""

from __future__ import annotations

import json
import traceback
import uuid
from dataclasses import replace
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.pipeline.conversations import BACKGROUND_MIN_VOICES
from omi_notes.speakers.store import OPTED_OUT

from .conftest import AUTH as CLIENT_AUTH
from .test_astra_it2b_cost import CountedPeople
from .test_astra_it2b_gains import test_assign_other_label_preserves_frozen_voice as _frozen_probe
from .test_carbon_it1_20261126 import AUTH, _FakeEmb, _add_conv, _settings, _setup_person
from .test_speaker_policy import _FakeEmb as _PolicyEmb

# -- IT3-01: a frozen bystander is never re-embedded --------------------------------------------------------------

@pytest.mark.parametrize("retained", [True, False])
def test_old_model_frozen_bystander_is_not_reembedded(tmp_path, monkeypatch, retained):
    # Existing files and samples use the previous sha; the next model version is now loaded.
    monkeypatch.setattr(_PolicyEmb, "model_sha", "newmodel12345678")
    _frozen_probe(tmp_path, monkeypatch,
        retained=retained, damage="consent", embed_failure=False)

# -- IT3-02: one wrong-shaped voices file never starves pruning ----------------------------------------------

@pytest.mark.parametrize("wrong", ['[1]', '{"labels":[1]}'])
def test_wrong_shape_voice_file_does_not_starve_optout(tmp_path, wrong):
    client, svc, store, person, vec, _, _ = _setup_person(tmp_path, unknown_voices=True)
    bad = "00000000-0000-0000-0000-000000000001"
    good = "ffffffff-ffff-ffff-ffff-ffffffffffff"
    bad_path = _add_conv(store, bad, vec, start=4000, sha_char="b")
    good_path = _add_conv(store, good, vec, start=5000, sha_char="c", person_id=person, source="auto")
    assert client.put("/v1/speakers/settings", json={"unknown_voices_enabled":False,"auto_assign":False,"acknowledged_at":None}, headers=AUTH).status_code==200
    assert store.person_policy(person, store.settings()) == "opted_out"
    bad_path.write_text(wrong)
    errors=[]
    for now in (6000,6002):
        try: svc.pipeline.relabel(now)
        except Exception as exc:
            errors.append(type(exc).__name__)
            print("PRUNE_EXCEPTION_SITE", traceback.extract_tb(exc.__traceback__)[-1])
    retained = "vector_b64" in json.loads(good_path.read_text())["labels"]["S1"]
    print("WRONG_SHAPE_PRUNE",wrong,errors,retained,store.db.meta("relabel_pending"))
    assert store.db.meta("relabel_pending")=="1"
    assert not retained, "unreadable first file must not starve healthy opted-out vector pruning"


# -- IT3-03 / IT3-04 and overlay controls -------------------------------------------------------------------

def test_former_wearer_card_is_restricted_before_worker(tmp_path):
    client, svc, store, old, _, _, _ = _setup_person(tmp_path, unknown_voices=True, me=True)
    svc.warm(now=2000)
    assert {p['id']:p for p in svc.people()}[old]['auto_active'] is True
    assert client.put('/v1/speakers/settings',json={'acknowledged_at':None},headers=AUTH).status_code==200
    new=str(uuid.uuid4())
    assert client.put(f'/v1/people/{new}',json={'name':'New wearer','me':True},headers=AUTH).status_code==201
    assert store.person_policy(old,store.settings())==OPTED_OUT
    answer={p['id']:p for p in client.get('/v1/people',headers=AUTH).json()['people']}[old]
    print('FORMER_WEARER_CARD',answer)
    assert not answer['me']
    assert not answer['auto_active']


def test_former_wearer_real_suggestion_is_restricted_before_worker(tmp_path):
    client=TestClient(create_app(_settings(tmp_path),start_worker=False))
    svc=client.app.state.speakers;store=svc.store
    rng=np.random.default_rng(123)
    gvec=np.zeros(256,dtype=np.float32);gvec[1]=1
    svc.pipeline.providers._embedder=_FakeEmb(gvec)
    client.put('/v1/speakers/settings',json={'acknowledged_at':'2026-11-01T00:00:00Z','unknown_voices_enabled':True,'auto_assign':False},headers=AUTH)
    bg,old=str(uuid.uuid4()),str(uuid.uuid4())
    assert client.put(f'/v1/people/{bg}',json={'name':'Background','me':False,'attest_knows':True},headers=AUTH).status_code==201
    assert client.put(f'/v1/people/{old}',json={'name':'Former wearer','me':True},headers=AUTH).status_code==201
    for i in range(BACKGROUND_MIN_VOICES+5):
        vec=rng.normal(size=256).astype(np.float32);vec[1]=-abs(vec[1]);vec/=np.linalg.norm(vec)
        store.add_sample(bg,vec,model='wespeaker',model_sha='deadbeef12345678',source='user',seconds=6,day=f'2026-10-{i%28+1:02d}',session=f'bg-{i}')
    for i in range(3):
        vec=gvec+0.005*rng.normal(size=256).astype(np.float32);vec/=np.linalg.norm(vec)
        store.add_sample(old,vec,model='wespeaker',model_sha='deadbeef12345678',source='user',seconds=6,day=f'2026-11-{10+i:02d}',session=f'g-{i}')
        _add_conv(store,str(uuid.uuid4()),gvec,start=5000+i*86400,sha_char=chr(ord('e')+i))
    svc.warm(now=5000+3*86400)
    before=client.get('/v1/speakers/suggestions',headers=AUTH).json()['suggestions']
    assert any(x.get('person_id')==old for x in before),before
    client.put('/v1/speakers/settings',json={'acknowledged_at':None},headers=AUTH)
    assert any(x.get('person_id')==old for x in client.get('/v1/speakers/suggestions',headers=AUTH).json()['suggestions'])
    new=str(uuid.uuid4())
    assert client.put(f'/v1/people/{new}',json={'name':'New wearer','me':True},headers=AUTH).status_code==201
    assert store.person_policy(old,store.settings())==OPTED_OUT
    after=client.get('/v1/speakers/suggestions',headers=AUTH).json()['suggestions']
    print('FORMER_WEARER_SUGGESTION',after)
    assert not any(x.get('person_id')==old for x in after)


def test_overlay_clears_after_warm_and_delete(tmp_path):
    client=TestClient(create_app(_settings(tmp_path),start_worker=False));svc=client.app.state.speakers
    pid=str(uuid.uuid4())
    client.put(f'/v1/people/{pid}',json={'name':'First','me':True},headers=AUTH)
    client.put(f'/v1/people/{pid}',json={'name':'Second','me':False},headers=AUTH)
    assert svc._people_overlay[pid][1]['name']=='Second'
    svc.warm()
    assert not svc._people_overlay
    client.put(f'/v1/people/{pid}',json={'name':'Third'},headers=AUTH)
    svc.forget(pid,delete_note=True)
    assert pid not in svc._people_overlay
    assert all(p['id']!=pid for p in svc.people())


def test_put_does_not_edit_a_note_reassigned_to_another_person(tmp_path):
    client=TestClient(create_app(_settings(tmp_path),start_worker=False));svc=client.app.state.speakers;store=svc.store
    original,reassigned=str(uuid.uuid4()),str(uuid.uuid4())
    assert client.put(f'/v1/people/{original}',json={'name':'Original'},headers=AUTH).status_code==201
    svc.warm()
    path=store.vault.root/store.person(original)['note_path']
    external=f'---\nomi_person_id: {reassigned}\nname: Someone else\nomi_me: false\n---\n# Someone else\nUser-authored body.\n'
    path.write_text(external)
    response=client.put(f'/v1/people/{original}',json={'name':'Renamed original'},headers=AUTH)
    print('REASSIGNED_NOTE_PUT',response.status_code,response.json(),'oldpath_exists',path.exists())
    changed=[p for p in path.parent.glob('*.md') if reassigned in p.read_text()]
    print('REASSIGNED_NOTE_FILES',[(p.name,p.read_text()) for p in changed])
    assert len(changed)==1 and changed[0]==path and changed[0].read_text()==external, 'a request naming original id must not rename/edit someone else’s note'


# -- IT3-05 / IT3-06 and the clustering control ------------------------------------------------------------

def test_put_person_does_not_materialize_every_people_card(client):  # IT3-06
    svc=client.app.state.speakers
    pid=str(uuid.uuid4())
    assert client.put('/v1/people/'+pid,json={'name':'Target'},headers=CLIENT_AUTH).status_code==201
    counts=[]
    for n in (100,10000):
        people=CountedPeople(n)
        people.append({'id':pid,'name':'Target','me':False})
        svc._people=replace(svc._people,people=people,ready=True)
        assert client.put('/v1/people/'+pid,json={'name':'Target'},headers=CLIENT_AUTH).status_code==200
        counts.append(people.visits)
    print('PUT_CARD_VISITS',counts)
    assert counts[1] <= counts[0]+5, 'single-person response still copies every global People card'

def test_cluster_bound_with_eligible_candidates(monkeypatch):
    from omi_notes.speakers import suggest
    seen=[]
    monkeypatch.setattr(suggest,'cluster',lambda vectors,*a,**k: seen.append(len(vectors)) or [])
    for n in (25,1000):
        candidates=[suggest.Candidate(f'c{i}','S1',np.ones(8,dtype=np.float32),20.,'2026-11-26',-20.) for i in range(n)]
        suggest.suggestions(candidates,{},me_exists=True,dismissed={},now=0.,limit=20)
    print('ELIGIBLE_CLUSTER_INPUTS',seen)
    assert seen==[25,80]

def test_conversation_speakers_get_has_no_global_sample_inventory(tmp_path,monkeypatch):
    
    client,svc,store,pid,vec,conv,voice=_setup_person(tmp_path)
    folder=store.person_dir(pid)/'samples'
    realglob=Path.glob
    visits=[]
    def globbed(path,pattern,*a,**k):
        for found in realglob(path,pattern,*a,**k):
            if pattern=='*/samples/*.json':visits.append(found.name)
            yield found
    monkeypatch.setattr(Path,'glob',globbed)
    counts=[]
    for start,n in ((0,100),(100,1000)):
        for i in range(start,n):(folder/f'unindexed-{i}.json').write_text('{}')
        assert client.get(f'/v1/conversations/{conv}/speakers',headers=AUTH).status_code==200
        visits.clear()
        response=client.get(f'/v1/conversations/{conv}/speakers',headers=AUTH)
        assert response.status_code==200,response.text
        counts.append(len(visits))
    print('SPEAKER_GET_SAMPLE_VISITS',counts)
    assert counts[1]<=counts[0]+10,'one-conversation GET walks unrelated global samples'


# -- read-your-write: the very next GET reflects each identity mutation, with no worker pass in between ------------
# (the shape: a mutation writes intent and an overlay; it runs no relabel and no snapshot build in the request)


def _no_request_builds(svc, monkeypatch):
    calls = {"relabel": 0, "refresh": 0}
    real_relabel, real_refresh = svc.pipeline.relabel, svc.refresh_people

    def relabel(*a, **k):
        calls["relabel"] += 1
        return real_relabel(*a, **k)

    def refresh(*a, **k):
        calls["refresh"] += 1
        return real_refresh(*a, **k)

    monkeypatch.setattr(svc.pipeline, "relabel", relabel)
    monkeypatch.setattr(svc, "refresh_people", refresh)
    return calls


def _people(client):
    return {p["id"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}


def _names(client, conv):
    return {lab["label"]: lab["name"] for lab in client.get(f"/v1/conversations/{conv}/speakers", headers=AUTH).json()["labels"]}


def test_ryw_create_person(tmp_path, monkeypatch):
    client, svc, store, pid, vec, conv, _ = _setup_person(tmp_path)
    calls = _no_request_builds(svc, monkeypatch)
    new = str(uuid.uuid4())
    assert client.put(f"/v1/people/{new}", json={"name": "Priya", "attest_knows": True}, headers=AUTH).status_code == 201
    assert _people(client)[new]["name"] == "Priya"
    assert calls == {"relabel": 0, "refresh": 0}


def test_ryw_rename(tmp_path, monkeypatch):
    client, svc, store, pid, vec, conv, _ = _setup_person(tmp_path, source="user")
    calls = _no_request_builds(svc, monkeypatch)
    assert client.put(f"/v1/people/{pid}", json={"name": "Gigi Two"}, headers=AUTH).status_code == 200
    assert _people(client)[pid]["name"] == "Gigi Two"
    assert _names(client, conv)["S1"] == "Gigi Two"
    assert calls == {"relabel": 0, "refresh": 0}


def test_ryw_set_as_me(tmp_path, monkeypatch):
    client, svc, store, old, vec, conv, _ = _setup_person(tmp_path, me=True)
    calls = _no_request_builds(svc, monkeypatch)
    new = str(uuid.uuid4())
    assert client.put(f"/v1/people/{new}", json={"name": "Alan", "me": True}, headers=AUTH).status_code == 201
    people = _people(client)
    assert people[new]["me"] and not people[old]["me"]
    assert [p for p in people.values() if p["me"]] == [people[new]]
    assert calls == {"relabel": 0, "refresh": 0}


def test_ryw_name_a_voice(tmp_path, monkeypatch):
    client, svc, store, pid, vec, _, _ = _setup_person(tmp_path)
    conv = str(uuid.uuid4())
    _add_conv(store, conv, vec, start=9000, sha_char="d")
    calls = _no_request_builds(svc, monkeypatch)
    rev = client.get(f"/v1/conversations/{conv}/speakers", headers=AUTH).json()["revision"]
    r = client.put(f"/v1/conversations/{conv}/speakers/S1",
                   json={"person_id": pid, "expected_revision": rev, "request_id": str(uuid.uuid4())}, headers=AUTH)
    assert r.status_code == 200, r.text
    assert {x["label"]: x["name"] for x in r.json()["labels"]}["S1"] == "Gigi"
    assert _names(client, conv)["S1"] == "Gigi"
    assert pid in _people(client)
    assert calls == {"relabel": 0, "refresh": 0}
    assert store.db.meta("relabel_pending") == "1"  # every other conversation: the worker's next pass


def test_ryw_forget(tmp_path, monkeypatch):
    client, svc, store, pid, vec, conv, _ = _setup_person(tmp_path, source="user")
    calls = _no_request_builds(svc, monkeypatch)
    # the note deleted too: gone (with the note kept the card stays, without a voice: test_review_it2)
    assert client.delete(f"/v1/people/{pid}?delete_note=true", headers=AUTH).status_code == 200
    assert pid not in _people(client)
    assert _names(client, conv)["S1"] is None
    samples = client.get(f"/v1/people/{pid}/samples", headers=AUTH)  # 404, or nothing left of their voice
    assert samples.status_code == 404 or samples.json()["samples"] == []
    assert calls["refresh"] == 0


def test_get_paths_compute_no_identity(tmp_path, monkeypatch):
    """GETs are side-effect-free: no recovery, label move or calibration gather on a request (invariant 1)."""
    client, svc, store, pid, vec, conv, _ = _setup_person(tmp_path)

    def boom(*a, **k):
        raise AssertionError("identity computed on a GET")

    monkeypatch.setattr(store, "reconcile", boom)
    monkeypatch.setattr(svc.pipeline, "move_labels", boom)
    monkeypatch.setattr(svc.pipeline, "relabel", boom)
    monkeypatch.setattr("omi_notes.speakers.calibration.gather", boom)
    for path in ("/v1/people", f"/v1/conversations/{conv}/speakers", "/v1/speakers/suggestions",
                 "/v1/speakers/calibration", "/v1/speakers/review"):
        assert client.get(path, headers=AUTH).status_code == 200, path


def test_a_deferred_label_move_is_finished_by_the_worker_never_by_a_get(tmp_path):
    """The GET used to finish a pending move; now only the worker's relabel pass does (Carbon D1 invariant 1), and
    while a named person is FROZEN it stays deferred with no names served across generations (invariant 6)."""
    from .test_astra_it2b_generation import setup_moved
    from .test_speaker_policy import Env

    e = Env(tmp_path)
    good = (e.store.person_dir(e.gigi) / "consent.json").read_text()
    old_sha = e.store.labels_transcript(e.conv)
    tsha = setup_moved(e)
    e.store.db.execute("UPDATE conversations SET transcript_sha=? WHERE id=?", (tsha, e.conv))
    e.tear_consent()
    e.svc.pipeline.identify(e.conv, None, "c" * 64, {}, tsha, {"S1"})  # deferred: Gigi is FROZEN
    assert e.store.labels_transcript(e.conv) == old_sha and e.store.db.meta("relabel_pending") == "1"
    served = e.client.get(f"/v1/conversations/{e.conv}/speakers", headers=AUTH).json()
    assert [x["name"] for x in served["labels"]] == [None]  # no name across transcript generations
    assert e.store.labels_transcript(e.conv) == old_sha, "a GET moved the labels"
    e.svc.pipeline.relabel(9000.0)  # still FROZEN: still deferred, still pending
    assert e.store.labels_transcript(e.conv) == old_sha and e.store.db.meta("relabel_pending") == "1"
    (e.store.person_dir(e.gigi) / "consent.json").write_text(good)
    e.svc.pipeline.relabel(9010.0)  # readable again: the worker finishes the move
    assert e.store.labels_transcript(e.conv) == tsha and not e.store.move_pending(e.conv)
