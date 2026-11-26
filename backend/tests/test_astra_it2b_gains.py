"""Independent Astra IT2b: gain routes and FROZEN bystander preservation."""
import json
import uuid
from types import SimpleNamespace

import numpy as np
import pytest

from omi_notes.speakers.store import FROZEN
from omi_notes.speakers.voices import Clip, LabelVoice
from omi_notes.util import canonical_json, sha256_hex
from .test_speaker_policy import Env, AUTH


@pytest.mark.parametrize("retained", [True, False])
@pytest.mark.parametrize("damage", ["consent", "sample"])
@pytest.mark.parametrize("embed_failure", [False, True])
def test_assign_other_label_preserves_frozen_voice(tmp_path, monkeypatch, retained, damage, embed_failure):
    e = Env(tmp_path)
    st, svc = e.store, e.svc
    target = str(uuid.uuid4())
    assert e.client.put(f"/v1/people/{target}", json={"name": "Owner", "me": True}, headers=AUTH).status_code == 201
    path = st.conv_dir(e.conv) / "transcript.json"
    transcript = json.loads(path.read_text())
    transcript["segments"].append({"speaker": "S2", "start": 8.0, "end": 15.0, "text": "Other person"})
    transcript["speaker_clips"]["S2"] = [[8.0, 11.0], [12.0, 15.0]]
    path.write_text(json.dumps(transcript))
    tsha = sha256_hex(canonical_json(transcript["segments"]).encode())
    st.db.execute("UPDATE conversations SET transcript_sha=? WHERE id=?", (tsha, e.conv))
    original_state = st.labels(e.conv)["S1"] | {"source": "user"}
    st.write_labels(e.conv, {"S1": original_state}, transcript_sha=tsha, voices=e.vfile.name)
    if not retained:
        st.prune_vectors(e.conv, set())
    before_file = e.vfile.read_bytes()
    before = json.loads(before_file)["labels"]["S1"]
    if damage == "consent":
        e.tear_consent()
    else:
        e.tear_sample()
        st.load_samples()
    assert st.person_policy(e.gigi, st.settings()) == FROZEN
    pcm = np.ones(240000, dtype=np.int16)
    pcm[:128000] = 0
    monkeypatch.setattr(svc.pipeline, "conversation_audio", lambda row: SimpleNamespace(pcm=pcm))
    def embed(clips, pcm, embedder):
        return {lab: LabelVoice(lab, spans, vector=-e.gvec.copy(), spread=0.05, rms_db=-20,
                               f0=99.0, f0_voiced=100) for lab, spans in clips.items()}
    if embed_failure:
        # Exercise real embed_voices: ValueError is its documented per-clip skip path.
        def failed_clip(pcm):
            if not np.any(pcm):
                raise ValueError("synthetic per-clip embedding failure")
            return e.gvec.copy()
        monkeypatch.setattr(svc.pipeline.providers.embedder, "embed", failed_clip)
    else:
        monkeypatch.setattr("omi_notes.speakers.service.embed_voices", embed)
    revision = st.db.one("SELECT speakers_revision FROM conversations WHERE id=?", (e.conv,))[0]
    response = e.client.put(f"/v1/conversations/{e.conv}/speakers/S2", json={
        "person_id": target, "expected_revision": revision, "request_id": str(uuid.uuid4())}, headers=AUTH)
    assert response.status_code == 200, response.text
    assert response.json()["sample"] == "created"
    assert st.labels(e.conv)["S1"]["person_id"] == e.gigi
    assert st.labels(e.conv)["S1"]["source"] == "user"
    after_ref = st.db.one("SELECT file FROM voices WHERE conversation_id=? AND label='S1'", (e.conv,))[0]
    after = json.loads((st.conv_dir(e.conv) / after_ref).read_text())["labels"]["S1"]
    print("FROZEN_BYSTANDER", {"damage": damage, "retained": retained, "embed_failure": embed_failure, "old_file_exists": e.vfile.exists(),
          "old_f0": before.get("f0"), "new_f0": after.get("f0"),
          "vector_before": bool(before.get("vector_b64")), "vector_after": bool(after.get("vector_b64")),
          "vector_equal": before.get("vector_b64") == after.get("vector_b64"), "label_preserved": True})
    assert {k: before.get(k) for k in ("vector_b64", "f0", "f0_voiced")} == {
        k: after.get(k) for k in ("vector_b64", "f0", "f0_voiced")}, "FROZEN bystander's derived voice must not gain or change"


@pytest.mark.parametrize("consent", ["{}", "{torn", "[]"])
def test_restore_and_move_refuse_stale_cached_consent(tmp_path, consent):
    e = Env(tmp_path)
    st = e.store
    sid = st.db.one("SELECT id FROM samples WHERE person_id=? LIMIT 1", (e.gigi,))[0]
    assert e.client.post(f"/v1/samples/{sid}/remove", json={"request_id": "remove"}, headers=AUTH).status_code == 200
    target = str(uuid.uuid4())
    assert e.client.put(f"/v1/people/{target}", json={"name": "Owner", "me": True}, headers=AUTH).status_code == 201
    owner_sample = st.add_sample(target, e.gvec, model="wespeaker", model_sha="deadbeef12345678", source="user", seconds=6, day="2026-11-26", session="owner")
    e.tear_consent(consent)
    for path, body in [(f"/v1/samples/{sid}/restore", {"request_id": "restore"}),
                       (f"/v1/samples/{owner_sample}/move", {"person_id": e.gigi, "request_id": "move"})]:
        r = e.client.post(path, json=body, headers=AUTH)
        assert r.status_code == 409, r.text
        assert r.json()["error"] == "consent_required", r.text
    assert st.read_sample(e.gigi, sid)["state"] == "removed"
    assert st.read_sample(target, owner_sample).get("state", "active") == "active"

# (test_f0_backfill_does_not_gain_voice_features_without_consent: Astra 09, deferred tonight)
