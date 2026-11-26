"""Carbon IT1 (2026-11-26) probes C1-01..C1-03, ported with the outcomes the invariants require (I1 outputs, I2 gains, I4
worker pruning). Helpers copied unchanged."""

from __future__ import annotations

import json
import os
import time
import uuid
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.pipeline.conversations import BACKGROUND_MIN_VOICES
from omi_notes.settings import Settings
from omi_notes.speakers.calibration import Calibrator
from omi_notes.speakers.store import FROZEN, NORMAL, OPTED_OUT
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


def _add_conv(store, conv_id: str, vec: np.ndarray, *, person_id: str | None = None, source: str | None = None,
              keep_vec: bool = True, start: float = 2000.0, sha_char: str = "a") -> Path:
    segments = [{"speaker": "S1", "start": 0.0, "end": 15.0, "text": f"Hello in {conv_id}"}]
    tsha = sha256_hex(canonical_json(segments).encode())
    ash = (sha_char * 64)[:64]
    cdir = store.conv_dir(conv_id)
    cdir.mkdir(parents=True, exist_ok=True)
    (cdir / "transcript.json").write_text(
        json.dumps({"segments": segments, "audio_sha": ash, "speaker_clips": {"S1": [[0.5, 7.0], [7.5, 14.0]]}})
    )
    with store.db.tx() as conn:
        conn.execute(
            'INSERT INTO conversations(id,device_id,start,"end",status,transcript_sha,audio_sha,blocks_json,created_at,updated_at) '
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (conv_id, "dev1", start, start + 15.0, "done", tsha, ash, json.dumps([[start, start + 15.0]]), start, start + 15.0),
        )
    voices = {"S1": LabelVoice("S1", [Clip(0.5, 7.0, 0), Clip(7.5, 14.0, 1)], vector=vec.copy(), spread=0.05, rms_db=-20.0, f0=210.0, f0_voiced=10)}
    vname = f"voices-wespeaker-deadbeef-{ash[:16]}-c00000000-{tsha[:8]}.json"
    store.write_voices(conv_id, vname, "wespeaker", "deadbeef12345678", voices, keep_vectors={"S1"} if keep_vec else set())
    if person_id is not None:
        store.write_labels(
            conv_id,
            {"S1": {"person_id": person_id, "source": source, "distance": 0.01, "margin": None, "evidence_s": 6.5, "not": []}},
            transcript_sha=tsha,
            voices=vname,
        )
    else:
        store.reference_voices(conv_id, vname)
    return cdir / vname


def _setup_person(tmp_path: Path, *, n_samples: int = 3, unknown_voices: bool = False, me: bool = False, source: str = "auto"):
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    rng = np.random.default_rng(42)
    gvec = rng.normal(size=256).astype(np.float32)
    gvec /= np.linalg.norm(gvec)
    svc.pipeline.providers._embedder = _FakeEmb(gvec)

    store.update_settings(acknowledged_at="2026-11-01T00:00:00Z", unknown_voices_enabled=unknown_voices, auto_assign=True)
    pid = str(uuid.uuid4())
    body = {"name": "Gigi", "me": me} | ({} if me else {"attest_knows": True})
    assert client.put(f"/v1/people/{pid}", json=body, headers=AUTH).status_code == 201
    for i in range(n_samples):
        v = gvec + 0.01 * rng.normal(size=256).astype(np.float32)
        v /= np.linalg.norm(v)
        store.add_sample(pid, v, model="wespeaker", model_sha="deadbeef12345678", source="user",
                         seconds=6.0, day=f"2026-11-{18 + i:02d}", session=f"s-{i}")
    svc.warm(now=1000.0)
    conv_id = str(uuid.uuid4())
    vp = _add_conv(store, conv_id, gvec, person_id=pid, source=source)
    return client, svc, store, pid, gvec, conv_id, vp


def test_c1_01_an_opted_out_person_is_named_by_no_review_hint_suggestion_or_people_card(tmp_path: Path) -> None:
    """C1-01 (Question 1 & 6): With >= BACKGROUND_MIN_VOICES background vectors and unknown_voices_enabled=True,
    opting Gigi out suppresses `pipeline.possible_voice_names`, YET:
    1) `GET /v1/speakers/review` (`Review._hint_people`, `speakers/review.py:420-434`) STILL emits `reasons: ['possible']` for Gigi,
    2) `GET /v1/speakers/suggestions` (`SpeakerService._suggestions`, `speakers/service.py:691-695`) STILL emits `is_this_person` for Gigi,
    3) `GET /v1/people` (`SpeakerService._compute_people`, `speakers/service.py:242,254-256`) STILL shows `auto_active: True` for Gigi!
    """
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    rng = np.random.default_rng(123)

    # Create orthogonal-ish unit vectors for wearer Alan and non-wearer Gigi
    avec = np.zeros(256, dtype=np.float32)
    avec[0] = 1.0
    gvec = np.zeros(256, dtype=np.float32)
    gvec[1] = 1.0
    svc.pipeline.providers._embedder = _FakeEmb(gvec)
    store.update_settings(acknowledged_at="2026-11-01T00:00:00Z", unknown_voices_enabled=True, auto_assign=False)

    alan = str(uuid.uuid4())
    gigi = str(uuid.uuid4())
    assert client.put(f"/v1/people/{alan}", json={"name": "Alan", "me": True}, headers=AUTH).status_code == 201
    assert client.put(f"/v1/people/{gigi}", json={"name": "Gigi", "me": False, "attest_knows": True}, headers=AUTH).status_code == 201

    # Populate >= BACKGROUND_MIN_VOICES (205) diverse consented wearer samples so voice_space(embedder) is non-None
    for i in range(BACKGROUND_MIN_VOICES + 5):
        v = rng.normal(size=256).astype(np.float32)
        v[1] = -abs(v[1])  # keep background away from gvec[1]=+1 so Gigi's centred cosine is high
        v /= np.linalg.norm(v)
        store.add_sample(alan, v, model="wespeaker", model_sha="deadbeef12345678", source="user",
                         seconds=6.0, day=f"2026-10-{(i % 28) + 1:02d}", session=f"bg-{i}")

    for i in range(3):
        v = gvec + 0.005 * rng.normal(size=256).astype(np.float32)
        v /= np.linalg.norm(v)
        store.add_sample(gigi, v, model="wespeaker", model_sha="deadbeef12345678", source="user",
                         seconds=6.0, day=f"2026-11-{10 + i:02d}", session=f"g-{i}")

    # 3 unnamed conversations across >= 2 days with >= 10 s speech so suggestions, review hints, and note hints all apply
    targets = [str(uuid.uuid4()) for _ in range(3)]
    for idx, tcid in enumerate(targets):
        _add_conv(store, tcid, gvec, person_id=None, start=5000.0 + idx * 86400.0, sha_char=chr(ord("e") + idx))
    target = targets[0]
    tsha = store.current_transcript_sha(target)
    svc.warm(now=5000.0 + 3 * 86400.0)

    # Sanity check BEFORE opt-out: non-vacuous! All three surfaces name Gigi!
    pre_hints = svc.pipeline.possible_voice_names(target, tsha)
    pre_rev = client.get("/v1/speakers/review", headers=AUTH).json()["items"]
    pre_sug = client.get("/v1/speakers/suggestions", headers=AUTH).json()["suggestions"]
    assert pre_hints == {"S1": ("Gigi", False)}
    assert any(it["person_id"] == gigi and it["reasons"] == ["possible"] for it in pre_rev)
    assert any(s["kind"] == "is_this_person" and s["person_id"] == gigi for s in pre_sug)

    # Now opt Gigi out via BOTH {} consent.json AND acknowledged_at: null!
    (store.person_dir(gigi) / "consent.json").write_text("{}")
    assert client.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH).status_code == 200
    svc.pipeline.relabel(5200.0)
    svc.warm(now=5200.0)
    assert store.person_policy(gigi, store.settings()) == OPTED_OUT

    post_hints = svc.pipeline.possible_voice_names(target, tsha)
    post_rev = client.get("/v1/speakers/review", headers=AUTH).json()["items"]
    post_sug = client.get("/v1/speakers/suggestions", headers=AUTH).json()["suggestions"]
    post_people = {p["id"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}

    print("C1_01_POST_OPTOUT:", {
        "note_hints": post_hints,
        "review_possible_gigi": [it for it in post_rev if it.get("person_id") == gigi],
        "suggestions_gigi": [s for s in post_sug if s.get("person_id") == gigi],
        "people_gigi_auto_active": post_people[gigi]["auto_active"],
        "people_gigi_status_line": post_people[gigi]["status_line"],
    })
    assert post_hints == {}  # note-render path properly suppressed
    # fixed (I1): no served output names the opted-out person
    assert not any(it["person_id"] == gigi and it["reasons"] == ["possible"] for it in post_rev)
    assert not any(s["kind"] == "is_this_person" and s["person_id"] == gigi for s in post_sug)
    assert post_people[gigi]["auto_active"] is False
    client.app.state.db.close()



def test_c1_02_a_user_labeled_vector_is_pruned_by_the_worker_after_an_opt_out(tmp_path: Path) -> None:
    """C1-02 (Question 1): When a person opts out via `PUT /v1/people/{id}` (`me: False` without `attest_knows`)
    or `{}` `consent.json`, `_put_person_write` and `_relabel` do NOT prune `voices-*.json` vectors on conversations
    where that person was user-confirmed (`source='user'`), because `persisted(states) == persisted(current)` hits
    `continue` at `pipeline/conversations.py:977-978`."""
    # Case A: PUT /v1/people/{alan} {"name": "Gigi", "me": False}
    c1, svc1, st1, alan, _, _, vp1 = _setup_person(tmp_path / "put_demote", me=True, unknown_voices=False, source="user")
    assert c1.put(f"/v1/people/{alan}", json={"name": "Gigi", "me": False}, headers=AUTH).status_code == 200
    assert st1.person_policy(alan, st1.settings()) == OPTED_OUT
    svc1.pipeline.relabel(3000.0)  # what every 2s worker tick runs
    assert "vector_b64" not in json.loads(vp1.read_text())["labels"]["S1"], "the worker's relabel pass prunes (I4)"
    c1.app.state.db.close()

    # Case B: consent.json -> {} on disk + warm() + pipeline.relabel()
    c2, svc2, st2, gigi, _, _, vp2 = _setup_person(tmp_path / "consent_empty_user", me=False, unknown_voices=False, source="user")
    (st2.person_dir(gigi) / "consent.json").write_text("{}")
    svc2.warm(now=3000.0)
    svc2.pipeline.relabel(3000.0)
    assert "vector_b64" not in json.loads(vp2.read_text())["labels"]["S1"], "the worker's relabel pass prunes (I4)"
    c2.app.state.db.close()



def test_c1_03_a_cached_attestation_never_mints_a_sample_after_an_opt_out(tmp_path: Path) -> None:
    """C1-03 / Question 3 (D1-04): When `consent.json` becomes `{}` on disk (before 5-min `scan_people()` runs),
    `PUT /v1/conversations/{id}/speakers/S1` reads stale `store.attested(gigi)` from SQLite, mints a new sample file,
    and keeps `S1`'s vector in `voices-*.json` even though `person_policy(gigi) == OPTED_OUT`."""
    c, svc, st, gigi, gvec, _, _ = _setup_person(tmp_path / "d104", unknown_voices=True)
    target = str(uuid.uuid4())
    vp = _add_conv(st, target, gvec, person_id=None, start=4000.0, sha_char="f")
    st.update_settings(unknown_voices_enabled=False)
    st.reconcile_vectors()
    # Now Gigi's consent.json becomes {} on disk (before 5-min warm_people scan runs)
    (st.person_dir(gigi) / "consent.json").write_text("{}")
    assert st.person_policy(gigi, st.settings()) == OPTED_OUT

    # Need raw audio or stored vector: let's test when S1 had stored vector (e.g. before reconcile or via raw audio)
    c2, svc2, st2, gigi2, gvec2, _, _ = _setup_person(tmp_path / "d104_b", unknown_voices=True)
    target2 = str(uuid.uuid4())
    vp2 = _add_conv(st2, target2, gvec2, person_id=None, start=4000.0, sha_char="f")
    (st2.person_dir(gigi2) / "consent.json").write_text("{}")
    assert st2.person_policy(gigi2, st2.settings()) == OPTED_OUT
    res = c2.put(
        f"/v1/conversations/{target2}/speakers/S1",
        json={"person_id": gigi2, "expected_revision": 0, "request_id": "req-d104"},
        headers=AUTH,
    )
    assert res.status_code == 200
    assert res.json()["sample"] != "created", "no new voiceprint for an opted-out person (I2)"
    c.app.state.db.close()
    c2.app.state.db.close()

