"""Astra recon of d2b2bd4 (2026-11-28) RECON-01 and RECON-02, ported unchanged except imports."""
import json
import uuid

import numpy as np
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.pipeline.conversations import BACKGROUND_MIN_VOICES
from omi_notes.util import canonical_json, sha256_hex

from .conftest import AUTH
from .test_carbon_it1_20261126 import AUTH as CARBON_AUTH, _FakeEmb, _add_conv, _settings
from .test_name_voice import get, labels, recurring
from .test_speaker_learning import env, new_person  # noqa: F401


def test_cached_suggestion_must_not_assign_a_different_transcripts_label(env):
    settings, client, worker = env
    me, rows, suggestion = recurring(env)
    svc = client.app.state.speakers
    ravi = new_person(client, "Ravi", attest_knows=True)
    target = rows[0]["id"]
    path = worker.pipeline.conv_dir(target) / "transcript.json"
    data = json.loads(path.read_text())
    old_sha = worker.pipeline.speakers.labels_transcript(target)
    # A completed re-transcription reverses the label numbers (old S1 is now S2).
    swap = {"S1":"S2", "S2":"S1"}
    for segment in data["segments"]:
        segment["speaker"] = swap.get(segment["speaker"], segment["speaker"])
    data["speaker_clips"] = {swap.get(k,k):v for k,v in data["speaker_clips"].items()}
    new_sha = sha256_hex(canonical_json(data["segments"]).encode())
    assert new_sha != old_sha
    path.write_text(json.dumps(data))
    worker.db.execute("UPDATE conversations SET transcript_sha=? WHERE id=?", (new_sha,target))
    # Worker finishes the label move; its next snapshot warm has not happened yet.
    worker.pipeline.move_labels(target,data)
    assert not worker.pipeline.speakers.move_pending(target)
    assert labels(client,target)["S2"]["person_id"] is None
    assert suggestion["id"] in {s["id"] for s in get(client,"/v1/speakers/suggestions")["suggestions"]}
    recalculated, _ = svc._suggestions(__import__("time").time())
    assert suggestion["id"] not in {s.id for s in recalculated}, "The previous live recomputation path would also retain it"
    response = client.post(f"/v1/speakers/suggestions/{suggestion['id']}/assign",
        json={"person_id":ravi,"request_id":"old-suggestion-after-retranscription"},headers=AUTH)
    print("RESULT", response.status_code,response.text, "CURRENT_S2",labels(client,target)["S2"])
    assert response.status_code in (404,409) or labels(client,target)["S2"]["person_id"] != ravi, \
        "The pre-retranscription suggestion named a different voice at the same label number"


def test_forgotten_voice_retaining_note_has_no_cached_suggestion(tmp_path):
    client=TestClient(create_app(_settings(tmp_path),start_worker=False))
    svc=client.app.state.speakers;store=svc.store
    rng=np.random.default_rng(123)
    gvec=np.zeros(256,dtype=np.float32);gvec[1]=1
    svc.pipeline.providers._embedder=_FakeEmb(gvec)
    client.put('/v1/speakers/settings',json={'acknowledged_at':'2026-11-01T00:00:00Z','unknown_voices_enabled':True,'auto_assign':False},headers=CARBON_AUTH)
    bg,old=str(uuid.uuid4()),str(uuid.uuid4())
    assert client.put(f'/v1/people/{bg}',json={'name':'Background','me':False,'attest_knows':True},headers=CARBON_AUTH).status_code==201
    assert client.put(f'/v1/people/{old}',json={'name':'Former wearer','me':True},headers=CARBON_AUTH).status_code==201
    for i in range(BACKGROUND_MIN_VOICES+5):
        vec=rng.normal(size=256).astype(np.float32);vec[1]=-abs(vec[1]);vec/=np.linalg.norm(vec)
        store.add_sample(bg,vec,model='wespeaker',model_sha='deadbeef12345678',source='user',seconds=6,day=f'2026-10-{i%28+1:02d}',session=f'bg-{i}')
    for i in range(3):
        vec=gvec+0.005*rng.normal(size=256).astype(np.float32);vec/=np.linalg.norm(vec)
        store.add_sample(old,vec,model='wespeaker',model_sha='deadbeef12345678',source='user',seconds=6,day=f'2026-11-{10+i:02d}',session=f'g-{i}')
        _add_conv(store,str(uuid.uuid4()),gvec,start=5000+i*86400,sha_char=chr(ord('e')+i))
    svc.warm(now=5000+3*86400)
    before=client.get('/v1/speakers/suggestions',headers=CARBON_AUTH).json()['suggestions']
    assert any(x.get('person_id')==old for x in before),before
    response = client.delete(f"/v1/people/{old}",headers=CARBON_AUTH)
    assert response.status_code == 200,response.text
    assert store.person(old) is not None
    assert store.db.one("SELECT 1 FROM samples WHERE person_id=?",(old,)) is None
    after=client.get('/v1/speakers/suggestions',headers=CARBON_AUTH).json()['suggestions']
    print("FORGOTTEN_CACHED_SUGGESTIONS",after)
    assert all(s.get("person_id") != old for s in after), "forget kept-note still exposes person's forgotten identity in cached suggestion"


def test_a_rename_is_not_lost_for_a_conversation_that_failed_in_the_pass(tmp_path):
    """RECON-03: _relabel advanced rendered_names past a conversation that failed in that pass, so its note was never
    re-rendered with the new name. Its own note is now marked for rendering (retried by the render path), without
    marking every note again on every pass."""
    from .test_carbon_it1_20261126 import _setup_person

    client, svc, store, pid, vec, conv, _ = _setup_person(tmp_path, source="user")
    bad = str(uuid.uuid4())
    _add_conv(store, bad, vec, person_id=pid, source="user", start=500.0, sha_char="b")
    store.db.execute("UPDATE conversations SET note_path='notes/bad.md', needs_render=0 WHERE id=?", (bad,))
    store.db.set_meta("relabel_pending", "1")
    svc.pipeline.relabel(9000.0)
    store.db.execute("UPDATE conversations SET needs_render=0 WHERE id=?", (bad,))
    assert client.put(f"/v1/people/{pid}", json={"name": "Gigi Renamed"}, headers=CARBON_AUTH).status_code == 200
    torn = store.conv_dir(bad) / "speakers.json"
    torn.write_text("{torn")
    svc.pipeline.relabel(9010.0)
    assert store.db.one("SELECT needs_render FROM conversations WHERE id=?", (bad,))[0] == 1, "its rename is still owed"
