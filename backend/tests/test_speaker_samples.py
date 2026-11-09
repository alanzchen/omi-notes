"""Sample states, review, calibration and enrollment import (docs/speaker-learning.md, "Voices hub")."""

from __future__ import annotations

import json
import shutil
from types import SimpleNamespace

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.pipeline.worker import Worker
from omi_notes.speakers import match as sm
from omi_notes.speakers.service import SpeakerService
from omi_notes.speakers.store import sample_eligible
from omi_notes.vault import Vault

from .conftest import AUTH
from .helpers import T0
from .test_speaker_learning import (  # noqa: F401
    ALAN, PRIYA, RAVI, FakeEmbedder, dialogue, env, label, name_label, new_person, sample, talk, vec,
)

MODEL = ("fake-voice", "0" * 64)


def me_with_samples(client, worker, days=(6, 5, 4)) -> tuple[str, list[dict], list[str]]:
    """Alan named in three conversations on three days (active); the sample ids, oldest first."""
    me = new_person(client, "Alan", me=True)
    rows = []
    for day in days:
        row = talk(client, worker, dialogue(ALAN, PRIYA, seed=day), day=day)
        assert name_label(client, row["id"], "S1", me).json()["sample"] == "created"
        rows.append(row)
    ids = [r["id"] for r in worker.db.query("SELECT id FROM samples WHERE person_id=? ORDER BY created_at, id", (me,))]
    return me, rows, ids


def sample_file(settings, person_id: str, sample_id: str) -> dict:
    return json.loads((Vault.open(settings).person_dir(person_id) / "samples" / f"{sample_id}.json").read_text())


def people(client) -> dict[str, dict]:
    return {p["name"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}


# -- M1: states and eligibility -------------------------------------------------------------------------


def test_only_active_samples_are_eligible():
    assert sample_eligible({}) and sample_eligible({"state": "active"})
    assert not sample_eligible({"state": "removed"}) and not sample_eligible({"state": "moved"})


def test_a_removed_sample_stops_feeding_the_model_and_a_restore_brings_it_back(env):
    settings, client, worker = env
    me, _, ids = me_with_samples(client, worker)
    store = worker.pipeline.speakers
    assert Vault.open(settings).format < 6
    assert people(client)["Alan"]["auto_active"] is True
    with store.lock:
        store.set_sample_state(me, ids[0], "removed", action="remove", by="user", request_id="r-remove", now=T0 + 10)
    assert Vault.open(settings).format == 6  # an older backend would use the removed voiceprint again
    data = sample_file(settings, me, ids[0])
    assert data["state"] == "removed" and data["revision"] == 1
    assert data["history"] == [{"at": T0 + 10, "action": "remove", "by": "user", "request_id": "r-remove",
                                "from": "active", "to": "removed"}]  # fmt: skip
    assert ids[0] not in {s.id for s in store.samples(*MODEL)}
    alan = people(client)["Alan"]
    assert (alan["samples"], alan["auto_active"]) == (2, False)  # only 2 confirmed recordings left
    with store.lock:
        store.set_sample_state(me, ids[0], "active", action="restore", by="user", request_id="r-restore", now=T0 + 20)
    assert ids[0] in {s.id for s in store.samples(*MODEL)}
    assert people(client)["Alan"]["auto_active"] is True
    assert [h["action"] for h in sample_file(settings, me, ids[0])["history"]] == ["remove", "restore"]


def test_the_vault_format_is_raised_before_the_first_state_is_written(env, monkeypatch):
    settings, client, worker = env
    me, _, ids = me_with_samples(client, worker, days=(6,))
    store = worker.pipeline.speakers
    real = Vault.write_json

    def failing(path, value, **kw):
        if path.parent.name == "samples":
            raise OSError("disk full")
        return real(path, value, **kw)

    monkeypatch.setattr(Vault, "write_json", staticmethod(failing))
    with pytest.raises(OSError), store.lock:
        store.set_sample_state(me, ids[0], "removed", action="remove", by="user", request_id="r", now=T0)
    assert json.loads((settings.vault_dir / "_omi" / "VAULT.json").read_text())["format"] == 6
    assert "state" not in sample_file(settings, me, ids[0])


def test_sample_states_survive_an_index_rebuild(env):
    settings, client, worker = env
    me, _, ids = me_with_samples(client, worker)
    store = worker.pipeline.speakers
    with store.lock:
        store.set_sample_state(me, ids[1], "removed", action="remove", by="user", request_id="r", now=T0)
    shutil.rmtree(settings.index_dir)
    app = create_app(settings, start_worker=False)
    fresh = Worker(settings, app.state.db)
    fresh.providers._embedder = FakeEmbedder()
    app.state.speakers = SpeakerService(fresh.pipeline)
    assert {s.id for s in fresh.pipeline.speakers.samples(*MODEL)} == {ids[0], ids[2]}
    row = fresh.db.one("SELECT state, revision FROM samples WHERE id=?", (ids[1],))
    assert (row["state"], row["revision"]) == ("removed", 1)


def test_forget_purges_removed_samples_and_moved_copies_of_the_voice(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    store = worker.pipeline.speakers
    other = new_person(client, "Ravi")
    with store.lock:
        store.set_sample_state(me, ids[0], "removed", action="remove", by="user", request_id="r1", now=T0)
        # a sample of Alan's moved to Ravi earlier: Alan's folder keeps the moved record, Ravi has the copy
        store.set_sample_state(me, ids[1], "moved", action="move", by="user", request_id="r2", now=T0,
                               extra={"moved_to": {"person_id": other, "sample_id": "copy"}})  # fmt: skip
    marker = Vault.open(settings).person_dir(me) / "samples" / f"{ids[1]}.json"
    assert marker.exists()
    r = client.delete(f"/v1/people/{other}", headers=AUTH)
    assert r.status_code == 200
    assert not marker.exists(), "a moved record holds the forgotten person's voice: it goes with them"
    assert worker.db.one("SELECT 1 FROM samples WHERE id=?", (ids[1],)) is None
    client.delete(f"/v1/people/{me}", headers=AUTH)
    assert not Vault.open(settings).person_dir(me).exists()
    assert worker.db.one("SELECT COUNT(*) AS n FROM samples")["n"] == 0


# -- M2: the owner restriction (Revision 4) ------------------------------------------------------------


def owner_models(**kw):
    samples = [sample("alan", ALAN, 0, source="enrollment")] + [sample("alan", ALAN, i, day=f"2026-09-2{i}") for i in (1, 2, 3)]
    return sm.build_models(samples, wearer_id="alan", **kw)


def at_cosine(centroid, cos: float, axis: int = 31):
    """A unit vector at this raw cosine to `centroid`."""
    c = centroid / np.linalg.norm(centroid)
    other = np.zeros_like(c)
    other[axis] = 1.0
    other = other - (other @ c) * c
    other /= np.linalg.norm(other)
    return (cos * c + np.sqrt(1 - cos**2) * other).astype("float32")


def test_an_over_split_second_owner_label_stays_unnamed():
    models = owner_models()
    assert models["alan"].wearer and models["alan"].active
    states = sm.assign({"S1": label(vec(ALAN, 8)), "S2": label(vec(ALAN, 9))}, {}, models, auto_assign=True)
    named = sorted(lab for lab, s in states.items() if s["person_id"] == "alan")
    assert len(named) == 1, "only the top raw-ranked label can be the owner"
    assert all(s["distance"] is not None for s in states.values())
    # not the wearer: the existing over-split rule keeps both
    plain = sm.build_models([sample("alan", ALAN, 0, source="enrollment")]
                            + [sample("alan", ALAN, i, day=f"2026-09-2{i}") for i in (1, 2, 3)])  # fmt: skip
    both = sm.assign({"S1": label(vec(ALAN, 8)), "S2": label(vec(ALAN, 9))}, {}, plain, auto_assign=True)
    assert both["S1"]["person_id"] == both["S2"]["person_id"] == "alan"


def test_a_single_owner_label_needs_raw_cosine_080():
    models = owner_models()
    c = models["alan"].centroid
    below = sm.assign({"S1": label(at_cosine(c, 0.79))}, {}, models, auto_assign=True)["S1"]
    assert below["person_id"] is None and below["distance"] == pytest.approx(0.21, abs=1e-3)
    above = sm.assign({"S1": label(at_cosine(c, 0.81))}, {}, models, auto_assign=True)["S1"]
    assert above["person_id"] == "alan" and above["source"] == "auto"


def test_a_multi_label_owner_label_needs_the_top_raw_rank_and_raw_cosine_088():
    models = owner_models()
    c = models["alan"].centroid
    other = label(vec(RAVI))
    low = sm.assign({"S1": label(at_cosine(c, 0.87)), "S2": other}, {}, models, auto_assign=True)
    assert low["S1"]["person_id"] is None
    high = sm.assign({"S1": label(at_cosine(c, 0.89)), "S2": other}, {}, models, auto_assign=True)
    assert high["S1"]["person_id"] == "alan" and high["S2"]["person_id"] is None
    # a stored label whose vector wasn't kept still makes the conversation multi-label
    stored = SimpleNamespace(vector=None, seconds=8.0, turns=2, mixed=False, clips=[[0, 4], [10, 14]])
    assert sm.assign({"S1": label(at_cosine(c, 0.85)), "S2": stored}, {}, models, auto_assign=True)["S1"]["person_id"] is None
    assert sm.OWNER_RULE.version >= 1
    assert (sm.OWNER_RULE.multi_min_cosine, sm.OWNER_RULE.single_min_cosine) == (0.88, 0.80)


# -- M3: recording-mean (rm) and global-mean (GA) centring ------------------------------------------------

from omi_notes.speakers import space as sp  # noqa: E402
from omi_notes.speakers import suggest as sg  # noqa: E402


def two_people_space(swap: bool = False) -> sp.RmSpace:
    priya = [sample("priya", PRIYA, i, day=f"2026-09-2{i}") for i in (1, 2, 3)]
    ravi = [sample("ravi", RAVI, i, day=f"2026-09-2{i}") for i in (1, 2, 3)]
    stored = [s.vector for s in priya + ravi] + [vec(ALAN, i) for i in range(6)]
    space = sp.build_space(stored, {"priya": [s.vector for s in priya], "ravi": [s.vector for s in ravi]})
    if swap:  # rm would rank the other person first
        space.centroids = {"priya": space.centroids["ravi"], "ravi": space.centroids["priya"]}
    return space


def test_recording_mean_basis_and_residual_guard():
    ga = sp.background_of([vec(ALAN), vec(PRIYA), vec(RAVI)])
    centre, basis = sp.label_centre(vec(PRIYA), [vec(PRIYA), vec(ALAN)], ga, full=True)
    assert basis == "conversation" and np.allclose(centre, sp.background_of([vec(PRIYA), vec(ALAN)]))
    assert sp.label_centre(vec(PRIYA), [vec(PRIYA), vec(ALAN)], ga, full=False)[1] == "partial"
    assert sp.label_centre(vec(PRIYA), [vec(PRIYA)], ga, full=True)[1] == "ga"
    # two nearly identical labels: the label sits on its recording mean, nothing is left to compare
    centre, basis = sp.label_centre(vec(PRIYA, 1), [vec(PRIYA, 1), vec(PRIYA, 2)], ga, full=True)
    assert basis == "ga" and np.allclose(centre, ga)
    assert sp.RESIDUAL_GUARD == 0.20


def test_a_non_owner_is_named_automatically_only_when_rm_agrees():
    models = sm.build_models([sample("priya", PRIYA, i, day=f"2026-09-2{i}") for i in (1, 2, 3)]
                             + [sample("ravi", RAVI, i, day=f"2026-09-2{i}") for i in (1, 2, 3)])  # fmt: skip
    voices = {"S1": label(vec(ALAN, 7)), "S2": label(vec(PRIYA, 7))}
    agreed = sm.assign(voices, {}, models, auto_assign=True, space=two_people_space(), full_rm=True)
    assert agreed["S2"]["person_id"] == "priya" and agreed["S2"]["rm_basis"] == "conversation"
    disagreed = sm.assign(voices, {}, models, auto_assign=True, space=two_people_space(swap=True), full_rm=True)
    assert disagreed["S2"]["person_id"] is None and disagreed["S2"]["rm_basis"] == "conversation"
    assert disagreed["S2"]["distance"] == agreed["S2"]["distance"], "the raw evidence is unchanged"
    alone = sm.assign({"S2": voices["S2"]}, {}, models, auto_assign=True, space=two_people_space(), full_rm=False)
    assert alone["S2"]["rm_basis"] == "ga" and alone["S2"]["person_id"] == "priya"


def test_rm_chooses_who_a_recurring_voice_might_be():
    quiet = [sg.Candidate(f"p{i}", "S1", vec(PRIYA, i), 12.0, f"d{i % 2}", -30.0) for i in range(3)]
    models = sm.build_models([sample("priya", PRIYA, i) for i in range(2)] + [sample("ravi", RAVI, i) for i in range(2)])
    found = sg.suggestions(quiet, models, me_exists=True, dismissed={}, now=0, space=two_people_space())
    assert found[0].kind == "is_this_person" and found[0].person_id == "priya"
    swapped = sg.suggestions(quiet, models, me_exists=True, dismissed={}, now=0, space=two_people_space(swap=True))
    assert swapped[0].person_id != "priya"


def test_ga_and_centroids_use_only_eligible_samples_and_consented_vectors(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    store = worker.pipeline.speakers
    space = store.rm_space(*MODEL)
    stored = worker.db.query("SELECT COUNT(*) AS n FROM voices WHERE vector IS NOT NULL")[0]["n"]
    assert space.count == stored + 3 and set(space.centroids) == {me}
    with store.lock:
        for sid in ids:
            store.set_sample_state(me, sid, "removed", action="remove", by="user", request_id=f"r-{sid}")
    space = store.rm_space(*MODEL)
    assert space.count == stored and space.centroids == {}


def test_auto_names_record_their_rm_basis_and_a_relabel_uses_the_stored_vectors(env):
    settings, client, worker = env
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH)
    me = new_person(client, "Alan", me=True)
    priya = new_person(client, "Priya", attest_knows=True)
    for day in (6, 5, 4):
        row = talk(client, worker, dialogue(ALAN, PRIYA, seed=day), day=day)
        assert name_label(client, row["id"], "S2", priya).json()["sample"] == "created"
        name_label(client, row["id"], "S1", me)
    fresh = talk(client, worker, dialogue(ALAN, PRIYA, seed=40), day=1)
    states = worker.pipeline.speakers.labels(fresh["id"])
    assert states["S2"]["person_id"] == priya and states["S2"]["source"] == "auto"
    assert states["S2"]["rm_basis"] == "conversation"
    record = json.loads((Vault.open(settings).conversation_dir(fresh["id"]) / "speakers.json").read_text())
    assert record["labels"]["S2"]["rm_basis"] == "conversation"
    worker.db.set_meta("relabel_pending", "1")
    worker.pipeline.relabel(T0 + 5000)
    assert worker.pipeline.speakers.labels(fresh["id"])["S2"]["rm_basis"] in ("partial", "ga")


def test_possible_names_are_scored_by_recording_mean_and_only_from_eligible_samples(env, monkeypatch):
    from omi_notes.pipeline import conversations

    settings, client, worker = env
    monkeypatch.setattr(conversations, "BACKGROUND_MIN_VOICES", 1)
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z", "unknown_voices_enabled": True},
               headers=AUTH)  # fmt: skip
    priya = new_person(client, "Priya", attest_knows=True)
    first = talk(client, worker, dialogue(ALAN, PRIYA, seed=3), day=3)
    assert name_label(client, first["id"], "S2", priya).json()["sample"] == "created"
    later = talk(client, worker, dialogue(RAVI, PRIYA, seed=9), day=1)  # Priya isn't active: no name, a hint
    assert worker.pipeline.speakers.labels(later["id"]).get("S2", {}).get("person_id") is None
    assert worker.pipeline.possible_voice_names(later["id"], later["transcript_sha"]) == {"S2": ("Priya", False)}
    (sid,) = [r["id"] for r in worker.db.query("SELECT id FROM samples WHERE person_id=?", (priya,))]
    with worker.pipeline.speakers.lock:
        worker.pipeline.speakers.set_sample_state(priya, sid, "removed", action="remove", by="user", request_id="r")
    assert worker.pipeline.possible_voice_names(later["id"], later["transcript_sha"]) == {}
