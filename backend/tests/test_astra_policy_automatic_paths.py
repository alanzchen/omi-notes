"""Astra IT1 (2026-11-26) probe, ported: imports adapted to this package; outcome as the invariants require."""
from __future__ import annotations
import json
import numpy as np
import pytest
from .test_speaker_policy import Env
from omi_notes.speakers.voices import Clip
from omi_notes.util import canonical_json, sha256_hex


def test_review_hint_never_names_opted_out_person(tmp_path):
    e = Env(tmp_path, unknown_voices=True, n_samples=4)
    # Populate the real 200-voice background threshold; both labels retain raw-available unknown voices.
    for _ in range(101):
        e.conversation(named=False, extra_unnamed=True, sha="d")
    before = e.svc.review._label_keys(3000.0)
    assert any(key[2] == e.gigi and key[3] == ["possible"] for key in before), "non-vacuous hint control"
    e.tear_consent("{}")
    e.svc.warm(now=3001.0)
    e.worker_pass(3002.0)
    assert e.store.person_policy(e.gigi, e.store.settings()) == "opted_out"
    after = e.svc.review._label_keys(3003.0)
    leaks = [key for key in after if key[2] == e.gigi]
    e.svc.review.entries(now=3003.0)
    response=e.client.get("/v1/speakers/review?limit=20", headers={"Authorization":"Bearer tok"})
    assert response.status_code==200
    cards=[item for item in response.json()["items"] if item.get("person_id")==e.gigi and item.get("reasons")==["possible"]]
    print("OPTOUT_REVIEW_HINTS", len(before), len(leaks), sorted({tuple(k[3]) for k in leaks}), "GETcards",len(cards))
    assert not leaks and not cards, "review queue still proposes the opted-out person through its independent hint path"


@pytest.mark.parametrize("me", [False, True])
@pytest.mark.parametrize("unreadable", [False, True])
def test_reprocess_with_unreadable_samples_keeps_confirmed_name(tmp_path, unreadable, me):
    e = Env(tmp_path, n_samples=3, me=me)
    oldsha = e.store.labels_transcript(e.conv)
    states = e.store.labels(e.conv)
    states["S1"]["source"] = "user"
    e.store.write_labels(e.conv, states, transcript_sha=oldsha, voices=e.vfile.name)
    if unreadable:
        for path in (e.store.person_dir(e.gigi)/"samples").glob("*.json"):
            path.write_text("{torn")
        e.store.load_samples()
        assert e.store.person_policy(e.gigi,e.store.settings()) == "frozen"
    segments=[{"speaker":"S1","start":0.0,"end":8.0,"text":"Hello again"}]
    tsha=sha256_hex(canonical_json(segments).encode())
    audio=type("Audio",(),{"pcm":np.ones(160000,dtype=np.int16)})()
    e.svc.pipeline.identify(e.conv,audio,"c"*64,{"S1":[Clip(0.5,4.0,0),Clip(4.5,7.5,1)]},tsha,{"S1"})
    final=e.store.labels(e.conv)
    kept=e.store.voices(e.conv)
    hasvector=any(v.vector is not None for v in kept.values())
    print("CONFIRMED_REPROCESS", unreadable, "wearer", me, final, "oldvoiceexists", e.vfile.exists(), "storedvectors",hasvector)
    assert (final.get("S1",{}).get("person_id"),final.get("S1",{}).get("source"),hasvector)==(e.gigi,"user",True)
