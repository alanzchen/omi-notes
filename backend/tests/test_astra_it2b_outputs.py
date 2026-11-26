"""Read-only review probes: isolated fixtures only; no product changes."""

import json
import uuid

import numpy as np
import pytest
from fastapi.testclient import TestClient

from .test_carbon_it1_20261126 import AUTH, _FakeEmb, _add_conv, _settings, _setup_person
from omi_notes.api import create_app
from omi_notes.pipeline.conversations import BACKGROUND_MIN_VOICES
from omi_notes.speakers.calibration import Calibrator, gather
from omi_notes.speakers.store import FROZEN, OPTED_OUT


@pytest.mark.parametrize("change", [{"auto_assign": False}, {"acknowledged_at": None}])
def test_immediate_conversation_speakers_obeys_settings(tmp_path, change):
    client, svc, store, pid, _, cid, _ = _setup_person(tmp_path, unknown_voices=True)
    before = client.get(f"/v1/conversations/{cid}/speakers", headers=AUTH).json()
    assert before["labels"][0]["person_id"] == pid
    assert client.put("/v1/speakers/settings", json=change, headers=AUTH).status_code == 200
    assert store.db.meta("relabel_pending") == "1"
    served = client.get(f"/v1/conversations/{cid}/speakers", headers=AUTH).json()
    print("IMMEDIATE_SPEAKER_SETTINGS", change, served["labels"])
    assert served["labels"][0]["person_id"] is None


@pytest.mark.parametrize("consent, expected_policy", [("{}", OPTED_OUT), ("{", FROZEN)])
def test_calibration_uses_naming_population(tmp_path, consent, expected_policy):
    client, svc, store, pid, _, _, _ = _setup_person(tmp_path, unknown_voices=True, source="user")
    cal = Calibrator(svc.pipeline)
    assert cal.run(force=True)
    assert pid in cal.current()["people"]
    (store.person_dir(pid) / "consent.json").write_text(consent)
    assert store.person_policy(pid, store.settings()) == expected_policy
    assert pid not in store.models("wespeaker", "deadbeef12345678", svc.pipeline.operating)
    inputs = gather(svc.pipeline)
    print("CALIBRATION_INPUT_PEOPLE", expected_policy, sorted({s.person_id for s in inputs["samples"]}))
    assert cal.run(force=True)
    served = client.get("/v1/speakers/calibration", headers=AUTH).json()
    print("CALIBRATION_POST_POLICY", expected_policy, served)
    assert pid not in served["calibration"]["people"]


def test_frozen_consent_invalidates_people_snapshot(tmp_path):
    client, svc, store, pid, _, _, _ = _setup_person(tmp_path, unknown_voices=True)
    svc.warm(now=2000)
    svc.pipeline.relabel(2000)
    svc.warm(now=2001)
    before = {p["id"]: p for p in svc.people()}[pid]
    assert before["auto_active"] is True
    inputs = svc._people_inputs()
    generation = svc.people_answer()["generation"]
    (store.person_dir(pid) / "consent.json").write_text("{")
    svc.pipeline.relabel(2002)
    svc.warm(now=2002)
    assert store.person_policy(pid, store.settings()) == FROZEN
    assert pid not in store.models("wespeaker", "deadbeef12345678", svc.pipeline.operating)
    after = {p["id"]: p for p in svc.people()}[pid]
    print("PEOPLE_FROZEN_CACHE", {"inputs_equal": inputs == svc._people_inputs(), "generation_before": generation,
                                    "generation_after": svc.people_answer()["generation"], "person": after})
    assert after["auto_active"] is False


def test_one_unreadable_voice_file_does_not_starve_other_optout_prunes(tmp_path):
    client, svc, store, _, vec, _, _ = _setup_person(tmp_path, unknown_voices=True)
    bad = "00000000-0000-0000-0000-000000000001"
    good = "ffffffff-ffff-ffff-ffff-ffffffffffff"
    bad_path = _add_conv(store, bad, vec, start=4000, sha_char="b")
    good_path = _add_conv(store, good, vec, start=5000, sha_char="c")
    assert client.put("/v1/speakers/settings", json={"unknown_voices_enabled": False, "auto_assign": False}, headers=AUTH).status_code == 200
    bad_path.write_text("{")
    errors = []
    for now in (6000, 6002):
        try:
            svc.pipeline.relabel(now)
        except ValueError as exc:
            errors.append(type(exc).__name__)
    retained = "vector_b64" in json.loads(good_path.read_text())["labels"]["S1"]
    print("PRUNING_LIVENESS", {"errors": errors, "healthy_vector_retained": retained,
                               "pending": store.db.meta("relabel_pending")})
    assert store.db.meta("relabel_pending") == "1", "failed work must remain pending"
    assert not retained, "an unrelated unreadable file must not indefinitely retain this opted-out vector"


def test_frozen_consent_invalidates_cached_identity_suggestion(tmp_path):
    """Real background population and three unnamed recordings; no mocked proposal or cache."""
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    rng = np.random.default_rng(123)
    gvec = np.zeros(256, dtype=np.float32)
    gvec[1] = 1.0
    svc.pipeline.providers._embedder = _FakeEmb(gvec)
    store.update_settings(acknowledged_at="2026-11-01T00:00:00Z", unknown_voices_enabled=True, auto_assign=False)
    alan, gigi = str(uuid.uuid4()), str(uuid.uuid4())
    assert client.put(f"/v1/people/{alan}", json={"name": "Alan", "me": True}, headers=AUTH).status_code == 201
    assert client.put(f"/v1/people/{gigi}", json={"name": "Gigi", "me": False, "attest_knows": True}, headers=AUTH).status_code == 201
    for i in range(BACKGROUND_MIN_VOICES + 5):
        vec = rng.normal(size=256).astype(np.float32)
        vec[1] = -abs(vec[1])
        vec /= np.linalg.norm(vec)
        store.add_sample(alan, vec, model="wespeaker", model_sha="deadbeef12345678", source="user",
                         seconds=6.0, day=f"2026-10-{(i % 28) + 1:02d}", session=f"bg-{i}")
    for i in range(3):
        vec = gvec + 0.005 * rng.normal(size=256).astype(np.float32)
        vec /= np.linalg.norm(vec)
        store.add_sample(gigi, vec, model="wespeaker", model_sha="deadbeef12345678", source="user",
                         seconds=6.0, day=f"2026-11-{10 + i:02d}", session=f"g-{i}")
    targets = [str(uuid.uuid4()) for _ in range(3)]
    for i, cid in enumerate(targets):
        _add_conv(store, cid, gvec, start=5000 + i * 86400, sha_char=chr(ord("e") + i))
    now = 5000 + 3 * 86400
    svc.warm(now=now)
    svc.pipeline.relabel(now)
    svc.warm(now=now + 1)
    before = client.get("/v1/speakers/suggestions", headers=AUTH).json()
    assert any(item.get("person_id") == gigi and item["kind"] == "is_this_person" for item in before["suggestions"])
    assert svc.pipeline.possible_voice_names(targets[0], store.current_transcript_sha(targets[0])) == {"S1": ("Gigi", False)}
    inputs = svc._people_inputs()
    (store.person_dir(gigi) / "consent.json").write_text("{")
    svc.pipeline.relabel(now + 2)
    svc.warm(now=now + 2)
    assert store.person_policy(gigi, store.settings()) == FROZEN
    assert svc.pipeline.possible_voice_names(targets[0], store.current_transcript_sha(targets[0])) == {}
    served = client.get("/v1/speakers/suggestions", headers=AUTH).json()
    leaked = [item for item in served["suggestions"] if item.get("person_id") == gigi and item["kind"] == "is_this_person"]
    print("FROZEN_CACHED_SUGGESTION", {"inputs_equal": inputs == svc._people_inputs(),
           "before_generation": before["generation"], "after_generation": served["generation"],
           "ready": served["ready"], "leaked": leaked})
    assert not leaked, "a frozen person's stale cache must not continue proposing new identity matches"


def test_unknown_voices_off_hides_unknown_voice_outputs_at_once(tmp_path):
    """Carbon C2B-02 as an expected truth: turning unknown voices off serves no unknown-voice suggestion or "possible"
    review hint, before the worker's next pass."""
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    rng = np.random.default_rng(123)
    gvec = np.zeros(256, dtype=np.float32)
    gvec[1] = 1.0
    svc.pipeline.providers._embedder = _FakeEmb(gvec)
    store.update_settings(acknowledged_at="2026-11-01T00:00:00Z", unknown_voices_enabled=True, auto_assign=False)
    alan, gigi = str(uuid.uuid4()), str(uuid.uuid4())
    assert client.put(f"/v1/people/{alan}", json={"name": "Alan", "me": True}, headers=AUTH).status_code == 201
    assert client.put(f"/v1/people/{gigi}", json={"name": "Gigi", "me": False, "attest_knows": True}, headers=AUTH).status_code == 201
    for i in range(BACKGROUND_MIN_VOICES + 5):
        vec = rng.normal(size=256).astype(np.float32)
        vec[1] = -abs(vec[1])
        vec /= np.linalg.norm(vec)
        store.add_sample(alan, vec, model="wespeaker", model_sha="deadbeef12345678", source="user",
                         seconds=6.0, day=f"2026-10-{(i % 28) + 1:02d}", session=f"bg-{i}")
    for i in range(3):
        vec = gvec + 0.005 * rng.normal(size=256).astype(np.float32)
        vec /= np.linalg.norm(vec)
        store.add_sample(gigi, vec, model="wespeaker", model_sha="deadbeef12345678", source="user",
                         seconds=6.0, day=f"2026-11-{10 + i:02d}", session=f"g-{i}")
    for i in range(3):
        _add_conv(store, str(uuid.uuid4()), gvec, start=5000 + i * 86400, sha_char=chr(ord("e") + i))
    now = 5000 + 3 * 86400
    svc.warm(now=now)
    svc.pipeline.relabel(now)
    svc.warm(now=now + 1)
    assert client.get("/v1/speakers/suggestions", headers=AUTH).json()["suggestions"], "non-vacuous control"
    assert any(i["reasons"] == ["possible"] for i in client.get("/v1/speakers/review", headers=AUTH).json()["items"])
    assert client.put("/v1/speakers/settings", json={"unknown_voices_enabled": False}, headers=AUTH).status_code == 200
    assert client.get("/v1/speakers/suggestions", headers=AUTH).json()["suggestions"] == []
    assert not any(i["reasons"] == ["possible"] for i in client.get("/v1/speakers/review", headers=AUTH).json()["items"])
