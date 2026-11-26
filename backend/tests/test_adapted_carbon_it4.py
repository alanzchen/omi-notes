"""Independent IT4 probes for Round 3 (867e0b9..3460bf4): lock non-blocking, skip-and-record, consent, and load_samples."""

from __future__ import annotations

import json
import os
import threading
import time
import uuid
from pathlib import Path

import numpy as np
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.settings import Settings
from omi_notes.speakers import suggest as speaker_suggest
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


def test_q2_get_handlers_never_block_while_store_lock_held(tmp_path: Path) -> None:
    """Question 2: While a background build or mutation holds `store.lock`, GET /v1/people,
    GET /v1/speakers/suggestions, GET /v1/issues, and GET /v1/status all respond immediately without blocking.
    """
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    pid = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid}", json={"name": "Alan", "me": True}, headers=AUTH).status_code == 201

    locked = threading.Event()
    release = threading.Event()

    def hold_store_lock() -> None:
        with svc.store.lock:
            locked.set()
            assert release.wait(5.0)

    holder = threading.Thread(target=hold_store_lock)
    holder.start()
    assert locked.wait(2.0)
    try:
        latencies = {}
        for path in ("/v1/people", "/v1/speakers/suggestions", "/v1/issues", "/v1/status"):
            t0 = time.perf_counter()
            res = client.get(path, headers=AUTH)
            latencies[path] = round((time.perf_counter() - t0) * 1000, 2)
            assert res.status_code == 200
            assert latencies[path] < 100.0
        print("Q2_LOCK_HELD_GET_LATENCIES_MS:", latencies)
    finally:
        release.set()
        holder.join(5.0)
    client.app.state.db.close()


def test_c4_01_corrupt_consent_prunes_vectors_and_drops_auto_names_while_people_shows_active(tmp_path: Path) -> None:
    """C4-01 (Question 3 & 5):
    When a confirmed active non-wearer's `consent.json` becomes corrupt (`{torn`), `scan_people()` overwrites
    `people.attested_at = None` in SQLite (`consent_ok == False`):
    1. `/v1/people` STILL displays `auto_active: True` ("Named automatically") because `build_models` ignores `attested_at`
       (only `/v1/issues` shows `speaker_files_unreadable`, not the People card).
    2. With default `unknown_voices_enabled=False`, `Worker.retention()` -> `store.reconcile_vectors()` permanently
       prunes `vector_b64` from per-conversation `voices-*.json` for Gigi's labels, and `relabel()` then wipes Gigi's
       `source='auto'` assignments back to `person_id=None`.
    3. Restoring valid `consent.json` + `relabel()` CANNOT restore those auto-names because `vector_b64` was stripped!
    """
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    svc.pipeline.providers._embedder = _FakeEmb()

    store.update_settings(acknowledged_at="2026-11-01T00:00:00Z", unknown_voices_enabled=False, auto_assign=True)
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
    card_before = client.get("/v1/people", headers=AUTH).json()["people"][0]
    assert card_before["auto_active"] is True and card_before["status_line"] == "已启用"

    # Create a completed conversation whose S1 voice matched Gigi automatically and kept vector_b64 under Gigi's consent
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
    lv = LabelVoice("S1", [Clip(0.5, 4.0, 0), Clip(4.5, 7.5, 1)], vector=gvec.copy(), spread=0.05, rms_db=-20.0, f0=210.0, f0_voiced=10)
    svc.pipeline.identify(conv_id, type("A", (), {"pcm": np.zeros(160000, dtype=np.int16)})(), "a" * 64,
                          {}, tsha, {"S1"}, clip_spans={"S1": [[0.5, 4.0], [4.5, 7.5]]})
    # Write Gigi's voice directly via identify's stored path
    vname = "voices-wespeaker-deadbeef-aaaaaaaaaaaaaaaa-c00000000-" + tsha[:8] + ".json"
    store.write_voices(conv_id, vname, "wespeaker", "deadbeef12345678", {"S1": lv}, keep_vectors={"S1"})
    store.write_labels(conv_id, {"S1": {"person_id": gigi, "source": "auto", "distance": 0.01, "margin": None, "evidence_s": 6.5, "not": []}},
                       transcript_sha=tsha, voices=vname)
    assert "vector_b64" in json.loads((cdir / vname).read_text())["labels"]["S1"]
    assert store.labels(conv_id)["S1"]["person_id"] == gigi

    # Corrupt Gigi's consent.json
    consent_path = store.person_dir(gigi) / "consent.json"
    valid_consent = consent_path.read_text()
    consent_path.write_text("{torn consent")

    svc.warm(now=2100.0)
    card_corrupt = client.get("/v1/people", headers=AUTH).json()["people"][0]
    issues = client.get("/v1/issues", headers=AUTH).json()["issues"]
    # 2026-11-26 R3 (I1): FROZEN is never named anew, so the card says automatic naming is off, not active
    assert card_corrupt["auto_active"] is False and card_corrupt["status_line"] == "自动命名已关闭"
    assert any(i["code"] == "speaker_files_unreadable" for i in issues)

    # Worker.retention() runs reconcile_vectors(), then relabel runs (e.g. on next speaker change)
    pruned = store.reconcile_vectors()
    store.db.set_meta("relabel_pending", "1")
    svc.pipeline.relabel(2200.0)
    print("C4_01_CORRUPT_CONSENT:", {"pruned": pruned, "labels_after": store.labels(conv_id), "card": card_corrupt["status_line"]})
    assert pruned == 0
    assert "vector_b64" in json.loads((cdir / vname).read_text())["labels"].get("S1", {})
    assert (store.labels(conv_id).get("S1") or {}).get("person_id") == gigi

    # Even after fixing consent.json, relabel cannot restore Gigi's auto-name because vector_b64 was pruned
    consent_path.write_text(valid_consent)
    svc.warm(now=2300.0)
    store.db.set_meta("relabel_pending", "1")
    svc.pipeline.relabel(2305.0)
    assert (store.labels(conv_id).get("S1") or {}).get("person_id") == gigi
    # People note and sample files themselves are untouched
    assert (svc.vault.root / "People" / "Gigi.md").exists()
    assert len(list((store.person_dir(gigi) / "samples").glob("*.json"))) == 3
    client.app.state.db.close()


def test_c4_02_residual_bad_files_escape_skip_and_wedge_people_stale_without_emptying_samples(tmp_path: Path, monkeypatch) -> None:
    """C4-02 (Question 1, 3, 4):
    Three residual bad-file shapes still escape C2-02's skip-and-record, wedging `refresh_people()` stale without
    recording `speaker_files_unreadable` in `/v1/issues`, while `load_samples()`'s single transaction keeps
    existing SQLite `samples` rows intact:
    (a) Valid-JSON sample dict with valid base64 missing required keys (`KeyError` in `_index_sample`) or
        non-float32 byte length (`ValueError` in `decode_vector`).
    (b) Unreadable `transcript.json` on a multi-day suggestion's *other-day* member in `_other_day()` (`service.py:748`).
    (c) Corrupt sample JSON under a folder-only person (`_omi/people/<id>/` with no `People/<Name>.md`) in
        `scan_people()` -> `_name_from_samples()` (`store.py:254`).
    """
    client = TestClient(create_app(_settings(tmp_path), start_worker=False), raise_server_exceptions=False)
    svc = client.app.state.speakers
    store = svc.store
    svc.pipeline.providers._embedder = _FakeEmb()

    pid = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid}", json={"name": "Alan", "me": True}, headers=AUTH).status_code == 201
    vec = np.ones(256, dtype=np.float32) / np.sqrt(256)
    store.add_sample(pid, vec, model="wespeaker", model_sha="deadbeef12345678", source="user", seconds=6.0, day="2026-11-20", session="c1")
    svc.warm(now=1000.0)

    # (a) Sample JSON dict passes `Vault.read_json` + `base64.b64decode`, fails `_index_sample` inside `with self.db.tx():`
    bad_sample = store.person_dir(pid) / "samples" / "00000000-0000-4000-8000-000000000001.json"
    for payload in (
        {"vector_b64": "AAAA"},  # KeyError: 'sample_id'
        {"sample_id": "00000000-0000-4000-8000-000000000001", "person_id": pid, "model": "wespeaker",
         "model_sha": "deadbeef12345678", "source": "user", "vector_b64": "AQ=="},  # ValueError: buffer size % 4 != 0
    ):
        bad_sample.write_text(json.dumps(payload))
        assert svc.refresh_people(now=1010.0) is False
        # Question 4 verification: single transaction rolled back DELETE FROM samples, so good sample row is preserved!
        assert store.db.one("SELECT COUNT(*) AS n FROM samples")["n"] == 1
        ans = client.get("/v1/people", headers=AUTH).json()
        issues = [i for i in client.get("/v1/issues", headers=AUTH).json()["issues"] if i["code"] == "speaker_files_unreadable"]
        assert ans.get("stale") is True and issues == []
    bad_sample.unlink()
    assert svc.refresh_people(now=1020.0) is True

    # (b) Multi-day suggestion where rep's transcript.json is valid, but other-day member m2's transcript.json is corrupt
    c1, c2 = str(uuid.uuid4()), str(uuid.uuid4())
    for cid, start in ((c1, 2000.0), (c2, 100000.0)):
        with store.db.tx() as conn:
            conn.execute(
                'INSERT INTO conversations(id,device_id,start,"end",status,transcript_sha,blocks_json,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)',
                (cid, "dev1", start, start + 10, "done", "sha", "[[0,10]]", start, start),
            )
    d1, d2 = store.conv_dir(c1), store.conv_dir(c2)
    d1.mkdir(parents=True, exist_ok=True)
    d2.mkdir(parents=True, exist_ok=True)
    (d2 / "transcript.json").write_text(json.dumps({"segments": [{"speaker": "S1", "start": 0.0, "end": 5.0, "text": "Rep ok"}]}))
    (d1 / "transcript.json").write_text("{corrupt other-day transcript")

    m_rep = speaker_suggest.Candidate(c2, "S1", vec, 6.0, "2026-11-21", -20.0)
    m_old = speaker_suggest.Candidate(c1, "S1", vec, 6.0, "2026-11-20", -20.0)
    sug = type("Sug", (), {
        "id": "sug-1", "kind": "who_is_this", "person_id": None, "seconds": 12.0,
        "conversations": 2, "days": 2, "representative": m_rep, "members": [m_rep, m_old],
    })()
    monkeypatch.setattr(svc, "_suggestions", lambda now: ([sug], {}))
    assert svc.refresh_people(now=1030.0) is False
    assert client.get("/v1/people", headers=AUTH).json().get("stale") is True
    assert [i for i in client.get("/v1/issues", headers=AUTH).json()["issues"] if i["code"] == "speaker_files_unreadable"] == []
    monkeypatch.undo()
    assert svc.refresh_people(now=1040.0) is True

    # (c) Folder-only person (`_omi/people/<pid_orphan>/samples/bad.json`, no `People/*.md`) crashes `scan_people()`
    orphan = str(uuid.uuid4())
    orphan_sdir = store.person_dir(orphan) / "samples"
    orphan_sdir.mkdir(parents=True, exist_ok=True)
    (orphan_sdir / f"{uuid.uuid4()}.json").write_text("{corrupt orphan sample")
    assert svc.refresh_people(now=1050.0) is False
    # And PUT /v1/people/{new} returns 500 because _put_person_write -> store.put_person -> scan_people raises!
    assert client.put(f"/v1/people/{uuid.uuid4()}", json={"name": "CrashTest"}, headers=AUTH).status_code == 500
    client.app.state.db.close()


def test_c4_03_stat_key_reloads_on_normal_fix_but_caches_same_mtime_size_and_hides_missing_vector(tmp_path: Path) -> None:
    """C4-03 (Question 3):
    1. A torn/partially written sample file that is later completed normally (new size/mtime_ns) IS reloaded automatically.
    2. A skipped file replaced with equal byte size AND preserved `mtime_ns` (`cp -p` / `rsync -t`) stays skipped
       because `_stat_key` omits `st_ino`/`st_ctime_ns`, then reloads once `mtime_ns` changes.
    3. A sample JSON dict missing `vector_b64` is skipped with `unreadable=False`, hiding it without `/v1/issues`.
    """
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    svc.pipeline.providers._embedder = _FakeEmb()

    pid = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid}", json={"name": "Alan", "me": True}, headers=AUTH).status_code == 201
    vec = np.ones(256, dtype=np.float32) / np.sqrt(256)
    sid_ref = store.add_sample(pid, vec, model="wespeaker", model_sha="deadbeef12345678", source="user", seconds=6.0, day="2026-11-20", session="c1")
    valid_obj = json.loads(store.sample_path(pid, sid_ref).read_text())

    # 1. Partially written file -> later completed via normal write: reloads cleanly!
    sid_partial = str(uuid.uuid4())
    p_partial = store.sample_path(pid, sid_partial)
    valid_bytes = json.dumps(valid_obj | {"sample_id": sid_partial}).encode()
    p_partial.write_bytes(valid_bytes[:40])  # partial write
    svc.warm(now=1100.0)
    assert client.get("/v1/people", headers=AUTH).json()["people"][0]["samples"] == 1
    p_partial.write_bytes(valid_bytes)  # write finishes
    svc.warm(now=1110.0)
    assert client.get("/v1/people", headers=AUTH).json()["people"][0]["samples"] == 2

    # 2. Corrupt file replaced with exact same byte length AND preserved mtime_ns (`rsync -t` / `cp -p` simulation)
    sid_same = str(uuid.uuid4())
    p_same = store.sample_path(pid, sid_same)
    good_same = json.dumps(valid_obj | {"sample_id": sid_same}).encode()
    corrupt_same = b"{" + b"x" * (len(good_same) - 1)
    assert len(corrupt_same) == len(good_same)
    p_same.write_bytes(corrupt_same)
    orig_st = p_same.stat()
    svc.warm(now=1120.0)
    assert client.get("/v1/people", headers=AUTH).json()["people"][0]["samples"] == 2

    tmp_rep = p_same.with_suffix(".repaired")
    tmp_rep.write_bytes(good_same)
    os.utime(tmp_rep, ns=(orig_st.st_atime_ns, orig_st.st_mtime_ns))
    os.replace(tmp_rep, p_same)  # new inode & ctime_ns, same mtime_ns & size
    svc.warm(now=1130.0)
    assert client.get("/v1/people", headers=AUTH).json()["people"][0]["samples"] == 2  # still hidden!
    os.utime(p_same, ns=(orig_st.st_atime_ns, orig_st.st_mtime_ns + 1))
    svc.warm(now=1140.0)
    assert client.get("/v1/people", headers=AUTH).json()["people"][0]["samples"] == 3  # reloads once mtime_ns advances!

    # 3. Sample dict missing vector_b64 is skipped with unreadable=False -> hidden without speaker_files_unreadable
    sid_novec = str(uuid.uuid4())
    store.sample_path(pid, sid_novec).write_text(json.dumps({"sample_id": sid_novec, "person_id": pid}))
    svc.warm(now=1150.0)
    assert client.get("/v1/people", headers=AUTH).json()["people"][0]["samples"] == 3
    assert [i for i in client.get("/v1/issues", headers=AUTH).json()["issues"] if i["code"] == "speaker_files_unreadable"] == []
    client.app.state.db.close()
