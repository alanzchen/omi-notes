"""Astra IT2B (2026-11-26) expected-truth probes, ported: imports adapted to this package."""
import json
import numpy as np
from .test_speaker_policy import Env
from omi_notes.speakers.voices import Clip
from omi_notes.util import canonical_json, sha256_hex

def setup_moved(e):
    states=e.store.labels(e.conv); states["S1"]["source"]="user"
    e.store.write_labels(e.conv,states,transcript_sha=e.store.labels_transcript(e.conv),voices=e.vfile.name)
    segs=[{"speaker":"S1","start":0.0,"end":8.0,"text":"different transcript generation"}]
    tsha=sha256_hex(canonical_json(segs).encode())
    path=e.store.conv_dir(e.conv)/"transcript.json"
    path.write_text(json.dumps({"segments":segs,"audio_sha":"c"*64,"speaker_clips":{"S1":[[0.5,4.0],[4.5,7.5]]}}))
    return tsha

def test_preserved_generation_survives_normal_sync(tmp_path):
    e=Env(tmp_path)
    tsha=setup_moved(e)
    for p in (e.store.person_dir(e.gigi)/"samples").glob("*.json"):p.write_text("{torn")
    e.store.load_samples()
    assert e.store.person_policy(e.gigi,e.store.settings())=="frozen"
    e.svc.pipeline.identify(e.conv,None,"c"*64,{},tsha,{"S1"})
    e.store.db.execute("UPDATE conversations SET transcript_sha=? WHERE id=?",(tsha,e.conv))
    assert e.vfile.exists(), "the immediate new I3 check does preserve the file"
    print("AFTER_IDENTIFY",e.store.referenced_voices(e.conv), e.store.labels(e.conv), list(e.store.voices(e.conv)))
    e.store.sync_conversation(e.conv)
    print("AFTER_NORMAL_SYNC",e.vfile.exists(), e.store.referenced_voices(e.conv), list(e.store.voices(e.conv)))
    assert e.vfile.exists(), "I3 retention must survive normal sync_conversation"

def test_freeze_does_not_confirm_unrelated_new_s1(tmp_path):
    e=Env(tmp_path)
    tsha=setup_moved(e)
    e.tear_consent()
    assert e.store.person_policy(e.gigi,e.store.settings())=="frozen"
    # A completely different voice in the re-transcription's S1; no identity match is possible.
    other=-e.gvec
    e.svc.pipeline.providers._embedder._vec=other
    audio=type("Audio",(),{"pcm":np.ones(160000,dtype=np.int16)*3000})()
    e.svc.pipeline.identify(e.conv,audio,"c"*64,{"S1":[Clip(0.5,4.0,0),Clip(4.5,7.5,1)]},tsha,{"S1"})
    labels=e.store.labels(e.conv)
    newvoice=e.store.voices(e.conv)["S1"].vector
    assert newvoice is not None and float(newvoice @ e.gvec) < -0.99, "non-vacuous distinct-voice control"
    print("NEW_UNRELATED_S1",labels, e.store.labels_transcript(e.conv),"oldfile",e.vfile.exists())
    assert not (e.store.labels_transcript(e.conv)==tsha and labels.get("S1",{}).get("person_id")==e.gigi), "old confirmed name must not be applied to unrelated new S1"
