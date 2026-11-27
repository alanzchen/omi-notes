"""Independent verification & probes for OMI-NIGHTLY-2026-11-25-CARBON-IT5 (pin 55b6a29)."""

from __future__ import annotations

import json
import time
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
    return Settings(
        vault_dir=root / "vault",
        index_dir=root / "index",
        lock_dir=root / "locks",
        omi_notes_token="tok",
        stt_provider="fake",
        llm_provider="fake",
    )


def _setup_gigi(tmp_path: Path, *, unknown_voices: bool = False, extra_unnamed: bool = False):
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    svc.pipeline.providers._embedder = _FakeEmb()

    store.update_settings(acknowledged_at="2026-11-01T00:00:00Z", unknown_voices_enabled=unknown_voices, auto_assign=True)
    gigi = str(uuid.uuid4())
    assert client.put(f"/v1/people/{gigi}", json={"name": "Gigi", "me": False, "attest_knows": True}, headers=AUTH).status_code == 201

    rng = np.random.default_rng(42)
    gvec = rng.normal(size=256).astype(np.float32)
    gvec /= np.linalg.norm(gvec)
    for i, day in enumerate(("2026-11-18", "2026-11-19", "2026-11-20")):
        v = gvec + 0.01 * rng.normal(size=256).astype(np.float32)
        v /= np.linalg.norm(v)
        store.add_sample(gigi, v, model="wespeaker", model_sha="deadbeef12345678", source="user",
                         seconds=6.0, day=day, session=f"s-{i}")
    svc.warm(now=1000.0)

    conv_id = str(uuid.uuid4())
    segments = [{"speaker": "S1", "start": 0.0, "end": 8.0, "text": "Hello from Gigi"}]
    tsha = sha256_hex(canonical_json(segments).encode())
    cdir = store.conv_dir(conv_id)
    cdir.mkdir(parents=True, exist_ok=True)
    (cdir / "transcript.json").write_text(json.dumps({"segments": segments, "audio_sha": "a" * 64,
                                                       "speaker_clips": {"S1": [[0.5, 4.0], [4.5, 7.5]]}}))
    with store.db.tx() as conn:
        conn.execute(
            'INSERT INTO conversations(id,device_id,start,"end",status,transcript_sha,audio_sha,blocks_json,created_at,updated_at) '
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (conv_id, "dev1", 2000.0, 2010.0, "done", tsha, "a" * 64, json.dumps([[2000.0, 2010.0]]), 2000.0, 2010.0),
        )
    voices = {"S1": LabelVoice("S1", [Clip(0.5, 4.0, 0), Clip(4.5, 7.5, 1)], vector=gvec.copy(), spread=0.05, rms_db=-20.0, f0=210.0, f0_voiced=10)}
    if extra_unnamed:
        uvec = rng.normal(size=256).astype(np.float32)
        uvec /= np.linalg.norm(uvec)
        voices["S2"] = LabelVoice("S2", [Clip(8.0, 9.5, 2)], vector=uvec, spread=0.05, rms_db=-22.0, f0=130.0, f0_voiced=8)
    vname = "voices-wespeaker-deadbeef-aaaaaaaaaaaaaaaa-c00000000-" + tsha[:8] + ".json"
    store.write_voices(conv_id, vname, "wespeaker", "deadbeef12345678", voices, keep_vectors=set(voices))
    store.write_labels(conv_id, {"S1": {"person_id": gigi, "source": "auto", "distance": 0.01, "margin": None, "evidence_s": 6.5, "not": []}},
                       transcript_sha=tsha, voices=vname)
    return client, svc, store, gigi, gvec, conv_id, cdir / vname


def test_c4_01_recheck_corrupt_consent_keeps_vectors_and_auto_names(tmp_path: Path) -> None:
    """Question 1: Original IT4 C4-01 reproducer with flipped outcome on 55b6a29."""
    client, svc, store, gigi, _gvec, conv_id, vpath = _setup_gigi(tmp_path)
    orig_attested = store.person(gigi)["attested_at"]
    assert orig_attested is not None

    consent_path = store.person_dir(gigi) / "consent.json"
    valid_consent = consent_path.read_text()
    consent_path.write_text("{torn consent")

    svc.warm(now=2100.0)
    assert store.person(gigi)["attested_at"] == orig_attested
    issues = client.get("/v1/issues", headers=AUTH).json()["issues"]
    assert any(i["code"] == "speaker_files_unreadable" for i in issues)

    pruned = store.reconcile_vectors()
    store.db.set_meta("relabel_pending", "1")
    svc.pipeline.relabel(2200.0)
    s1_entry = json.loads(vpath.read_text())["labels"]["S1"]
    assert pruned == 0
    assert "vector_b64" in s1_entry and s1_entry.get("f0") == 210.0
    assert store.labels(conv_id)["S1"]["person_id"] == gigi

    # Repairing consent.json clears speaker_files_unreadable and keeps everything intact
    consent_path.write_text(valid_consent)
    svc.warm(now=2500.0)
    assert not any(i["code"] == "speaker_files_unreadable" for i in client.get("/v1/issues", headers=AUTH).json()["issues"])
    assert store.labels(conv_id)["S1"]["person_id"] == gigi
    assert (svc.vault.root / "People" / "Gigi.md").exists()
    assert len(list((store.person_dir(gigi) / "samples").glob("*.json"))) == 3
    client.app.state.db.close()


def test_q2_all_legitimate_opt_outs_prune_as_before(tmp_path: Path) -> None:
    """Question 2:
    1. DELETE /v1/people/{id} prunes vectors both when consent.json is valid AND when consent.json was corrupt!
    2. PUT /v1/speakers/settings {"acknowledged_at": null} prunes non-wearer vectors when consent.json is valid.
    3. PUT /v1/speakers/settings {"unknown_voices_enabled": false} prunes unnamed vectors while keeping consented ones.
    4. Clearing consent.json to `{}` or `{"attested_at": null}` is read as a dict (consent_unreadable=False) and prunes.
    """
    # 1a. Forget with valid consent.json
    c1, _, st1, g1, _, conv1, vp1 = _setup_gigi(tmp_path / "forget_valid")
    assert c1.delete(f"/v1/people/{g1}", headers=AUTH).status_code == 200
    assert not (st1.person_dir(g1) / "consent.json").exists()
    assert st1.person_policy(g1, st1.settings()) == "opted_out"
    assert "vector_b64" not in json.loads(vp1.read_text())["labels"]["S1"]
    assert (st1.labels(conv1).get("S1") or {}).get("person_id") is None
    c1.app.state.db.close()

    # 1b. Forget even when consent.json WAS corrupt beforehand!
    c1b, _, st1b, g1b, _, conv1b, vp1b = _setup_gigi(tmp_path / "forget_corrupt")
    (st1b.person_dir(g1b) / "consent.json").write_text("{torn")
    assert c1b.delete(f"/v1/people/{g1b}", headers=AUTH).status_code == 200
    assert not st1b.person_dir(g1b).exists()
    assert "vector_b64" not in json.loads(vp1b.read_text())["labels"]["S1"]
    assert (st1b.labels(conv1b).get("S1") or {}).get("person_id") is None
    c1b.app.state.db.close()

    # 2. Global acknowledgment withdrawn via API (valid consent.json)
    c2, _, st2, g2, _, _, vp2 = _setup_gigi(tmp_path / "withdraw_ack")
    assert c2.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH).status_code == 200
    assert st2.person_policy(g2, st2.settings()) == "opted_out"
    c2.app.state.speakers.pipeline.relabel(9000.0)  # (2026-11-26 R3, I4: a settings PUT records intent; the worker's relabel pass prunes)
    assert "vector_b64" not in json.loads(vp2.read_text())["labels"]["S1"]
    c2.app.state.db.close()

    # 3. Unknown voices turned off via API
    c3, _, _, _, _, _, vp3 = _setup_gigi(tmp_path / "unknown_off", unknown_voices=True, extra_unnamed=True)
    assert c3.put("/v1/speakers/settings", json={"unknown_voices_enabled": False}, headers=AUTH).status_code == 200
    c3.app.state.speakers.pipeline.relabel(9000.0)  # (2026-11-26 R3, I4: a settings PUT records intent; the worker's relabel pass prunes)
    labels3 = json.loads(vp3.read_text())["labels"]
    assert "vector_b64" in labels3["S1"] and "vector_b64" not in labels3["S2"]
    c3.app.state.db.close()

    # 4. Empty dict `{}` in consent.json
    c4, svc4, st4, g4, _, _, vp4 = _setup_gigi(tmp_path / "empty_dict")
    (st4.person_dir(g4) / "consent.json").write_text("{}")
    svc4.warm(now=2100.0)
    assert st4.person_policy(g4, st4.settings()) == "opted_out" and st4.person(g4)["attested_at"] is None
    assert st4.reconcile_vectors() == 1
    assert "vector_b64" not in json.loads(vp4.read_text())["labels"]["S1"]
    c4.app.state.db.close()


def test_c5_01_compound_global_ack_withdrawal_with_torn_consent_and_falsy_non_dict(tmp_path: Path) -> None:
    """C5-01 & C5-02b:
    1. Compound edge case (C5-01): If `consent.json` is already torn on disk AND the user withdraws global consent via
       `PUT /v1/speakers/settings` (`{"acknowledged_at": null}`, `unknown_voices_enabled=False`), `vector_labels()`
       (`store.py:899`) checks `elif person is not None and self.consent_unreadable(person["id"]):` without checking
       `prefs["acknowledged_at"]`, so `reconcile_vectors()` keeps S1's vector even though `consent_ok` is False
       independently of `consent.json`.
    2. Falsy non-dict JSON (`[]` or `null`) in `consent.json` (`store.py:230, 910`): `Vault.read_json(path) or {}`
       coerces `[]`/`null` to `{}`, treating it as readable empty consent (`consent_unreadable=False`) and pruning.
    """
    # 1. Compound global ack withdrawal + torn consent.json
    c1, _, _, g1, _, _, vp1 = _setup_gigi(tmp_path / "compound_ack")
    (c1.app.state.speakers.store.person_dir(g1) / "consent.json").write_text("{torn")
    assert c1.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH).status_code == 200
    c1.app.state.speakers.pipeline.relabel(9000.0)  # (2026-11-26 R3, I4: a settings PUT records intent; the worker's relabel pass prunes)
    assert "vector_b64" not in json.loads(vp1.read_text())["labels"]["S1"]
    c1.app.state.db.close()

    # 2. Falsy non-dict JSON (`[]`) in consent.json
    c2, svc2, st2, g2, _, _, vp2 = _setup_gigi(tmp_path / "falsy_json_list")
    (st2.person_dir(g2) / "consent.json").write_text("[]")
    svc2.warm(now=2100.0)
    assert st2.person_policy(g2, st2.settings()) == "frozen" and g2 in st2.unreadable_consent
    assert st2.reconcile_vectors() == 0
    assert "vector_b64" in json.loads(vp2.read_text())["labels"]["S1"]
    c2.app.state.db.close()


def test_q3_and_q4_never_consented_person_cannot_be_named_and_request_cost(tmp_path: Path, monkeypatch) -> None:
    """Questions 3 & 4:
    - Question 4: A person P who NEVER had consent (`attested_at` NULL, 0 samples) whose `consent.json` is torn:
      * keeps an existing stored label vector on C1 (`reconcile_vectors` == 0),
      * CANNOT create a voice sample on manual naming (`sample == "not_attested"`),
      * CANNOT be auto-named on a new conversation C2 (`identify` / `relabel` leave C2 unnamed because P has 0 samples
        and is absent from `models` and `space.centroids`).
    - Question 3 & C5-02a: Measure `consent_unreadable()` call counts and latencies across GET and PUT handlers.
    """
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    svc.pipeline.providers._embedder = _FakeEmb()
    store.update_settings(acknowledged_at="2026-11-01T00:00:00Z", unknown_voices_enabled=False, auto_assign=True)

    # Person P created WITHOUT attest_knows (never consented, 0 samples)
    bob = str(uuid.uuid4())
    assert client.put(f"/v1/people/{bob}", json={"name": "Bob", "me": False, "attest_knows": False}, headers=AUTH).status_code == 201
    assert store.person(bob)["attested_at"] is None

    rng = np.random.default_rng(9)
    bvec = rng.normal(size=256).astype(np.float32)
    bvec /= np.linalg.norm(bvec)

    # C1 had S1 manually named Bob while vector existed, and consent.json is torn
    c1, c2 = str(uuid.uuid4()), str(uuid.uuid4())
    segs = [{"speaker": "S1", "start": 0.0, "end": 8.0, "text": "Bob speaking"}]
    tsha = sha256_hex(canonical_json(segs).encode())
    for cid, ts in ((c1, 2000.0), (c2, 2100.0)):
        d = store.conv_dir(cid)
        d.mkdir(parents=True, exist_ok=True)
        (d / "transcript.json").write_text(json.dumps({"segments": segs, "audio_sha": "b" * 64,
                                                        "speaker_clips": {"S1": [[0.5, 4.0], [4.5, 7.5]]}}))
        with store.db.tx() as conn:
            conn.execute(
                'INSERT INTO conversations(id,device_id,start,"end",status,transcript_sha,audio_sha,blocks_json,created_at,updated_at) '
                "VALUES (?,?,?,?,?,?,?,?,?,?)",
                (cid, "dev1", ts, ts + 10, "done", tsha, "b" * 64, "[[0,10]]", ts, ts + 10),
            )
    vname = "voices-wespeaker-deadbeef-bbbbbbbbbbbbbbbb-c00000000-" + tsha[:8] + ".json"
    lv = LabelVoice("S1", [Clip(0.5, 4.0, 0), Clip(4.5, 7.5, 1)], vector=bvec.copy(), spread=0.05, rms_db=-20.0)
    store.write_voices(c1, vname, "wespeaker", "deadbeef12345678", {"S1": lv}, keep_vectors={"S1"})
    store.write_labels(c1, {"S1": {"person_id": bob, "source": "user", "distance": None, "margin": None, "evidence_s": 6.5, "not": []}},
                       transcript_sha=tsha, voices=vname)
    store.write_voices(c2, vname, "wespeaker", "deadbeef12345678", {"S1": lv}, keep_vectors={"S1"})

    pdir = store.person_dir(bob)
    pdir.mkdir(parents=True, exist_ok=True)
    (pdir / "consent.json").write_text("{torn never consented")
    svc.warm(now=2200.0)
    assert store.person(bob)["attested_at"] is None

    # Kept on C1 (named Bob + torn consent.json), while unnamed C2 IS pruned (unknown_voices_enabled=False) -> pruned == 1!
    assert store.reconcile_vectors() == 1
    assert "vector_b64" in json.loads((store.conv_dir(c1) / vname).read_text())["labels"]["S1"]
    assert "vector_b64" not in json.loads((store.conv_dir(c2) / vname).read_text())["labels"]["S1"]
    # Even with vector restored on C2, relabel NEVER auto-names Bob (0 samples, absent from models & space.centroids)
    store.write_voices(c2, vname, "wespeaker", "deadbeef12345678", {"S1": lv}, keep_vectors={"S1"})
    store.db.set_meta("relabel_pending", "1")
    svc.pipeline.relabel(2210.0)
    assert (store.labels(c2).get("S1") or {}).get("person_id") is None

    rev = store.db.one("SELECT speakers_revision FROM conversations WHERE id=?", (c2,))[0]
    r_assign = client.put(f"/v1/conversations/{c2}/speakers/S1",
                          json={"person_id": bob, "expected_revision": rev, "request_id": "req-bob-1"}, headers=AUTH)
    assert r_assign.status_code == 200 and r_assign.json()["sample"] == "not_attested"
    assert store.db.one("SELECT COUNT(*) FROM samples WHERE person_id=?", (bob,))[0] == 0

    # Question 3 cost probe: instrument consent_unreadable across 500 conversations naming unconsented Bob vs consented Alan
    alan = str(uuid.uuid4())
    assert client.put(f"/v1/people/{alan}", json={"name": "Alan", "me": True}, headers=AUTH).status_code == 201
    store.add_sample(alan, -bvec, model="wespeaker", model_sha="deadbeef12345678", source="user", seconds=6.0, day="2026-11-20", session="s-a")
    (pdir / "consent.json").unlink()  # Bob has no consent.json (normal unconsented person)
    svc.warm(now=2300.0)

    with store.db.tx() as conn:
        for i in range(500):
            cid = f"bulk-{i:04d}"
            conn.execute(
                'INSERT INTO conversations(id,device_id,start,"end",status,transcript_sha,audio_sha,blocks_json,created_at,updated_at) '
                "VALUES (?,?,?,?,?,?,?,?,?,?)",
                (cid, "dev1", 3000.0 + i, 3010.0 + i, "done", tsha, "b" * 64, "[[0,10]]", 3000.0, 3010.0),
            )
            conn.execute(
                "INSERT INTO voices(conversation_id,label,file,model,model_sha,vector,seconds,turns,spread,rms_db,clips_json) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (cid, "S1", vname, "wespeaker", "deadbeef12345678", bvec.astype("<f4").tobytes(), 6.5, 2, 0.05, -20.0, "[[0.5,4.0]]"),
            )
            conn.execute(
                "INSERT INTO speaker_labels(conversation_id,label,person_id,source,not_json,forgotten,samples_json) VALUES (?,?,?,?,?,?,?)",
                (cid, "S1", bob, "user", "[]", 0, "[]"),
            )

    calls = [0]
    real_cu = store.read_consent

    def counted_cu(pid: str) -> bool:
        calls[0] += 1
        return real_cu(pid)

    monkeypatch.setattr(store, "read_consent", counted_cu)

    # Core GET endpoints: 0 calls
    for ep in ("/v1/people", "/v1/speakers/suggestions", "/v1/issues", "/v1/status"):
        calls[0] = 0
        assert client.get(ep, headers=AUTH).status_code == 200
        assert calls[0] == 0

    # Publish a calibration.json so GET /v1/speakers/calibration evaluates calibrator.fingerprint() -> ga_population()
    from omi_notes.speakers.calibration import Calibrator
    assert Calibrator(svc.pipeline).run(force=True) is True

    # GET /v1/speakers/calibration calls gather() -> ga_population() -> uncached consent_unreadable per conv naming unconsented Bob
    calls[0] = 0
    t0 = time.perf_counter()
    assert client.get("/v1/speakers/calibration", headers=AUTH).status_code == 200
    cal_ms = round((time.perf_counter() - t0) * 1000, 2)
    cal_calls = calls[0]

    # And reconcile_vectors() (run on PUT /v1/speakers/settings or Worker.retention) also calls consent_unreadable per conv
    calls[0] = 0
    t0 = time.perf_counter()
    store.reconcile_vectors()
    rec_ms = round((time.perf_counter() - t0) * 1000, 2)
    rec_calls = calls[0]
    print("IT5_COST_PROBE:", {"calibration_get_ms_500_unconsented": cal_ms, "calibration_cu_calls": cal_calls,
                              "reconcile_ms_500_unconsented": rec_ms, "reconcile_cu_calls": rec_calls})
    # the GET reads no consent (the worker compares calibration inputs, Carbon D1); the worker reads Bob once
    assert cal_calls == 0 and rec_calls == 1
    client.app.state.db.close()


def test_c5_03_skipped_sample_deactivates_model_drops_auto_name_then_reconcile_vectors_destroys_stored_vector(tmp_path: Path) -> None:
    """Owner round5 REPORT.md line 27 claims a skipped sample file is 'Not destructive of stored data: vectors and user
    names are kept... the names return only at the next relabel.'
    In fact, with default `unknown_voices_enabled=False`, once `relabel()` clears `S1.person_id` to `None`, `S1` is now
    an *unnamed* label, so `Worker.retention() -> store.reconcile_vectors()` permanently strips `vector_b64` and `f0`
    from `voices-*.json`, and repairing the sample + forcing `relabel()` CANNOT restore the name without `reprocess`!
    """
    client, svc, store, gigi, _gvec, conv_id, vpath = _setup_gigi(tmp_path)
    sample_files = sorted((store.person_dir(gigi) / "samples").glob("*.json"))
    assert len(sample_files) == 3

    # Corrupt 1 of Gigi's 3 samples and trigger load_samples() (e.g. rebuild or another sample added) -> Gigi drops to 2 samples (< 3)
    saved_sample = sample_files[0].read_text()
    sample_files[0].write_text("{torn sample")
    store.load_samples()
    svc.refresh_people(now=2100.0)

    # A relabel runs meanwhile -> drops Gigi's auto-name on S1 -> Worker.retention() runs reconcile_vectors()
    store.db.set_meta("relabel_pending", "1")
    svc.pipeline.relabel(2150.0)
    assert (store.labels(conv_id).get("S1") or {}).get("person_id") == gigi
    pruned = store.reconcile_vectors()
    assert pruned == 0
    assert "vector_b64" in json.loads(vpath.read_text())["labels"]["S1"]

    # Repair the sample file and explicitly run relabel: vector is gone, so Gigi's name CANNOT return!
    sample_files[0].write_text(saved_sample)
    svc.warm(now=2500.0)
    store.db.set_meta("relabel_pending", "1")
    svc.pipeline.relabel(2510.0)
    assert (store.labels(conv_id).get("S1") or {}).get("person_id") == gigi
    client.app.state.db.close()

