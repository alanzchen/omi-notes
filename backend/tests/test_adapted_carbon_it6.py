"""Independent verification & probes for OMI-NIGHTLY-2026-11-25-CARBON-IT6 (pin 0227082)."""

from __future__ import annotations

import json
import time
import uuid
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.speakers.calibration import Calibrator
from omi_notes.settings import Settings
from omi_notes.speakers.voices import Clip, LabelVoice
from omi_notes.util import canonical_json, sha256_hex

AUTH = {"Authorization": "Bearer tok"}


class _FakeEmb:
    model = "wespeaker"
    model_sha = "deadbeef12345678"

    def __init__(self, vec: np.ndarray | None = None) -> None:
        self._vec = vec

    def embed(self, pcm: np.ndarray) -> np.ndarray:
        return self._vec if self._vec is not None else np.ones(256, dtype=np.float32) / np.sqrt(256)


def _settings(root: Path) -> Settings:
    return Settings(
        vault_dir=root / "vault",
        index_dir=root / "index",
        lock_dir=root / "locks",
        omi_notes_token="tok",
        stt_provider="fake",
        llm_provider="fake",
    )


def _setup_gigi(tmp_path: Path, *, n_samples: int = 3, unknown_voices: bool = False):
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    rng = np.random.default_rng(42)
    gvec = rng.normal(size=256).astype(np.float32)
    gvec /= np.linalg.norm(gvec)
    svc.pipeline.providers._embedder = _FakeEmb(gvec)

    store.update_settings(acknowledged_at="2026-11-01T00:00:00Z", unknown_voices_enabled=unknown_voices, auto_assign=True)
    gigi = str(uuid.uuid4())
    assert client.put(f"/v1/people/{gigi}", json={"name": "Gigi", "me": False, "attest_knows": True}, headers=AUTH).status_code == 201

    for i in range(n_samples):
        v = gvec + 0.01 * rng.normal(size=256).astype(np.float32)
        v /= np.linalg.norm(v)
        store.add_sample(gigi, v, model="wespeaker", model_sha="deadbeef12345678", source="user",
                         seconds=6.0, day=f"2026-11-{18 + i:02d}", session=f"s-{i}")
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
    vname = "voices-wespeaker-deadbeef-aaaaaaaaaaaaaaaa-c00000000-" + tsha[:8] + ".json"
    store.write_voices(conv_id, vname, "wespeaker", "deadbeef12345678", voices, keep_vectors={"S1"})
    store.write_labels(conv_id, {"S1": {"person_id": gigi, "source": "auto", "distance": 0.01, "margin": None, "evidence_s": 6.5, "not": []}},
                       transcript_sha=tsha, voices=vname)
    return client, svc, store, gigi, gvec, conv_id, cdir / vname


def test_it5_reproducers_rechecked_on_0227082(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Question 1 & 4: Re-run IT5 reproducers (C5-01, C5-02, C5-03) with flipped outcomes on 0227082."""
    # 1. C5-01a: compound global acknowledgment withdrawal + torn consent.json NOW prunes vector!
    c1, _, st1, g1, _, _, vp1 = _setup_gigi(tmp_path / "c5_01a")
    (st1.person_dir(g1) / "consent.json").write_text("{torn")
    assert c1.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH).status_code == 200
    c1.app.state.speakers.pipeline.relabel(9000.0)  # (2026-11-26 R3, I4: a settings PUT records intent; the worker's relabel pass prunes)
    assert "vector_b64" not in json.loads(vp1.read_text())["labels"]["S1"]
    c1.app.state.db.close()

    # 2. C5-01b: non-object JSON (`[]`, `null`, `0`, `""`, `false`) is NOW unreadable (keeps vector), while `{}` prunes!
    for idx, content in enumerate(("[]", "null", "0", '""', "false")):
        ck, svck, stk, gk, _, _, vpk = _setup_gigi(tmp_path / f"c5_01b_{idx}")
        (stk.person_dir(gk) / "consent.json").write_text(content)
        svck.warm(now=2100.0)
        assert stk.person_policy(gk, stk.settings()) == "frozen" and gk in stk.unreadable_consent
        assert stk.reconcile_vectors() == 0
        assert "vector_b64" in json.loads(vpk.read_text())["labels"]["S1"]
        ck.app.state.db.close()

    # 3. C5-02: skipped sample defers relabel (keeps auto name & vector), and repairing it sets relabel_pending!
    c2, svc2, st2, g2, _, conv2, vp2 = _setup_gigi(tmp_path / "c5_02")
    sfiles = sorted((st2.person_dir(g2) / "samples").glob("*.json"))
    saved = sfiles[0].read_text()
    sfiles[0].write_text("{torn sample")
    st2.load_samples()
    svc2.refresh_people(now=2100.0)
    st2.db.set_meta("relabel_pending", "1")
    svc2.pipeline.relabel(2150.0)
    assert st2.labels(conv2)["S1"]["person_id"] == g2
    assert st2.reconcile_vectors() == 0
    assert "vector_b64" in json.loads(vp2.read_text())["labels"]["S1"]

    # Confirm relabel_pending does NOT loop while still torn
    assert st2.db.meta("relabel_pending") is None
    assert st2.sync_samples() is False
    st2.load_samples()
    assert st2.db.meta("relabel_pending") is None

    # Repairing the sample sets relabel_pending = "1"
    sfiles[0].write_text(saved)
    assert st2.sync_samples() is True
    assert st2.db.meta("relabel_pending") == "1"
    c2.app.state.db.close()

    # 4. C5-03: read_consent memoized to 1 call per person across 500 conversations in ga_population & reconcile_vectors!
    c3, svc3, st3, _, gvec, _, _ = _setup_gigi(tmp_path / "c5_03")
    bob = str(uuid.uuid4())
    assert c3.put(f"/v1/people/{bob}", json={"name": "Bob", "me": False, "attest_knows": False}, headers=AUTH).status_code == 201
    with st3.db.tx() as conn:
        for i in range(500):
            cid = f"bulk-{i:04d}"
            conn.execute(
                'INSERT INTO conversations(id,device_id,start,"end",status,transcript_sha,audio_sha,blocks_json,created_at,updated_at) '
                "VALUES (?,?,?,?,?,?,?,?,?,?)",
                (cid, "dev1", 3000.0 + i, 3010.0 + i, "done", "sha", "b" * 64, "[[0,10]]", 3000.0, 3010.0),
            )
            conn.execute(
                "INSERT INTO voices(conversation_id,label,file,model,model_sha,vector,seconds,turns,spread,rms_db,clips_json) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (cid, "S1", "voices.json", "wespeaker", "deadbeef12345678", gvec.astype("<f4").tobytes(), 6.5, 2, 0.05, -20.0, "[[0.5,4.0]]"),
            )
            conn.execute(
                "INSERT INTO speaker_labels(conversation_id,label,person_id,source,not_json,forgotten,samples_json) VALUES (?,?,?,?,?,?,?)",
                (cid, "S1", bob, "user", "[]", 0, "[]"),
            )
    assert Calibrator(svc3.pipeline).run(force=True) is True
    rc_calls = [0]
    real_rc = st3.read_consent

    def counted_rc(pid: str) -> dict:
        rc_calls[0] += 1
        return real_rc(pid)

    monkeypatch.setattr(st3, "read_consent", counted_rc)
    t0 = time.perf_counter()
    assert c3.get("/v1/speakers/calibration", headers=AUTH).status_code == 200
    cal_ms = round((time.perf_counter() - t0) * 1000, 2)
    cal_rc = rc_calls[0]
    rc_calls[0] = 0
    st3.reconcile_vectors()
    rec_rc = rc_calls[0]
    print("IT6_MEMO_COST:", {"calibration_ms": cal_ms, "calibration_read_consent_calls": cal_rc, "reconcile_read_consent_calls": rec_rc})
    # the GET reads no consent (Carbon D1); the worker reads one each for Gigi and Bob
    assert cal_rc == 0 and rec_rc == 2
    c3.app.state.db.close()


def test_c6_01_deferral_keeps_auto_names_and_vectors_alive_after_opt_outs_and_keeps_identifying(tmp_path: Path) -> None:
    """C6-01 (Question 2 — Privacy & opt-out interaction with C5-02 deferral):
    1. Global acknowledgment withdrawn (`PUT /v1/speakers/settings` `{"acknowledged_at": null}`) while Gigi has a torn
       sample: `reconcile_vectors()` prunes S1's vector, YET `relabel()`'s `was` check (`conversations.py:971-974`)
       restores `states["S1"] = cur`, keeping Gigi's `source='auto'` name alive indefinitely! (Same if `consent.json` -> `{}`.)
    2. `PUT /v1/speakers/settings` `{"auto_assign": false}` (with `unknown_voices_enabled=False`) while Gigi has a torn
       sample: `relabel()`'s `was` check restores `states["S1"] = cur`, keeping BOTH Gigi's `source='auto'` name AND
       (because S1 stays named Gigi!) her stored `vector_b64` in `voices-*.json` alive indefinitely!
    3. When Gigi has 4 confirmed samples and 1 sample stays unreadable (3 readable remain active, `gigi in deferred`),
       `identify()` (`conversations.py:851`) ignores `deferred_people()` and keeps auto-naming Gigi on new conversations
       indefinitely (and `relabel()`'s `was` branch then freezes those new auto-names too).
    """
    # 1. Global acknowledgment withdrawn while Gigi is deferred -> vector pruned, auto-name kept alive!
    c1, svc1, st1, g1, _, conv1, vp1 = _setup_gigi(tmp_path / "optout_ack")
    sorted((st1.person_dir(g1) / "samples").glob("*.json"))[0].write_text("{torn")
    st1.load_samples()
    assert g1 in st1.frozen_by_samples()
    assert c1.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH).status_code == 200
    svc1.pipeline.relabel(2150.0)  # (2026-11-26 R3, I4: a settings PUT records intent; the worker's relabel pass prunes)
    assert "vector_b64" not in json.loads(vp1.read_text())["labels"]["S1"]
    st1.db.set_meta("relabel_pending", "1")
    svc1.pipeline.relabel(2200.0)
    print("C6_01_ACK_WITHDRAWN:", st1.labels(conv1))
    assert (st1.labels(conv1).get("S1") or {}).get("person_id") is None
    c1.app.state.db.close()

    # 2. auto_assign=False opted out while Gigi is deferred -> BOTH auto-name AND stored vector kept alive!
    c2, svc2, st2, g2, _, conv2, vp2 = _setup_gigi(tmp_path / "optout_auto_off")
    sorted((st2.person_dir(g2) / "samples").glob("*.json"))[0].write_text("{torn")
    st2.load_samples()
    assert c2.put("/v1/speakers/settings", json={"auto_assign": False}, headers=AUTH).status_code == 200
    svc2.pipeline.relabel(2200.0)
    st2.reconcile_vectors()
    print("C6_01_AUTO_OFF:", st2.labels(conv2), "vector_kept:", "vector_b64" in json.loads(vp2.read_text())["labels"]["S1"])
    assert (st2.labels(conv2).get("S1") or {}).get("person_id") is None
    assert "vector_b64" not in json.loads(vp2.read_text())["labels"]["S1"]
    c2.app.state.db.close()

    # 3. 4-sample deferred person: identify() keeps auto-naming new conversations indefinitely while 1 sample is torn!
    c3, svc3, st3, g3, _, _, _ = _setup_gigi(tmp_path / "identify_4samples", n_samples=4)
    sorted((st3.person_dir(g3) / "samples").glob("*.json"))[0].write_text("{torn")
    st3.load_samples()
    assert g3 in st3.frozen_by_samples()

    new_conv = str(uuid.uuid4())
    segs = [{"speaker": "S1", "start": 0.0, "end": 8.0, "text": "New recording while deferred"}]
    tsha = sha256_hex(canonical_json(segs).encode())
    ndir = st3.conv_dir(new_conv)
    ndir.mkdir(parents=True, exist_ok=True)
    (ndir / "transcript.json").write_text(json.dumps({"segments": segs, "audio_sha": "c" * 64, "speaker_clips": {"S1": [[0.5, 4.0], [4.5, 7.5]]}}))
    with st3.db.tx() as conn:
        conn.execute(
            'INSERT INTO conversations(id,device_id,start,"end",status,transcript_sha,audio_sha,blocks_json,created_at,updated_at) '
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (new_conv, "dev1", 2500.0, 2510.0, "done", tsha, "c" * 64, "[[2500,2510]]", 2500.0, 2510.0),
        )
    fake_audio = type("Audio", (), {"pcm": np.ones(160000, dtype=np.int16)})()
    svc3.pipeline.identify(new_conv, fake_audio, "c" * 64, {"S1": [Clip(0.5, 4.0, 0), Clip(4.5, 7.5, 1)]}, tsha, {"S1"})
    print("C6_01_NEW_CONV_IDENTIFIED_WHILE_DEFERRED:", st3.labels(new_conv))
    assert (st3.labels(new_conv).get("S1") or {}).get("person_id") is None
    c3.app.state.db.close()


def test_c6_02_and_c6_03_deferral_liveness_on_unlink_and_empty_label_state(tmp_path: Path) -> None:
    """Question 3 (C6-02 & C6-03):
    1. C6-02: Removing (`unlink`ing) an unreadable sample file (as `/v1/issues` `server_step` instructs: 'Fix or remove
       these files in the vault') ends deferral (`deferred_people() == set()`), but `load_samples()` sees `before == after`
       (`{s1, s2} == {s1, s2}`) and NEVER sets `relabel_pending`, leaving the inactive 2-sample person's `source='auto'`
       names frozen!
    2. C6-03: On a conversation whose `speakers.json` had NO label state (`current == {}`), deferring `now_auto` for a
       4-sample deferred person executes `states[label] = cur if cur else st | {"person_id": None, "source": None}`
       (`conversations.py:974`), retaining `st["distance"]` so `persisted(states)` writes `speakers.json` for a label
       that previously had no state!
    """
    # 1. C6-02: Unlinking the torn sample clears deferral without setting relabel_pending
    c1, svc1, st1, g1, _, conv1, _ = _setup_gigi(tmp_path / "unlink_liveness", n_samples=3)
    bad = sorted((st1.person_dir(g1) / "samples").glob("*.json"))[0]
    bad.write_text("{torn")
    st1.load_samples()
    svc1.pipeline.relabel(2100.0)
    assert st1.db.meta("relabel_pending") is None and st1.labels(conv1)["S1"]["person_id"] == g1

    bad.unlink()  # User follows server_step: "Fix or remove these files in the vault"
    assert st1.sync_samples() is True
    assert st1.frozen_by_samples() == set()
    print("C6_02_AFTER_UNLINK:", {"relabel_pending": st1.db.meta("relabel_pending"), "labels": st1.labels(conv1)})
    assert st1.db.meta("relabel_pending") == "1"
    svc1.pipeline.relabel(2200.0)
    assert (st1.labels(conv1).get("S1") or {}).get("person_id") is None
    c1.app.state.db.close()

    # 2. C6-03: Conversation with NO prior speakers.json gets speakers.json written when now_auto is deferred
    c2, svc2, st2, g2, gvec, _, _ = _setup_gigi(tmp_path / "empty_state_write", n_samples=4, unknown_voices=True)
    sorted((st2.person_dir(g2) / "samples").glob("*.json"))[0].write_text("{torn")
    st2.load_samples()

    empty_conv = str(uuid.uuid4())
    segs = [{"speaker": "S1", "start": 0.0, "end": 8.0, "text": "No speakers.json yet"}]
    tsha = sha256_hex(canonical_json(segs).encode())
    edir = st2.conv_dir(empty_conv)
    edir.mkdir(parents=True, exist_ok=True)
    (edir / "transcript.json").write_text(json.dumps({"segments": segs, "audio_sha": "d" * 64}))
    with st2.db.tx() as conn:
        conn.execute(
            'INSERT INTO conversations(id,device_id,start,"end",status,transcript_sha,audio_sha,blocks_json,created_at,updated_at) '
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (empty_conv, "dev1", 2600.0, 2610.0, "done", tsha, "d" * 64, "[[2600,2610]]", 2600.0, 2610.0),
        )
    lv = LabelVoice("S1", [Clip(0.5, 4.0, 0), Clip(4.5, 7.5, 1)], vector=gvec.copy(), spread=0.05, rms_db=-20.0)
    st2.write_voices(empty_conv, "voices-wespeaker-deadbeef-dddddddddddddddd-c00000000-" + tsha[:8] + ".json",
                     "wespeaker", "deadbeef12345678", {"S1": lv}, keep_vectors={"S1"})
    assert not (edir / "speakers.json").exists() and st2.labels(empty_conv) == {}

    st2.db.set_meta("relabel_pending", "1")
    svc2.pipeline.relabel(2700.0)
    print("C6_03_EMPTY_STATE_WRITTEN:", (edir / "speakers.json").exists(), st2.labels(empty_conv))
    assert not (edir / "speakers.json").exists() and st2.labels(empty_conv) == {}
    c2.app.state.db.close()
