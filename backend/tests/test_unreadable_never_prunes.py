"""C4-01 (Carbon IT4, 2026-11-25): an unreadable vault file is never evidence for deleting or downgrading derived data.
Since 159a42f a corrupt consent.json read as "no consent", so the retention pass pruned that person's stored vectors from
voices-*.json and relabel then dropped their automatic names, for good. Now the person keeps their last-known consent
while the file can't be read, and with none known nothing of theirs is pruned. A real opt-out (forget, unknown voices
turned off) still prunes as before. The setup is Carbon's reproducer."""

from __future__ import annotations

import json
import uuid
from pathlib import Path

import numpy as np
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.settings import Settings
from omi_notes.speakers.voices import Clip, LabelVoice
from omi_notes.util import canonical_json, sha256_hex

AUTH = {"Authorization": "Bearer tok"}


class _FakeEmb:
    model = "wespeaker"
    model_sha = "deadbeef12345678"


def _settings(root: Path) -> Settings:
    return Settings(vault_dir=root / "vault", index_dir=root / "index", lock_dir=root / "locks", omi_notes_token="tok",
                    stt_provider="fake", llm_provider="fake")  # fmt: skip


def _gigi_named_automatically(tmp_path, *, unknown_voices: bool = False, extra_unnamed: bool = False):
    """Carbon's setup: Gigi (attested, 3 samples, active) named automatically for S1, whose vector is stored in the
    conversation's voices file. `extra_unnamed`: an unnamed S2 whose vector is stored too (unknown voices on)."""
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    svc.pipeline.providers._embedder = _FakeEmb()
    store.update_settings(acknowledged_at="2026-11-01T00:00:00Z", unknown_voices_enabled=unknown_voices, auto_assign=True)
    gigi = str(uuid.uuid4())
    assert client.put(f"/v1/people/{gigi}", json={"name": "Gigi", "me": False, "attest_knows": True},
                      headers=AUTH).status_code == 201  # fmt: skip
    rng = np.random.default_rng(42)
    gvec = rng.normal(size=256).astype(np.float32)
    gvec /= np.linalg.norm(gvec)
    for i, day in enumerate(("2026-11-18", "2026-11-19", "2026-11-20")):
        v = gvec + 0.01 * rng.normal(size=256).astype(np.float32)
        store.add_sample(gigi, v / np.linalg.norm(v), model="wespeaker", model_sha="deadbeef12345678", source="user",
                         seconds=6.0, day=day, session=f"s-{i}")  # fmt: skip
    svc.warm(now=1000.0)
    conv_id = str(uuid.uuid4())
    segments = [{"speaker": "S1", "start": 0.0, "end": 8.0, "text": "Hello from Gigi"}]
    tsha = sha256_hex(canonical_json(segments).encode())
    cdir = store.conv_dir(conv_id)
    cdir.mkdir(parents=True, exist_ok=True)
    (cdir / "transcript.json").write_text(json.dumps({"segments": segments, "audio_sha": "a" * 64,
                                                       "speaker_clips": {"S1": [[0.5, 4.0], [4.5, 7.5]]}}))  # fmt: skip
    with store.db.tx() as conn:
        conn.execute('INSERT INTO conversations(id,device_id,start,"end",status,transcript_sha,audio_sha,blocks_json,'
                     "created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                     (conv_id, "dev1", 2000.0, 2010.0, "done", tsha, "a" * 64, json.dumps([[2000.0, 2010.0]]), 2000.0, 2010.0))  # fmt: skip
    voices = {"S1": LabelVoice("S1", [Clip(0.5, 4.0, 0), Clip(4.5, 7.5, 1)], vector=gvec.copy(), spread=0.05, rms_db=-20.0,
                               f0=210.0, f0_voiced=10)}  # fmt: skip
    if extra_unnamed:
        other = rng.normal(size=256).astype(np.float32)
        voices["S2"] = LabelVoice("S2", [Clip(8.0, 9.0, 2)], vector=other / np.linalg.norm(other), spread=0.05,
                                  rms_db=-20.0, f0=120.0, f0_voiced=10)  # fmt: skip
    vname = "voices-wespeaker-deadbeef-aaaaaaaaaaaaaaaa-c00000000-" + tsha[:8] + ".json"
    store.write_voices(conv_id, vname, "wespeaker", "deadbeef12345678", voices, keep_vectors=set(voices))
    store.write_labels(conv_id, {"S1": {"person_id": gigi, "source": "auto", "distance": 0.01, "margin": None,
                                        "evidence_s": 6.5, "not": []}}, transcript_sha=tsha, voices=vname)  # fmt: skip
    return client, svc, store, gigi, conv_id, cdir / vname


def _stored(voices_file: Path) -> set[str]:
    return {label for label, v in json.loads(voices_file.read_text())["labels"].items() if "vector_b64" in v}


def _retention_then_relabel(svc, store, now):
    pruned = store.reconcile_vectors()  # what Worker.retention runs
    store.db.set_meta("relabel_pending", "1")
    svc.pipeline.relabel(now)
    return pruned


def test_c4_01_a_corrupt_consent_file_prunes_nothing_and_keeps_automatic_names(tmp_path):
    client, svc, store, gigi, conv_id, vfile = _gigi_named_automatically(tmp_path)
    attested = store.person(gigi)["attested_at"]
    (store.person_dir(gigi) / "consent.json").write_text("{torn consent")
    svc.warm(now=2100.0)
    assert store.person(gigi)["attested_at"] == attested, "the last-known consent stands while the file can't be read"
    assert any(i["code"] == "speaker_files_unreadable" for i in client.get("/v1/issues", headers=AUTH).json()["issues"])
    assert _retention_then_relabel(svc, store, 2200.0) == 0
    assert _stored(vfile) == {"S1"}
    assert store.labels(conv_id)["S1"]["person_id"] == gigi


def test_c4_01_with_no_known_consent_an_unreadable_file_still_prunes_nothing(tmp_path):
    """No previous people row to fall back on (e.g. the index was rebuilt): unknown, and nothing of theirs goes."""
    client, svc, store, gigi, conv_id, vfile = _gigi_named_automatically(tmp_path)
    (store.person_dir(gigi) / "consent.json").write_text("{torn consent")
    store.db.execute("DELETE FROM people")
    store.scan_people()
    assert store.person(gigi)["attested_at"] is None and gigi in store.unreadable_consent
    assert _retention_then_relabel(svc, store, 2200.0) == 0
    assert _stored(vfile) == {"S1"} and store.labels(conv_id)["S1"]["person_id"] == gigi


def test_forgetting_a_person_still_removes_their_stored_voice(tmp_path):
    client, svc, store, gigi, conv_id, vfile = _gigi_named_automatically(tmp_path)
    assert client.delete(f"/v1/people/{gigi}", headers=AUTH).status_code == 200
    store.reconcile_vectors()
    assert "S1" not in _stored(vfile)
    assert (store.labels(conv_id).get("S1") or {}).get("person_id") is None


def test_turning_unknown_voices_off_still_prunes_unnamed_vectors(tmp_path):
    client, svc, store, gigi, conv_id, vfile = _gigi_named_automatically(tmp_path, unknown_voices=True, extra_unnamed=True)
    assert store.reconcile_vectors() == 0 and _stored(vfile) == {"S1", "S2"}
    assert client.put("/v1/speakers/settings", json={"unknown_voices_enabled": False}, headers=AUTH).status_code == 200
    store.reconcile_vectors()
    assert _stored(vfile) == {"S1"}, "the unnamed voice goes; the consented one stays"


# -- Carbon IT5 (2026-11-25): the unreadable stand-in covers only the person's own consent.json; a skipped sample file
# never costs a person their automatic names or stored vectors.


def test_c5_01_withdrawing_the_global_acknowledgment_prunes_even_with_a_torn_consent_file(tmp_path):
    """Carbon's compound edge, outcome fixed: the acknowledgment is a global condition, not part of consent.json."""
    client, svc, store, gigi, conv_id, vfile = _gigi_named_automatically(tmp_path)
    (store.person_dir(gigi) / "consent.json").write_text("{torn")
    assert client.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH).status_code == 200
    store.reconcile_vectors()
    assert "S1" not in _stored(vfile)


import pytest  # noqa: E402


@pytest.mark.parametrize("content", ["[]", "null", "0", '""', "false"])
def test_c5_01_consent_content_that_isnt_an_object_is_unreadable_not_empty(tmp_path, content):
    client, svc, store, gigi, conv_id, vfile = _gigi_named_automatically(tmp_path)
    (store.person_dir(gigi) / "consent.json").write_text(content)
    svc.warm(now=2100.0)
    assert store.person_policy(gigi, store.settings()) == "frozen" and gigi in store.unreadable_consent
    assert store.reconcile_vectors() == 0 and _stored(vfile) == {"S1"}


def test_c5_01_a_missing_or_empty_object_consent_file_is_read_as_given(tmp_path):
    client, svc, store, gigi, conv_id, vfile = _gigi_named_automatically(tmp_path)
    path = store.person_dir(gigi) / "consent.json"
    path.write_text("{}")  # readable: no attestation, a real withdrawal
    assert store.person_policy(gigi, store.settings()) == "opted_out"
    path.unlink()  # missing: no consent
    assert store.person_policy(gigi, store.settings()) == "opted_out"


def test_c5_02_a_skipped_sample_file_keeps_the_persons_automatic_names_and_vectors(tmp_path):
    """Carbon's reproducer (test_c5_03_skipped_sample_...), outcome fixed: while one of Gigi's samples can't be read,
    relabel defers her (her automatic name stays), so retention has nothing unnamed to prune; once the file is readable
    again the reload marks a relabel and her name is evaluated with all her samples."""
    client, svc, store, gigi, conv_id, vfile = _gigi_named_automatically(tmp_path)
    samples = sorted((store.person_dir(gigi) / "samples").glob("*.json"))
    saved = samples[0].read_text()
    samples[0].write_text("{torn sample")
    store.load_samples()
    svc.refresh_people(now=2100.0)
    store.db.set_meta("relabel_pending", "1")
    svc.pipeline.relabel(2150.0)
    assert store.labels(conv_id)["S1"]["person_id"] == gigi and store.labels(conv_id)["S1"]["source"] == "auto"
    assert store.reconcile_vectors() == 0 and _stored(vfile) == {"S1"}
    samples[0].write_text(saved)
    store.db.set_meta("relabel_pending", None)
    store.sync_samples()  # the reload brings the file back
    assert store.db.meta("relabel_pending") == "1", "a changed readable set re-evaluates the names"
    svc.pipeline.relabel(2510.0)
    assert store.labels(conv_id)["S1"]["person_id"] == gigi
