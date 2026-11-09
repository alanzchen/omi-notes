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
