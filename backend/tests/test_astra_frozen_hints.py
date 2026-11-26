"""Astra IT1 (2026-11-26) probe, ported: imports adapted to this package; outcome as the invariants require."""
import pytest
from .test_speaker_policy import Env

def test_frozen_person_gets_no_new_possibly_hint(tmp_path):
    e=Env(tmp_path,unknown_voices=True,n_samples=4)
    targets=[e.conversation(named=False,extra_unnamed=True,sha="d")[0] for _ in range(101)]
    cid=targets[-1]
    tsha=e.store.db.one("SELECT transcript_sha FROM conversations WHERE id=?",(cid,))[0]
    before=e.svc.pipeline.possible_voice_names(cid,tsha)
    assert before.get("S1")==("Gigi",False),"real positive hint control"
    e.tear_sample();e.store.load_samples();e.worker_pass(3000.0)
    assert e.store.person_policy(e.gigi,e.store.settings())=="frozen"
    after=e.svc.pipeline.possible_voice_names(cid,tsha)
    print("FROZEN_NEW_HINT",before,after)
    assert "S1" not in after
