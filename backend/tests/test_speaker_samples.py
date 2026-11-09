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
from omi_notes.speakers.store import flag_open, sample_eligible
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
    me = new_person(client, "Alan", me=True)
    store = worker.pipeline.speakers
    with store.lock:  # a voiceprint from before F0 (nothing has raised the format yet)
        ids = [store.add_sample(me, vec(ALAN), model=MODEL[0], model_sha=MODEL[1], source="user", seconds=8.0, day=None, session="s")]
    assert Vault.open(settings).format < 6
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
    assert space.count == stored and set(space.centroids) == {me}  # each named voice is also its sample: once
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


# -- M4: F0 and review flags ---------------------------------------------------------------------------

from omi_notes.audio import pitch  # noqa: E402
from omi_notes.speakers import flags as fl  # noqa: E402

from .helpers import silence  # noqa: E402
from .test_speaker_learning import voice  # noqa: E402


def test_yin_finds_the_pitch_of_a_voiced_clip_and_needs_enough_voiced_frames():
    clip = pitch.clip_f0(voice(3, 150.0))
    assert clip["f0"] == pytest.approx(150.0, abs=4) and clip["voiced"] >= pitch.MIN_VOICED
    assert pitch.clip_f0(voice(0.12, 150.0))["f0"] is None  # too few voiced frames
    assert pitch.clip_f0(silence(2))["f0"] is None
    pcm = np.concatenate([voice(4, 120.0), voice(4, 120.0, 1)])
    whole = pitch.voice_f0(pcm, [[0.0, 4.0], [4.0, 8.0]])
    assert whole["f0"] == pytest.approx(120.0, abs=4) and whole["voiced"] >= pitch.SAMPLE_MIN_VOICED
    assert whole["estimator"] == pitch.ESTIMATOR
    short = pitch.voice_f0(pcm, [[0.0, 0.6]])  # a clip passes, but a sample needs 100 voiced frames
    assert short["f0"] is None and short["voiced"] >= pitch.MIN_VOICED


def test_a_new_sample_carries_its_f0_and_clips_measured_while_the_pcm_was_in_hand(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6,))
    data = sample_file(settings, me, ids[0])
    assert data["f0"] == pytest.approx(ALAN, abs=6) and data["f0_source"] == "voices-stage"
    assert data["f0_estimator"] == pitch.ESTIMATOR and data["f0_voiced"] >= pitch.SAMPLE_MIN_VOICED
    assert data["clips"] and data["voices_file"].startswith("voices-")
    voices = json.loads((Vault.open(settings).conversation_dir(rows[0]["id"]) / data["voices_file"]).read_text())
    assert voices["labels"]["S1"]["f0"] == data["f0"] and "f0" not in voices["labels"]["S2"]  # unknown: not kept
    assert worker.db.one("SELECT f0 FROM samples WHERE id=?", (ids[0],))["f0"] == data["f0"]


def strip_f0(settings, worker, person_id, sample_id, *, clips: bool = False) -> None:
    """Make a sample look like one from before F0 (and, with `clips`, before clip bounds were recorded)."""
    path = Vault.open(settings).person_dir(person_id) / "samples" / f"{sample_id}.json"
    data = json.loads(path.read_text())
    for key in ("f0", "f0_voiced", "f0_source", "f0_estimator", "f0_measurement") + (("clips", "voices_file") if clips else ()):
        data.pop(key, None)
    Vault.write_json(path, data)
    worker.pipeline.speakers.load_samples()


def run_cli(settings, *args):
    from typer.testing import CliRunner

    from omi_notes.cli import app as cli

    from .conftest import cli_env

    result = CliRunner().invoke(cli, ["speakers", *args], env=cli_env(settings))
    assert result.exit_code == 0, result.output
    return result.output


def test_measure_f0_backfills_from_raw_audio_once_and_only_adds_fields(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6, 5))
    strip_f0(settings, worker, me, ids[0])
    strip_f0(settings, worker, me, ids[1], clips=True)  # older still: its bounds come from the voices file it matches
    before = sample_file(settings, me, ids[0])
    out = run_cli(settings, "measure-f0")
    assert "measured 2" in out, out
    for sid in ids:
        data = sample_file(settings, me, sid)
        assert data["f0"] == pytest.approx(ALAN, abs=6) and data["f0_source"] == "raw-backfill"
    after = sample_file(settings, me, ids[0])
    assert {k: v for k, v in after.items() if k in before} == before, "nothing else changes"
    assert "measured 0" in run_cli(settings, "measure-f0"), "idempotent"


def bench_dir(tmp_path, settings, rows, sample_data, *, shift: float = 0.0, end_shift: float | None = None,
              f0s=(111.0, 113.0), voiced=(150, 150), voices_file: str | None = "same") -> str:
    """A bench like ~/Developer/omi-asr-bench/spk: data/{clips,manifest}.json and the production estimator's clip
    values in a0-20261109/q3_clip_f0_numpy.json, for one sample's conversation and label."""
    conv = rows[0]
    bench = tmp_path / "spk"
    (bench / "data").mkdir(parents=True, exist_ok=True)
    (bench / "a0-20261109").mkdir(parents=True, exist_ok=True)
    spans = sample_data["clips"]
    end_shift = shift if end_shift is None else end_shift
    clips = [{"i": i, "cid": conv["id"], "label": sample_data["label"], "j": i, "start": conv["start"], "person": "Alan"}
             for i in range(len(spans))]  # fmt: skip
    entry = {"id": conv["id"], "start": conv["start"],
             "labels": {sample_data["label"]: {"clips": [[a + shift, b + end_shift] for a, b in spans]}}}  # fmt: skip
    if voices_file:
        entry["voices_file"] = sample_data["voices_file"] if voices_file == "same" else voices_file
    (bench / "data" / "clips.json").write_text(json.dumps(clips))
    (bench / "data" / "manifest.json").write_text(json.dumps([entry]))
    values = {str(i): {"f0": f0s[i % len(f0s)], "voiced": voiced[i % len(voiced)], "frames": 400} for i in range(len(spans))}
    (bench / "a0-20261109" / "q3_clip_f0_numpy.json").write_text(json.dumps(values))
    return str(bench)


def test_import_f0_adds_bench_values_only_where_conversation_label_and_clip_bounds_match(env, tmp_path):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6,))
    data = sample_file(settings, me, ids[0])
    strip_f0(settings, worker, me, ids[0])
    off = bench_dir(tmp_path / "off", settings, rows, data, shift=0.2)
    out = run_cli(settings, "import-f0", off)
    assert "imported 0" in out and "skipped (clip bounds differ) 1" in out, out
    assert "f0" not in sample_file(settings, me, ids[0])
    good = bench_dir(tmp_path / "good", settings, rows, data, shift=0.03, f0s=(111.0, 113.0, 115.0))
    out = run_cli(settings, "import-f0", good)
    assert "imported 1" in out, out
    imported = sample_file(settings, me, ids[0])
    assert imported["f0_source"] == "bench-20261108" and imported["f0_clips"] == list(range(len(data["clips"])))
    weights = [b - a for a, b in data["clips"]]
    assert imported["f0"] == pytest.approx(pitch.label_f0([{"f0": (111.0, 113.0, 115.0)[i % 3], "voiced": 150}
                                                          for i in range(len(weights))], weights), abs=0.01)  # fmt: skip
    assert pitch.ESTIMATOR in imported["f0_estimator"] and "q3_clip_f0_numpy.json" in imported["f0_estimator"]
    assert imported["f0_voiced"] == 150 * len(weights) and "duration-weighted" in imported["f0_aggregation"]
    out = run_cli(settings, "import-f0", good)
    assert "imported 0" in out and "skipped (already measured) 1" in out, "never overwrites"
    assert sample_file(settings, me, ids[0]) == imported


def flag_input(i: int, f0: float | None, f0_voice: float = ALAN, pid: str = "alan") -> fl.FlagInput:
    return fl.FlagInput(f"{pid}-{i}", pid, vec(f0_voice, i), f0)


def test_flags_mark_pitch_outside_the_persons_band_and_scores_far_below_the_rest():
    people = [flag_input(i, 118.0 + i) for i in range(8)]
    odd_pitch = flag_input(8, 190.0)
    odd_voice = flag_input(9, 121.0, f0_voice=RAVI)
    found = fl.evaluate(people + [odd_pitch, odd_voice])
    assert found["alan-8"] == ["pitch"]
    assert "score" in found["alan-9"]
    assert all(found.get(s.id, []) == [] for s in people)
    # no fixed 165 Hz split: a high-pitched person is judged by their own band
    high = [flag_input(i, 210.0 + i, pid="gigi") for i in range(8)]
    assert all(not v for v in fl.evaluate(high).values())
    assert fl.evaluate(people[:3] + [odd_pitch]) == {s.id: [] for s in people[:3] + [odd_pitch]}  # too few to judge


def add_samples(store, person_id: str, f0s: list[float | None], voice_f0: float = ALAN) -> list[str]:
    ids = []
    for i, f0 in enumerate(f0s):
        ids.append(store.add_sample(person_id, vec(voice_f0, i), model=MODEL[0], model_sha=MODEL[1],
                                    source="user", seconds=8.0, day=f"2026-09-{10 + i}", session=f"s{i}",
                                    extra={"f0": f0, "f0_source": "voices-stage"} if f0 else None))  # fmt: skip
    return ids


def test_a_confirmed_flag_never_returns_on_unchanged_evidence_and_flags_never_exclude(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    store = worker.pipeline.speakers
    with store.lock:
        ids = add_samples(store, me, [118.0 + i for i in range(8)] + [190.0])
        assert store.apply_flags(T0) == 1
    flag = sample_file(settings, me, ids[-1])["flag"]
    assert flag["reasons"] == ["pitch"] and flag["evidence_fingerprint"]
    assert Vault.open(settings).format == 6
    assert ids[-1] in {s.id for s in store.samples(*MODEL)}, "a flag orders the review queue, it never excludes"
    with store.lock:
        store.resolve_flag(me, ids[-1], "confirm", request_id="r-confirm", now=T0 + 1)
        assert store.apply_flags(T0 + 2) == 0
    assert sample_file(settings, me, ids[-1])["flag"]["resolved"]["decision"] == "confirm"
    # new evidence (another F0 measurement) is a new question
    path = Vault.open(settings).person_dir(me) / "samples" / f"{ids[-1]}.json"
    data = json.loads(path.read_text()) | {"f0": 230.0}
    Vault.write_json(path, data)
    store.load_samples()
    with store.lock:
        assert store.apply_flags(T0 + 3) == 1
    assert flag_open(sample_file(settings, me, ids[-1]).get("flag"))


# -- M5: the review queue and sample APIs ------------------------------------------------------------------


def review(client, limit: int = 10) -> list[dict]:
    r = client.get(f"/v1/speakers/review?limit={limit}", headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()["items"]


def decide(client, item_id: str, decision: str, request_id: str, **extra):
    return client.post(f"/v1/speakers/review/{item_id}", json={"decision": decision, "request_id": request_id} | extra,
                       headers=AUTH)  # fmt: skip


def flag_one(worker, person_id: str, sample_id: str, reasons=("pitch",)) -> None:
    store = worker.pipeline.speakers
    with store.lock:
        store.update_sample(person_id, sample_id, {"flag": {"reasons": list(reasons), "evidence_fingerprint": "fp1"}},
                            action="flag", by="calibration", request_id=None, recalibrate=False)  # fmt: skip


def test_the_review_queue_puts_flagged_samples_first_with_playable_clips_and_captions(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    flag_one(worker, me, ids[1])
    items = review(client)
    first = items[0]
    assert (first["kind"], first["person_id"], first["sample_id"], first["reasons"]) == ("sample", me, ids[1], ["pitch"])
    assert first["id"] == f"s.{ids[1]}.1", "bound to the sample's revision"
    assert first["playable"] is True and first["clip"]["id"] == f"sample.{ids[1]}.0" and first["text"]
    assert first["conversation"] == {"id": rows[1]["id"], "started_at": first["conversation"]["started_at"],
                                     "title": rows[1]["title"]} and first["device"]  # fmt: skip
    wav = client.get(f"/v1/clips/{first['clip']['id']}", headers=AUTH)
    assert wav.status_code == 200 and wav.headers["content-type"] == "audio/wav"
    assert {i["sample_id"] for i in items if i["kind"] == "sample"} == set(ids), "then the rest"
    assert len(review(client, limit=2)) == 2
    alan = people(client)["Alan"]
    assert (alan["samples"], alan["samples_active"], alan["samples_flagged"], alan["samples_removed"]) == (3, 3, 1, 0)
    assert alan["review_count"] == 1 and alan["status_line"] == "已启用"
    assert "voice_review" in client.get("/v1/status", headers=AUTH).json()["features"]


def test_a_review_confirm_resolves_the_flag_once_stale_ids_are_refused_and_retries_answer_the_same(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    flag_one(worker, me, ids[0])
    item = review(client)[0]
    r = decide(client, item["id"], "confirm", "rq-1")
    assert r.status_code == 200, r.text
    assert sample_file(settings, me, ids[0])["flag"]["resolved"]["fingerprint"] == "fp1"
    again = decide(client, item["id"], "confirm", "rq-1")
    assert again.status_code == 200 and again.json() == r.json(), "a retry is answered, not redone"
    stale = decide(client, item["id"], "reject", "rq-2")
    assert stale.status_code == 409 and stale.json()["error"] == "stale_review"
    assert review(client)[0]["reasons"] == [] and people(client)["Alan"]["review_count"] == 0


def test_a_review_reject_soft_removes_and_undo_puts_it_back(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    item = next(i for i in review(client) if i.get("sample_id") == ids[2])
    r = decide(client, item["id"], "reject", "rq-rej")
    assert r.status_code == 200, r.text
    assert sample_file(settings, me, ids[2])["state"] == "removed"
    alan = people(client)["Alan"]
    assert (alan["samples_active"], alan["samples_removed"], alan["auto_active"]) == (2, 1, False)
    assert [s["id"] for s in client.get(f"/v1/people/{me}/samples?state=removed", headers=AUTH).json()["samples"]] == [ids[2]]
    # its label still listed it: the label is "not Alan" now too, and the undo restores both (decision a)
    state = worker.pipeline.speakers.labels(rows[2]["id"])["S1"]
    assert (state["person_id"], state["not"], state["samples"]) == (None, [me], [])
    undo = client.post("/v1/speakers/undo", json={"request_id": "rq-rej", "undo_request_id": "u-1"}, headers=AUTH).json()
    assert undo["undone"] == [rows[2]["id"]], undo
    assert sample_file(settings, me, ids[2])["state"] == "active"
    state = worker.pipeline.speakers.labels(rows[2]["id"])["S1"]
    assert (state["person_id"], state["samples"]) == (me, [ids[2]])
    repeat = client.post("/v1/speakers/undo", json={"request_id": "rq-rej", "undo_request_id": "u-1"}, headers=AUTH).json()
    assert repeat == undo
    assert people(client)["Alan"]["auto_active"] is True


def test_sample_endpoints_remove_restore_and_list_by_state(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    r = client.post(f"/v1/samples/{ids[0]}/remove", json={"request_id": "x-1"}, headers=AUTH)
    assert r.status_code == 200 and r.json()["sample"]["state"] == "removed"
    assert client.post(f"/v1/samples/{ids[0]}/remove", json={"request_id": "x-1"}, headers=AUTH).json() == r.json()
    listed = client.get(f"/v1/people/{me}/samples?state=active", headers=AUTH).json()["samples"]
    assert {s["id"] for s in listed} == {ids[1], ids[2]}
    shape = listed[0]
    assert {"id", "state", "revision", "source", "seconds", "f0", "flag", "playable", "text", "conversation", "review_id"} <= set(shape)
    assert people(client)["Alan"]["status_line"] == "需要更多样本"
    back = client.post(f"/v1/samples/{ids[0]}/restore", json={"request_id": "x-2"}, headers=AUTH)
    assert back.status_code == 200 and back.json()["sample"]["state"] == "active"
    bad = client.post(f"/v1/samples/{ids[0]}/restore", json={"request_id": "x-3"}, headers=AUTH)
    assert bad.status_code == 409
    assert client.post("/v1/samples/00000000-0000-4000-8000-000000000000/remove", json={"request_id": "x"}, headers=AUTH).status_code == 404


def test_moving_a_sample_corrects_its_label_and_undo_restores_both(env):
    settings, client, worker = env
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH)
    me, rows, ids = me_with_samples(client, worker)
    stranger = new_person(client, "Stranger")
    refused = client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": stranger, "request_id": "m-0"}, headers=AUTH)
    assert refused.status_code == 409 and refused.json()["error"] == "consent_required"
    priya = new_person(client, "Priya", attest_knows=True)
    item = next(i for i in review(client) if i.get("sample_id") == ids[0])
    r = decide(client, item["id"], "move", "m-1", person_id=priya)
    assert r.status_code == 200, r.text
    old = sample_file(settings, me, ids[0])
    new_id = old["moved_to"]["sample_id"]
    assert old["state"] == "moved" and old["moved_to"]["person_id"] == priya
    copy = sample_file(settings, priya, new_id)
    assert copy["moved_from"] == {"person_id": me, "sample_id": ids[0]} and copy["vector_b64"] == old["vector_b64"]
    labels = worker.pipeline.speakers.labels(rows[0]["id"])
    assert labels["S1"]["person_id"] == priya and labels["S1"]["source"] == "user" and labels["S1"]["samples"] == [new_id]
    assert decide(client, item["id"], "move", "m-1", person_id=priya).json() == r.json()
    undo = client.post("/v1/speakers/undo", json={"request_id": "m-1", "undo_request_id": "u-m"}, headers=AUTH).json()
    assert undo["undone"] == [rows[0]["id"]], undo
    assert sample_file(settings, me, ids[0])["state"] == "active"
    assert not (Vault.open(settings).person_dir(priya) / "samples" / f"{new_id}.json").exists()
    labels = worker.pipeline.speakers.labels(rows[0]["id"])
    assert labels["S1"]["person_id"] == me and labels["S1"]["samples"] == [ids[0]]


def test_a_label_review_item_names_or_rules_out_through_the_naming_path(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    fresh = talk(client, worker, dialogue(ALAN, PRIYA, seed=40), day=1)
    assert worker.pipeline.speakers.labels(fresh["id"])["S1"]["source"] == "auto"
    item = next(i for i in review(client) if i["kind"] == "label")
    assert (item["conversation"]["id"], item["label"], item["person_id"], item["reasons"]) == (fresh["id"], "S1", me, ["auto"])
    r = decide(client, item["id"], "confirm", "lab-1")
    assert r.status_code == 200, r.text
    state = worker.pipeline.speakers.labels(fresh["id"])["S1"]
    assert state["source"] == "user" and state["person_id"] == me and len(state["samples"]) == 1
    assert decide(client, item["id"], "confirm", "lab-1").status_code == 200
    assert decide(client, item["id"], "reject", "lab-2").json()["error"] == "stale_review"


def test_a_review_item_without_raw_audio_keeps_its_caption_and_is_not_playable(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6,))
    worker.db.execute("UPDATE chunks SET raw_deleted=1")  # an older vault's audio, deleted before raw was kept for good
    (item,) = [i for i in review(client) if i.get("sample_id") == ids[0]]
    assert item["playable"] is False and "clip" not in item and item["text"]
    assert client.get(f"/v1/clips/sample.{ids[0]}.0", headers=AUTH).status_code == 410


# -- M6: calibration (informational) ---------------------------------------------------------------------

from omi_notes.speakers import calibration as cal  # noqa: E402


def test_clopper_pearson_one_sided_upper_bounds():
    assert cal.cp_upper(0, 0) is None
    assert cal.cp_upper(0, 29) == pytest.approx(1 - 0.05 ** (1 / 29), abs=1e-4) and cal.cp_upper(0, 29) < 0.10
    assert cal.cp_upper(0, 59) < 0.05 < cal.cp_upper(0, 58)
    assert cal.cp_upper(1, 10) == pytest.approx(0.3942, abs=1e-3)
    assert cal.cp_upper(5, 5) == 1.0


def two_people(client, worker, days=(6, 5, 4, 3)) -> tuple[str, str, list[dict]]:
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH)
    me = new_person(client, "Alan", me=True)
    priya = new_person(client, "Priya", attest_knows=True)
    rows = []
    for day in days:
        row = talk(client, worker, dialogue(ALAN, PRIYA, seed=day), day=day)
        name_label(client, row["id"], "S1", me)
        name_label(client, row["id"], "S2", priya)
        rows.append(row)
    return me, priya, rows


def calibration_file(settings) -> dict | None:
    return Vault.read_json(settings.vault_dir / "_omi" / "speakers" / "calibration.json")


def test_calibration_measures_held_out_conversations_and_never_changes_activation(env):
    settings, client, worker = env
    me, priya, rows = two_people(client, worker)
    before = {p["name"]: p["auto_active"] for p in client.get("/v1/people", headers=AUTH).json()["people"]}
    assert worker.calibrator.run(T0 + 10_000, force=True)
    data = calibration_file(settings)
    assert data["version"] == cal.VERSION and data["fingerprint"] and data["computed_at"]
    alan = data["people"][me]
    held = alan["held_out"]
    assert held["positives"]["conversations"] == 4 and held["named_other"]["conversations"] == 0
    assert held["target_absent"] == {"conversations": 0, "errors": 0, "upper": None}
    assert held["positives"]["upper"] == cal.cp_upper(held["positives"]["errors"], 4)
    assert data["people"][priya]["held_out"]["positives"]["conversations"] == 4
    assert alan["consistency"]["samples"] == 4 and "median" in alan["consistency"]
    assert {p["name"]: p["auto_active"] for p in client.get("/v1/people", headers=AUTH).json()["people"]} == before
    people = {p["name"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}
    assert people["Alan"]["calibrated_at"] == data["computed_at"]
    assert people["Alan"]["measured"]["conversations"] == 4 and "wrong_at_most" in people["Alan"]["measured"]
    api = client.get("/v1/speakers/calibration", headers=AUTH).json()
    assert api["calibration"]["fingerprint"] == data["fingerprint"] and api["stale"] is False
    log = Vault.read_jsonl(settings.vault_dir / "_omi" / "speakers" / "calibration-log.jsonl")
    assert log[-1]["fingerprint"] == data["fingerprint"] and log[-1]["computed_at"] == data["computed_at"]
    assert "voice_calibration" in client.get("/v1/status", headers=AUTH).json()["features"]


def test_calibration_is_unmeasured_without_held_out_counts(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    with worker.pipeline.speakers.lock:
        add_samples(worker.pipeline.speakers, me, [None, None, None])  # voiceprints from no conversation
    assert worker.calibrator.run(T0, force=True)
    alan = people(client)["Alan"]
    assert alan["measured"] is None and alan["calibrated_at"] is not None
    assert calibration_file(settings)["people"][me]["held_out"]["positives"] == {"conversations": 0, "errors": 0, "upper": None}


def test_calibration_runs_debounced_after_a_change_and_nightly(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6, 5))
    calibrator = worker.calibrator
    assert calibrator.run(T0 + 5000, force=True)
    first = calibration_file(settings)["computed_at"]
    changed = T0 + 6000
    with worker.pipeline.speakers.lock:
        worker.pipeline.speakers.set_sample_state(me, ids[0], "removed", action="remove", by="user", request_id="r", now=changed)
    assert not calibrator.run(changed + 10), "debounced"
    assert calibrator.run(changed + cal.DEBOUNCE_SECONDS)
    assert calibration_file(settings)["computed_at"] > first
    assert not calibrator.run(changed + cal.DEBOUNCE_SECONDS + 1), "nothing pending"
    # nightly at 03:10 local, once a day
    from datetime import datetime

    night = datetime(2026, 9, 28, 3, 15, tzinfo=worker.pipeline.tz).timestamp()
    assert calibrator.run(night) and not calibrator.run(night + 60)
    assert not calibrator.run(datetime(2026, 9, 29, 2, 0, tzinfo=worker.pipeline.tz).timestamp())
    assert calibrator.run(datetime(2026, 9, 29, 3, 11, tzinfo=worker.pipeline.tz).timestamp())


def test_calibration_publishes_only_if_its_inputs_did_not_change_meanwhile(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6, 5))
    real = cal.evaluate

    def racing(*args, **kwargs):
        with worker.pipeline.speakers.lock:  # a remove from the app while the calibration computes
            worker.pipeline.speakers.set_sample_state(me, ids[0], "removed", action="remove", by="user", request_id="r")
        return real(*args, **kwargs)

    monkeypatch.setattr(cal, "evaluate", racing)
    before = calibration_file(settings)  # (the worker's ticks may have calibrated already)
    assert not worker.calibrator.run(T0, force=True)
    assert calibration_file(settings) == before, "computed from inputs that changed meanwhile: never published"
    monkeypatch.setattr(cal, "evaluate", real)
    assert worker.calibrator.run(T0 + 100, force=True)
    assert calibration_file(settings)["fingerprint"] == worker.calibrator.fingerprint()


def test_consent_and_forget_ask_for_a_recalibration(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6,))
    for change in (
        lambda: client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH),
        lambda: new_person(client, "Priya", attest_knows=True),
        lambda: client.delete(f"/v1/people/{me}", headers=AUTH),
    ):
        worker.db.set_meta("calibrate_pending", None)
        change()
        assert worker.db.meta("calibrate_pending") is not None


def test_startup_reconciles_a_stale_or_missing_calibration_first(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6,))
    (settings.vault_dir / "_omi" / "speakers" / "calibration.json").unlink(missing_ok=True)
    worker.db.set_meta("calibrate_pending", None)
    worker.calibrator.reconcile()
    assert worker.db.meta("calibrate_pending") == "0"


def test_startup_reconciles_a_stale_or_missing_calibration(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6, 5))
    assert worker.calibrator.run(T0, force=True)
    worker.db.set_meta("calibrate_pending", None)
    path = settings.vault_dir / "_omi" / "speakers" / "calibration.json"
    Vault.write_json(path, json.loads(path.read_text()) | {"fingerprint": "other"})
    assert client.get("/v1/speakers/calibration", headers=AUTH).json()["stale"] is True
    worker.calibrator.reconcile()
    assert worker.db.meta("calibrate_pending") is not None
    assert worker.calibrator.run(T0 + 1)
    assert client.get("/v1/speakers/calibration", headers=AUTH).json()["stale"] is False


# -- M7: enrollment import ---------------------------------------------------------------------------------

import io  # noqa: E402

import soundfile as sf  # noqa: E402


def monologue(f0: float = ALAN, turns: int = 8, seed: int = 0) -> np.ndarray:
    return dialogue(f0, f0, turns=turns, seconds=4.0, seed=seed)


def import_range(client, person_id: str, conv_id: str, start: float, end: float, name: str = "Alan", **extra):
    body = {"conversation_id": conv_id, "start": start, "end": end, "confirm_person": True, "person_name": name} | extra
    return client.post(f"/v1/people/{person_id}/enrollments/import", json=body, headers=AUTH)


def enrollment_seconds(worker, person_id: str) -> float:
    return sum(s.seconds for s in worker.pipeline.speakers.samples(*MODEL) if s.person_id == person_id and s.source == "enrollment")


def test_importing_a_recording_range_enrolls_once_and_overlaps_never_add_seconds(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    row = talk(client, worker, monologue(), day=3)
    first = import_range(client, me, row["id"], 0.0, 60.0)
    assert first.status_code == 201, first.text
    result = first.json()
    assert result["state"] == "accepted" and result["speech_s"] >= 20 and result["sample_id"]
    data = sample_file(settings, me, result["sample_id"])
    assert data["source"] == "enrollment" and data["conversation_id"] == row["id"] and data["session"] == row["id"]
    assert data["import"]["kind"] == "conversation" and data["import"]["sha256"] == row["audio_sha"]
    assert (Vault.open(settings).person_dir(me) / "enrollment" / f"{result['import_id']}.omiaudio").exists()
    again = import_range(client, me, row["id"], 0.0, 60.0)
    assert again.status_code == 200 and again.json()["import_id"] == result["import_id"]
    inside = import_range(client, me, row["id"], 5.0, 50.0)
    assert inside.status_code == 200 and inside.json()["import_id"] == result["import_id"], "already covered"
    seconds = enrollment_seconds(worker, me)
    wider = import_range(client, me, row["id"], 0.0, 70.0)
    assert wider.status_code == 201 and wider.json()["merged"] == [result["import_id"]]
    assert sample_file(settings, me, result["sample_id"])["state"] == "removed"
    assert enrollment_seconds(worker, me) == pytest.approx(wider.json()["speech_s"]) and enrollment_seconds(worker, me) >= seconds
    assert "enrollment_import" in client.get("/v1/status", headers=AUTH).json()["features"]


def test_an_import_needs_the_persons_name_consent_and_enough_speech(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    priya = new_person(client, "Priya")
    row = talk(client, worker, monologue(), day=3)
    assert import_range(client, me, row["id"], 0, 60, name="Bob").status_code == 422
    assert import_range(client, me, row["id"], 0, 60, confirm_person=False).status_code == 422
    refused = import_range(client, priya, row["id"], 0, 60, name="Priya")
    assert refused.status_code == 409 and refused.json()["error"] == "consent_required"
    short = import_range(client, me, row["id"], 0, 8)
    assert short.status_code == 422 and short.json()["error"] == "not_enough_speech"
    assert enrollment_seconds(worker, me) == 0


def wav_bytes(pcm: np.ndarray, rate: int = 16000) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, pcm, rate, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def test_an_uploaded_wav_enrolls_and_forget_deletes_its_audio(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    files = {"file": ("reading.wav", wav_bytes(monologue()), "audio/wav")}
    r = client.post(f"/v1/people/{me}/enrollments/import", data={"confirm_person": "true", "person_name": "Alan"},
                    files=files, headers=AUTH)  # fmt: skip
    assert r.status_code == 201, r.text
    data = sample_file(settings, me, r.json()["sample_id"])
    assert data["import"]["kind"] == "upload" and data["import"]["filename"] == "reading.wav" and data["conversation_id"] is None
    again = client.post(f"/v1/people/{me}/enrollments/import", data={"confirm_person": "true", "person_name": "Alan"},
                        files=files, headers=AUTH)  # fmt: skip
    assert again.status_code == 200 and again.json()["import_id"] == r.json()["import_id"]
    too_long = {"file": ("long.wav", wav_bytes(np.zeros(16000 * 60 * 21, np.int16)), "audio/wav")}
    long = client.post(f"/v1/people/{me}/enrollments/import", data={"confirm_person": "true", "person_name": "Alan"},
                       files=too_long, headers=AUTH)  # fmt: skip
    assert long.status_code in (413, 422)
    client.delete(f"/v1/people/{me}", headers=AUTH)
    assert not Vault.open(settings).person_dir(me).exists()


def test_sixty_seconds_of_enrollment_make_the_centroid_enrollment_only_and_the_gate_still_applies():
    enrolled = [sm.Sample(f"e{i}", "alan", vec(ALAN, i), "enrollment", "2026-09-20", f"imp{i}", float(i), seconds=35.0) for i in (0, 1)]
    stray = [sm.Sample(f"u{i}", "alan", vec(RAVI, i), "user", "2026-09-21", f"c{i}", 10.0 + i, seconds=8.0) for i in (1, 2, 3)]
    models = sm.build_models(enrolled + stray)
    model = models["alan"]
    assert model.enrollment_only
    assert np.allclose(model.centroid, sm.centroid([s.vector for s in enrolled]), atol=1e-6)
    assert not model.active and "days" in model.why_inactive, "the existing gate still applies"
    short = sm.build_models([enrolled[0]] + stray)["alan"]
    assert not short.enrollment_only
    found = fl.evaluate([fl.FlagInput(s.id, s.person_id, s.vector) for s in enrolled + stray], {"alan": model.centroid})
    assert all("enrollment" in found[s.id] for s in stray) and not found["e0"]

