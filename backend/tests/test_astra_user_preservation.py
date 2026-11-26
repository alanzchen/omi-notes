"""Astra IT1 (2026-11-26) probe, ported: imports adapted to this package; outcome as the invariants require."""
from __future__ import annotations
import pytest
from .test_speaker_policy import Env

@pytest.mark.parametrize("me",[False,True])
@pytest.mark.parametrize("damage",["consent","sample"])
def test_confirmed_user_name_and_vector_survive_unreadable_files(tmp_path,me,damage):
    e=Env(tmp_path,me=me)
    state=e.store.labels(e.conv)["S1"] | {"source":"user"}
    e.store.write_labels(e.conv,{"S1":state},transcript_sha=e.store.labels_transcript(e.conv))
    if damage=="consent":e.tear_consent()
    else:e.tear_sample();e.store.load_samples()
    e.store.db.set_meta("relabel_pending","1")
    e.worker_pass()
    assert e.name()==e.gigi and e.store.labels(e.conv)["S1"]["source"]=="user"
    assert e.stored()=={"S1"}
