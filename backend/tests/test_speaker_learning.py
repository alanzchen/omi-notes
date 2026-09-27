"""Recognizing the wearer and recurring people (docs/speaker-learning.md) with a fake embedder."""

from __future__ import annotations

import io
import json
import shutil
import time
import uuid
from datetime import timedelta

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.pipeline.worker import Worker
from omi_notes.providers.fake import FakeLlm
from omi_notes.speakers import match as sm
from omi_notes.speakers import suggest as sg
from omi_notes.speakers.service import SpeakerService
from omi_notes.speakers.voices import Clip, LabelVoice, centroid, embed_voices, label_turns, select_clips
from omi_notes.vault import Vault

from .conftest import AUTH, make_settings
from .helpers import STARTED, T0, convs, replay, silence

SR = 16000
ALAN, PRIYA, RAVI = 120.0, 210.0, 300.0  # fundamental frequencies of three synthetic "voices"


def voice(seconds: float, f0: float, seed: int = 0) -> np.ndarray:
    """Syllable-like harmonic bursts at a fixed pitch (the energy VAD calls it speech)."""
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * SR)) / SR
    tone = sum(np.sin(2 * np.pi * k * f0 * t) / k for k in range(1, 5))
    envelope = np.clip(np.sin(2 * np.pi * 3.0 * t + rng.uniform(0, np.pi)), 0, None) ** 0.5
    return np.clip(tone * envelope * 0.25 * 32767 / 2.1 + rng.normal(0, 30, len(t)), -32768, 32767).astype(np.int16)


class FakeEmbedder:
    """Maps a clip's dominant pitch to a direction: same voice ≈ distance 0, different ≈ 1."""

    model = "fake-voice"
    model_sha = "0" * 64
    dim = 32

    def __init__(self) -> None:
        self.calls = 0

    def embed(self, pcm: np.ndarray) -> np.ndarray:
        self.calls += 1
        x = pcm.astype(np.float64)
        spectrum = np.abs(np.fft.rfft(x * np.hanning(len(x))))
        freqs = np.fft.rfftfreq(len(x), 1 / SR)
        band = (freqs > 80) & (freqs < 400)
        f0 = float(freqs[band][np.argmax(spectrum[band])])
        index = np.arange(self.dim)
        v = np.exp(-0.5 * ((index - (f0 - 80) / 10.0) / 1.2) ** 2) + 0.01 * np.cos(index * (1 + len(pcm) % 7))
        return (v / np.linalg.norm(v)).astype(np.float32)


class CountingLlm(FakeLlm):
    def __init__(self) -> None:
        self.calls = 0
        self.prompts: list[str] = []

    def summarize(self, request):
        self.calls += 1
        self.prompts.append(request.user)
        return super().summarize(request)


def dialogue(first: float, second: float, turns: int = 4, seconds: float = 4.0, seed: int = 0) -> np.ndarray:
    """first, second, first, second… with 5 s pauses (one STT block — one fake utterance — per turn)."""
    parts = [silence(1)]
    for i in range(turns):
        parts += [voice(seconds, first if i % 2 == 0 else second, seed + i), silence(5)]
    return np.concatenate(parts)


@pytest.fixture
def env(tmp_path):
    settings = make_settings(tmp_path)
    app = create_app(settings, start_worker=False)
    client = TestClient(app)
    worker = Worker(settings, Database(settings.db_path))
    worker.providers._embedder = FakeEmbedder()
    worker.providers._llm = CountingLlm()
    app.state.speakers = SpeakerService(worker.pipeline)
    return settings, client, worker


def talk(client, worker, pcm, *, day: int = 0, at: float | None = None) -> dict:
    """Replay a conversation `day` days before STARTED and process it."""
    start = STARTED - timedelta(days=day)
    before = {r["id"] for r in convs(worker)}
    replay(client, pcm, start=start)
    worker.tick(at or (T0 + 400 + day))
    (row,) = [r for r in convs(worker) if r["id"] not in before]
    return row


def new_person(client, name: str, **extra) -> str:
    pid = str(uuid.uuid4())
    r = client.put(f"/v1/people/{pid}", json={"name": name} | extra, headers=AUTH)
    assert r.status_code == 201, r.text
    return pid


def name_label(client, conv_id: str, label: str, person_id: str | None, **extra):
    speakers = client.get(f"/v1/conversations/{conv_id}/speakers", headers=AUTH).json()
    body = {"person_id": person_id, "expected_revision": speakers["revision"], "request_id": str(uuid.uuid4())} | extra
    return client.put(f"/v1/conversations/{conv_id}/speakers/{label}", json=body, headers=AUTH)


# -- pure: clips ---------------------------------------------------------------------------------------


def test_clip_selection_rules():
    turns = {
        "S1": [(0.0, 5.0), (20.0, 21.2), (30.0, 34.0)],  # 1.2 s is too short; the third overlaps S2
        "S2": [(5.5, 12.0), (33.5, 40.0)],  # 0.5 s after S1 is clean (±0.25 s guard); the second overlaps
    }
    clips = select_clips(turns, [(0.0, 18.0), (18.5, 40.0)])
    assert [(c.start, c.end) for c in clips["S1"]] == [(0.25, 4.75)]  # trimmed 0.25 s at each end
    assert [(c.start, c.end) for c in clips["S2"]] == [(5.75, 11.75)]
    assert select_clips({"S1": [(0.0, 5.0)], "S2": [(5.2, 12.0)]}, [(0.0, 40.0)]) == {}  # 0.2 s apart: overlapping


def test_clips_prefer_long_turns_split_at_10_s_and_stop_at_30_s():
    turns = {"S1": [(0.0, 3.0), (10.0, 32.0), (40.0, 50.0)], "S2": [(60.0, 62.0)]}
    clips = select_clips(turns, [(0.0, 100.0)])["S1"]
    assert [round(c.seconds, 2) for c in clips] == [10.0, 10.0, 1.5, 8.5]
    assert sum(c.seconds for c in clips) == pytest.approx(30.0)
    assert clips[0].turn == 1 and clips[-1].turn == 2


def test_clips_never_include_spacers_or_losses():
    turns = {"S1": [(0.0, 10.0)]}
    clips = select_clips(turns, [(0.0, 4.0), (4.5, 10.0)])["S1"]  # a spacer at 4.0-4.5
    assert [(c.start, c.end) for c in clips] == [(4.75, 9.75), (0.25, 3.75)]


def test_label_turns_number_speakers_like_the_transcript():
    response = {"results": {"utterances": [
        {"start": 5, "end": 7, "speaker": 3, "transcript": "b"}, {"start": 0, "end": 2, "speaker": 7, "transcript": "a"},
        {"start": 3, "end": 4, "speaker": 9, "transcript": " "},
    ]}}  # fmt: skip
    assert label_turns(response) == {"S1": [(0.0, 2.0)], "S2": [(5.0, 7.0)]}


def test_label_voice_is_a_weighted_centroid_and_mixed_when_clips_disagree():
    pcm = np.concatenate([voice(4, ALAN), voice(4, ALAN, 1), voice(4, PRIYA)])
    clips = {"S1": [Clip(0.0, 4.0, 0), Clip(4.0, 8.0, 1)], "S2": [Clip(0.0, 4.0, 0), Clip(8.0, 12.0, 1)]}
    voices = embed_voices(clips, pcm, FakeEmbedder())
    assert not voices["S1"].mixed and voices["S1"].spread < 0.1
    assert voices["S2"].mixed and voices["S2"].seconds == 8.0 and voices["S2"].turns == 2


# -- pure: matching ------------------------------------------------------------------------------------


def vec(f0: float, jitter: int = 0) -> np.ndarray:
    return FakeEmbedder().embed(voice(3 + jitter * 0.1, f0, jitter))


def sample(pid: str, f0: float, i: int, source: str = "user", day: str = "2026-09-20") -> sm.Sample:
    return sm.Sample(f"{pid}-{i}", pid, vec(f0, i), source, day, f"conv-{pid}-{i}", float(i))


def label(vector, seconds=8.0, turns=2, spread=0.0) -> LabelVoice:
    v = LabelVoice("S1", [Clip(0, seconds / turns, i) for i in range(turns)], vector=vector, spread=spread)
    v.clips = [Clip(i * 10.0, i * 10.0 + seconds / turns, i) for i in range(turns)]
    return v


def test_match_needs_distance_margin_evidence_and_a_single_voice():
    models = sm.build_models([sample("alan", ALAN, i) for i in range(3)] + [sample("priya", PRIYA, i) for i in range(3)])
    assert sm.match(label(vec(ALAN, 9)), models).accepted
    assert sm.match(label(vec(ALAN, 9)), models).person_id == "alan"
    assert not sm.match(label(vec(RAVI)), models).accepted  # far from everyone
    assert "evidence" in sm.match(label(vec(ALAN, 9), seconds=4.0), models).reason
    assert "evidence" in sm.match(label(vec(ALAN, 9), turns=1), models).reason
    assert "mixed" in sm.match(label(vec(ALAN, 9), spread=0.7), models).reason
    between = centroid([vec(ALAN), vec(PRIYA)])
    found = sm.match(label(between), models)
    assert not found.accepted and ("margin" in found.reason or "distance" in found.reason)


def test_activation_needs_three_samples_from_two_days_beyond_enrollment_and_leave_one_out():
    enrolled = [sample("alan", ALAN, 0, source="enrollment")]
    one_day = enrolled + [sample("alan", ALAN, i) for i in (1, 2, 3)]
    assert not sm.build_models(one_day)["alan"].active  # all on one day
    two_days = enrolled + [sample("alan", ALAN, 1), sample("alan", ALAN, 2), sample("alan", ALAN, 3, day="2026-09-21")]
    assert sm.build_models(two_days)["alan"].active
    assert not sm.build_models(enrolled)["alan"].active  # enrollment alone
    polluted = two_days + [sample("alan", PRIYA, 4, day="2026-09-22")]  # a mislabeled sample fails leave-one-out
    assert "leave-one-out" in sm.build_models(polluted)["alan"].why_inactive


def test_assign_keeps_user_labels_and_blocked_people_and_auto_names_only_active_people():
    active = [sample("alan", ALAN, 0, source="enrollment")] + [sample("alan", ALAN, i, day=f"2026-09-2{i}") for i in (1, 2, 3)]
    inactive = [sample("priya", PRIYA, i) for i in (1, 2)]
    models = sm.build_models(active + inactive)
    voices = {"S1": label(vec(ALAN, 7)), "S2": label(vec(PRIYA, 7)), "S3": label(vec(ALAN, 8))}
    states = sm.assign(voices, {}, models, auto_assign=True)
    assert states["S1"]["person_id"] == "alan" and states["S1"]["source"] == "auto"
    assert states["S2"]["person_id"] is None  # Priya is not active yet: suggestions only
    assert states["S3"]["person_id"] == "alan"  # several labels may be one person
    sticky = sm.assign(voices, {"S1": {"person_id": "priya", "source": "user"}}, models, auto_assign=True)
    assert sticky["S1"]["person_id"] == "priya" and sticky["S1"]["source"] == "user"
    blocked = sm.assign(voices, {"S1": {"not": ["alan"]}}, models, auto_assign=True)
    assert blocked["S1"]["person_id"] is None and blocked["S1"]["not"] == ["alan"]
    off = sm.assign(voices, {}, models, auto_assign=False)
    assert all(s["person_id"] is None for s in off.values())


def test_a_second_voice_close_to_the_only_known_person_is_not_named_after_them():
    """Seen end to end with WeSpeaker: two `say` voices 0.04 and 0.44 from the only enrolled person.
    With nobody else there is no runner-up, so the other labels in the conversation are compared."""
    models = sm.build_models([sample("alan", ALAN, 0, source="enrollment")]
                             + [sample("alan", ALAN, i, day=f"2026-09-2{i}") for i in (1, 2, 3)])  # fmt: skip
    near = 0.65 * vec(ALAN, 7) + 0.76 * vec(RAVI)
    near = near / np.linalg.norm(near)  # within the threshold of Alan, but clearly another voice
    assert sm.match(label(near), models).accepted, "alone, it would be named Alan"
    states = sm.assign({"S1": label(vec(ALAN, 8)), "S2": label(near)}, {}, models, auto_assign=True)
    assert states["S1"]["person_id"] == "alan" and states["S2"]["person_id"] is None
    assert states["S2"]["distance"] is not None, "the distance is still reported"
    split = sm.assign({"S1": label(vec(ALAN, 8)), "S2": label(vec(ALAN, 9))}, {}, models, auto_assign=True)
    assert split["S1"]["person_id"] == split["S2"]["person_id"] == "alan", "an over-split keeps both labels"
    confirmed = sm.assign({"S1": label(vec(ALAN, 8)), "S2": label(near)}, {"S1": {"person_id": "alan", "source": "user"}},
                          models, auto_assign=True)  # fmt: skip
    assert confirmed["S1"]["source"] == "user" and confirmed["S2"]["person_id"] is None


# -- pure: suggestions ---------------------------------------------------------------------------------


def candidate(conv: str, f0: float, day: str, seconds: float = 12.0, rms: float = -30.0, i: int = 0) -> sg.Candidate:
    return sg.Candidate(conv, "S1", vec(f0, i), seconds, day, rms)


def test_suggestions_need_three_conversations_on_two_days_and_respect_dismissals():
    ravi = [candidate(f"r{i}", RAVI, day, i=i) for i, day in enumerate(["d1", "d1", "d2"])]
    few = [candidate(f"p{i}", PRIYA, "d1", i=i) for i in range(4)]  # one day only
    short = [candidate(f"s{i}", 350.0, f"d{i}", seconds=5.0, i=i) for i in range(4)]  # too little speech each
    found = sg.suggestions(ravi + few + short, {}, me_exists=True, dismissed={}, now=0)
    assert [s.kind for s in found] == ["who_is_this"] and found[0].conversations == 3 and found[0].days == 2
    again = sg.suggestions(ravi, {}, me_exists=True, dismissed={found[0].id: 100.0}, now=50)
    assert again == []
    later = sg.suggestions(ravi, {}, me_exists=True, dismissed={found[0].id: 100.0}, now=150)
    assert [s.id for s in later] == [found[0].id]


def test_suggestions_ask_is_this_you_for_the_loudest_voice_and_name_known_people():
    loud = [candidate(f"a{i}", ALAN, f"d{i % 2}", rms=-15.0, i=i) for i in range(3)]
    quiet = [candidate(f"r{i}", RAVI, f"d{i % 2}", rms=-35.0, i=i) for i in range(3)]
    kinds = {s.members[0].conversation_id[0]: s.kind for s in sg.suggestions(loud + quiet, {}, me_exists=False,
                                                                                dismissed={}, now=0)}  # fmt: skip
    assert kinds == {"a": "is_this_you", "r": "who_is_this"}
    models = sm.build_models([sample("ravi", RAVI, i) for i in range(2)])
    found = sg.suggestions(quiet, models, me_exists=True, dismissed={}, now=0)
    assert found[0].kind == "is_this_person" and found[0].person_id == "ravi"


# -- pipeline + API --------------------------------------------------------------------------------------


def test_recognition_is_inert_until_someone_is_named(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    conv_dir = Vault.open(settings).conversation_dir(row["id"])
    assert not list(conv_dir.glob("voices-*.json")) and not (conv_dir / "speakers.json").exists()
    assert worker.providers.embedder.calls == 0
    transcript = json.loads((conv_dir / "transcript.json").read_text())
    assert set(transcript["speaker_clips"]) == {"S1", "S2"}
    speakers = client.get(f"/v1/conversations/{row['id']}/speakers", headers=AUTH).json()
    assert speakers["revision"] == 0 and speakers["audio_available"] is True
    assert [(x["label"], x["person_id"], x["clip_id"]) for x in speakers["labels"]] == [
        ("S1", None, f"{row['id']}.S1.0"), ("S2", None, f"{row['id']}.S2.0")]  # fmt: skip


def test_naming_me_relabels_from_cache_and_later_recognizes_me(env):
    settings, client, worker = env
    first = talk(client, worker, dialogue(ALAN, PRIYA), day=6)
    llm = worker.providers.llm
    calls = llm.calls
    me = new_person(client, "Alan", me=True)
    assert (settings.vault_dir / "People" / "Alan.md").read_text().startswith("---\nomi_person_id: " + me)
    r = name_label(client, first["id"], "S1", me)
    assert r.status_code == 200, r.text
    assert r.json()["sample"] == "created" and r.json()["revision"] >= 1
    worker.tick(T0 + 1000)
    note = (settings.vault_dir / first["note_path"]).read_text()
    assert "speakers:\n- 'S1: [[Alan]]'\n- 'S2: ?'" in note and "people:\n- '[[Alan]]'" in note
    assert "· Alan:**" in note and "Speaker 2" in note
    assert llm.calls == calls  # relabeling re-renders from cache: no LLM call

    # Two more sessions on other days make Alan's voice "active": new conversations name him.
    for day in (5, 4):
        row = talk(client, worker, dialogue(ALAN, RAVI, seed=day), day=day)
        assert name_label(client, row["id"], "S1", me).json()["sample"] == "created"
    people = {p["name"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}
    assert people["Alan"]["samples"] == 3 and people["Alan"]["auto_active"] is True and people["Alan"]["me"] is True
    fresh = talk(client, worker, dialogue(ALAN, PRIYA, seed=40), day=1)
    labels = {x["label"]: x for x in client.get(f"/v1/conversations/{fresh['id']}/speakers", headers=AUTH).json()["labels"]}
    assert labels["S1"]["person_id"] == me and labels["S1"]["source"] == "auto"
    assert labels["S1"]["distance"] < 0.5 and labels["S1"]["evidence_s"] >= 5 and labels["S2"]["person_id"] is None
    assert "S1 = the owner (Alan)" in llm.prompts[-1]
    conv_dir = Vault.open(settings).conversation_dir(fresh["id"])
    assert any("-s" in p.name for p in conv_dir.glob("llm-*.json"))
    voices = json.loads(next(conv_dir.glob("voices-*.json")).read_text())
    assert "vector_b64" in voices["labels"]["S1"] and "vector_b64" not in voices["labels"]["S2"]  # unknown: not kept


def test_forget_voice_clears_names_and_rerenders(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    worker.tick(T0 + 1000)
    assert "S1: [[Alan]]" in (settings.vault_dir / row["note_path"]).read_text()
    r = client.delete(f"/v1/people/{me}", headers=AUTH)
    assert r.status_code == 200 and r.json()["relabeled_conversations"] == [row["id"]]
    assert not Vault.open(settings).person_dir(me).exists()
    worker.tick(T0 + 1100)
    note = (settings.vault_dir / row["note_path"]).read_text()
    assert "[[Alan]]" not in note and "Speaker 1" in note
    assert (settings.vault_dir / "People" / "Alan.md").exists()  # the note stays unless asked
    client.delete(f"/v1/people/{me}?delete_note=true", headers=AUTH)
    assert not (settings.vault_dir / "People" / "Alan.md").exists()


def test_voiceprints_of_other_people_need_acknowledgment_and_attestation(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    priya = new_person(client, "Priya")
    assert name_label(client, row["id"], "S2", priya).json()["sample"] == "not_acknowledged"
    assert client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH).json()[
        "acknowledged_at"] == "2026-09-27T10:00:00.000Z"  # fmt: skip
    assert name_label(client, row["id"], "S2", priya).json()["sample"] == "not_attested"
    client.put(f"/v1/people/{priya}", json={"name": "Priya", "attest_knows": True}, headers=AUTH)
    result = name_label(client, row["id"], "S2", priya).json()
    assert result["sample"] == "created"
    assert [x["name"] for x in result["labels"]] == [None, "Priya"]
    sample_file = next((Vault.open(settings).person_dir(priya) / "samples").glob("*.json"))
    data = json.loads(sample_file.read_text())
    assert data["model"] == "fake-voice" and data["source"] == "user" and data["attested"] is True and data["dim"] == 32


def test_label_assignment_revisions_and_request_dedupe(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    body = {"person_id": me, "expected_revision": 0, "request_id": "req-1"}
    first = client.put(f"/v1/conversations/{row['id']}/speakers/S1", json=body, headers=AUTH)
    retry = client.put(f"/v1/conversations/{row['id']}/speakers/S1", json=body, headers=AUTH)
    assert first.status_code == retry.status_code == 200 and retry.json()["revision"] == first.json()["revision"]
    assert len(worker.db.query("SELECT * FROM samples")) == 1
    stale = client.put(f"/v1/conversations/{row['id']}/speakers/S2",
                       json={"person_id": None, "not_person_id": me, "expected_revision": 0, "request_id": "req-2"},
                       headers=AUTH)  # fmt: skip
    assert stale.status_code == 409 and stale.json()["error"] == "stale_revision"
    revision = first.json()["revision"]
    missing = client.put(f"/v1/conversations/{row['id']}/speakers/S9",
                         json={"person_id": me, "expected_revision": revision, "request_id": "req-3"}, headers=AUTH)  # fmt: skip
    assert missing.status_code == 404
    blocked = client.put(f"/v1/conversations/{row['id']}/speakers/S1",
                         json={"person_id": None, "not_person_id": me, "expected_revision": revision, "request_id": "req-4"},
                         headers=AUTH).json()  # fmt: skip
    assert blocked["labels"][0]["person_id"] is None and blocked["revision"] > revision
    record = json.loads((Vault.open(settings).conversation_dir(row["id"]) / "speakers.json").read_text())
    assert record["labels"]["S1"]["not"] == [me] and "req-1" in record["requests"]


def test_me_is_unique(env):
    settings, client, worker = env
    first = new_person(client, "Alan", me=True)
    second = new_person(client, "Alan Two", me=True)
    people = {p["id"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}
    assert (people[first]["me"], people[second]["me"]) == (False, True)
    assert "omi_me: false" in (settings.vault_dir / "People" / "Alan.md").read_text()


def test_clips_are_wav_while_raw_audio_exists_then_gone(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    r = client.get(f"/v1/clips/{row['id']}.S1.0", headers=AUTH)
    assert r.status_code == 200 and r.headers["content-type"] == "audio/wav"
    pcm, rate = sf.read(io.BytesIO(r.content), dtype="int16")
    assert rate == 16000 and pcm.ndim == 1 and 0 < len(pcm) <= 10 * 16000
    assert client.get(f"/v1/clips/{row['id']}.S1.9", headers=AUTH).status_code == 404
    assert client.get(f"/v1/clips/{row['id']}.S7.0", headers=AUTH).status_code == 404
    worker.retention(time.time() + 400 * 86400)
    gone = client.get(f"/v1/clips/{row['id']}.S1.0", headers=AUTH)
    assert gone.status_code == 410 and gone.json()["error"] == "audio_expired"
    assert client.get(f"/v1/conversations/{row['id']}/speakers", headers=AUTH).json()["audio_available"] is False


def test_unknown_voices_suggestions_and_pruning(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    seed = talk(client, worker, dialogue(ALAN, PRIYA), day=9)
    name_label(client, seed["id"], "S1", me)  # recognition is no longer inert
    assert client.get("/v1/speakers/suggestions", headers=AUTH).json() == {"suggestions": []}
    assert client.put("/v1/speakers/settings", json={"unknown_voices_enabled": True}, headers=AUTH).json()[
        "unknown_voices_enabled"] is True  # fmt: skip
    rows = [talk(client, worker, dialogue(ALAN, RAVI, turns=6, seconds=5.0, seed=day), day=day) for day in (3, 2, 2)]
    for row in rows:
        voices = json.loads(next(Vault.open(settings).conversation_dir(row["id"]).glob("voices-*.json")).read_text())
        assert all("vector_b64" in v for v in voices["labels"].values())  # opted in: every label is kept
    found = {x["kind"]: x for x in client.get("/v1/speakers/suggestions", headers=AUTH).json()["suggestions"]}
    assert set(found) == {"who_is_this", "is_this_person"}  # Ravi; and Alan, whose voice isn't active yet
    assert found["is_this_person"]["person_id"] == me
    s = found["who_is_this"]
    assert s["conversations"] == 3 and s["days"] == 2 and s["seconds"] >= 30 and s["excerpt"]
    assert client.post(f"/v1/speakers/suggestions/{s['id']}/dismiss", headers=AUTH).status_code == 204
    assert [x["kind"] for x in client.get("/v1/speakers/suggestions", headers=AUTH).json()["suggestions"]] == ["is_this_person"]
    settings_file = json.loads((settings.vault_dir / "_omi" / "speakers" / "settings.json").read_text())
    assert s["id"] in settings_file["dismissed"]

    # A suggestion the user names: every member label is assigned (samples only with consent).
    settings_file["dismissed"] = {}
    Vault.write_json(settings.vault_dir / "_omi" / "speakers" / "settings.json", settings_file)
    ravi = new_person(client, "Ravi", attest_knows=True)
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH)
    r = client.post(f"/v1/speakers/suggestions/{s['id']}/assign", json={"person_id": ravi, "request_id": "sug-1"},
                    headers=AUTH)  # fmt: skip
    assert r.status_code == 200 and set(r.json()["relabeled_conversations"]) >= {row["id"] for row in rows}
    assert client.post(f"/v1/speakers/suggestions/{s['id']}/assign", json={"person_id": ravi, "request_id": "sug-2"},
                       headers=AUTH).status_code == 404  # fmt: skip
    for row in rows:
        labels = {x["label"]: x["person_id"] for x in
                  client.get(f"/v1/conversations/{row['id']}/speakers", headers=AUTH).json()["labels"]}  # fmt: skip
        assert labels["S2"] == ravi

    # Unknown vectors expire with the raw audio; assigned ones stay.
    other = talk(client, worker, dialogue(PRIYA, 350.0, seed=77), day=0, at=T0 + 3000)
    worker.retention(time.time() + 400 * 86400)
    voices = json.loads(next(Vault.open(settings).conversation_dir(other["id"]).glob("voices-*.json")).read_text())
    assert not any("vector_b64" in v for v in voices["labels"].values())
    kept = json.loads(next(Vault.open(settings).conversation_dir(rows[0]["id"]).glob("voices-*.json")).read_text())
    assert "vector_b64" in kept["labels"]["S2"]


def test_turning_unknown_voices_off_deletes_their_vectors(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    name_label(client, talk(client, worker, dialogue(ALAN, PRIYA), day=5)["id"], "S1", me)
    client.put("/v1/speakers/settings", json={"unknown_voices_enabled": True}, headers=AUTH)
    row = talk(client, worker, dialogue(PRIYA, RAVI, seed=3), day=2)
    path = next(Vault.open(settings).conversation_dir(row["id"]).glob("voices-*.json"))
    assert all("vector_b64" in v for v in json.loads(path.read_text())["labels"].values())
    client.put("/v1/speakers/settings", json={"unknown_voices_enabled": False}, headers=AUTH)
    assert not any("vector_b64" in v for v in json.loads(path.read_text())["labels"].values())


def test_resummarize_queues_a_forced_llm_run_with_names(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    worker.tick(T0 + 1000)
    calls = worker.providers.llm.calls
    assert client.post(f"/v1/conversations/{row['id']}/resummarize", headers=AUTH).status_code == 202
    worker.tick(T0 + 1100)
    assert worker.providers.llm.calls == calls + 1 and "S1 = the owner (Alan)" in worker.providers.llm.prompts[-1]
    llm_files = list(Vault.open(settings).conversation_dir(row["id"]).glob("llm-*.json"))
    assert len(llm_files) == 1  # the superseded summary is gone


def test_rebuild_restores_people_samples_and_assignments(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    worker.tick(T0 + 1000)
    worker.tick(T0 + 1100)
    revision = worker.db.one("SELECT speakers_revision FROM conversations WHERE id=?", (row["id"],))[0]
    before = {p.relative_to(settings.vault_dir).as_posix(): p.read_bytes() for p in settings.vault_dir.rglob("*")
              if p.is_file() and p.name != "_status.md"}  # fmt: skip
    shutil.rmtree(settings.index_dir)
    app = create_app(settings, start_worker=False)
    fresh = Worker(settings, app.state.db)

    class Exploding:
        def __getattr__(self, name):
            raise AssertionError(f"provider used after the rebuild: {name}")

    fresh.providers._stt = fresh.providers._llm = Exploding()
    fresh.providers._embedder = FakeEmbedder()
    app.state.speakers = SpeakerService(fresh.pipeline)
    for t in (T0 + 1200, T0 + 1300):
        fresh.tick(t)
    after = {p.relative_to(settings.vault_dir).as_posix(): p.read_bytes() for p in settings.vault_dir.rglob("*")
             if p.is_file() and p.name != "_status.md"}  # fmt: skip
    assert [k for k in set(before) | set(after) if before.get(k) != after.get(k)] == []
    labels = TestClient(app).get(f"/v1/conversations/{row['id']}/speakers", headers=AUTH).json()
    assert labels["revision"] == revision and labels["labels"][0]["person_id"] == me
    assert fresh.db.one("SELECT COUNT(*) AS n FROM samples")["n"] == 1


def test_renaming_a_people_note_relinks_its_conversations_from_cache(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    name_label(client, row["id"], "S1", me)
    worker.tick(T0 + 1000)
    calls = worker.providers.llm.calls
    (settings.vault_dir / "People" / "Alan.md").rename(settings.vault_dir / "People" / "Alan Smith.md")  # in Obsidian
    worker.tick(T0 + 1100)
    note = (settings.vault_dir / row["note_path"]).read_text()
    assert "S1: [[Alan Smith]]" in note and "[[Alan]]" not in note and worker.providers.llm.calls == calls
    people = client.get("/v1/people", headers=AUTH).json()["people"]
    assert [(p["id"], p["name"], p["note_path"]) for p in people] == [(me, "Alan Smith", "People/Alan Smith.md")]


def test_speakers_bench_reports_separation(env):
    from typer.testing import CliRunner

    from omi_notes.cli import app as cli

    from .conftest import cli_env

    settings, client, worker = env
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH)
    me = new_person(client, "Alan", me=True)
    priya = new_person(client, "Priya", attest_knows=True)
    for day in (3, 2):
        row = talk(client, worker, dialogue(ALAN, PRIYA, seed=day), day=day)
        name_label(client, row["id"], "S1", me)
        name_label(client, row["id"], "S2", priya)
    result = CliRunner().invoke(cli, ["speakers", "bench"], env=cli_env(settings))
    assert result.exit_code == 0, result.output
    assert "Model fake-voice" in result.output and "same person" in result.output and "different people" in result.output
    assert "separable: suggested SPEAKER_MATCH_THRESHOLD=" in result.output
