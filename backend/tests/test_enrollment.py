"""Voice enrollment through the pendant (docs/speaker-learning.md, "Enrollment")."""

from __future__ import annotations

import json
import uuid

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.pipeline.worker import Worker
from omi_notes.providers.fake import FakeStt
from omi_notes.records import row_from_record
from omi_notes.speakers import enroll
from omi_notes.speakers.service import SpeakerService

from .conftest import AUTH, make_settings
from .helpers import STARTED, T0, convs, event, replay, silence
from .test_speaker_learning import FakeEmbedder

SR = 16000


def voice(seconds: float, f0: float, level: float = 6000.0) -> np.ndarray:
    """A voiced, syllable-modulated signal with dominant pitch `f0` (the fake embedder's voice)."""
    t = np.arange(int(seconds * SR)) / SR
    harmonics = sum(np.sin(2 * np.pi * f0 * k * t) / k for k in (1, 2, 3))
    syllables = 0.55 + 0.45 * np.sin(2 * np.pi * 3.0 * t) ** 2
    return (harmonics * syllables * level / 1.8).astype(np.int16)


class CountingStt(FakeStt):
    calls = 0

    def transcribe(self, request):
        CountingStt.calls += 1
        return super().transcribe(request)


@pytest.fixture
def env(tmp_path):
    settings = make_settings(tmp_path)
    app = create_app(settings, start_worker=False)
    client = TestClient(app)
    worker = Worker(settings, Database(settings.db_path))
    worker.providers._embedder = FakeEmbedder()
    CountingStt.calls = 0
    worker.providers._stt = CountingStt()
    app.state.speakers = SpeakerService(worker.pipeline)
    return settings, client, worker


def start_event(client, eid: str, capture: str, offset_s: float) -> None:
    event(client, "voice_enrollment_start", at=T0 + offset_s, capture_id=capture, offset_us=int(offset_s * 1e6),
          data={"enrollment_id": eid})  # fmt: skip


def end_event(client, eid: str, capture: str, offset_s: float, outcome: str = "completed") -> None:
    event(client, "voice_enrollment_end", at=T0 + offset_s, capture_id=capture, offset_us=int(offset_s * 1e6),
          data={"enrollment_id": eid, "end_offset_us": int(offset_s * 1e6), "outcome": outcome})  # fmt: skip


# -- the audio checks (pure) ------------------------------------------------------------------------


def test_one_clear_voice_is_accepted():
    r = enroll.evaluate(voice(40, 150), FakeEmbedder())
    assert r["state"] == "accepted" and r["speech_s"] == 40.0
    assert r["consistency"] >= 0.8 and r["held_out_distance"] <= 0.5
    assert len(r["enroll_pcm"]) < 40 * SR, "the held-out clip is disjoint from the enrollment audio"


@pytest.mark.parametrize(
    ("pcm", "reason"),
    [
        (voice(12, 150), "Only 12 s"),
        (voice(40, 150, level=40), "too quiet"),
        (np.clip(voice(40, 150, level=60000).astype(np.int32), -32768, 32767).astype(np.int16), "distorted"),
        (np.concatenate([voice(20, 150), voice(20, 260)]), "More than one voice"),
        (np.concatenate([voice(34, 150), voice(9, 280)]), "didn't match"),
    ],
)
def test_bad_recordings_need_another_sample(pcm, reason):
    r = enroll.evaluate(pcm, FakeEmbedder())
    assert r["state"] == "needs_another_sample" and reason in r["reason"], r


# -- end to end -------------------------------------------------------------------------------------


def test_enrollment_window_becomes_a_voiceprint_and_is_never_transcribed(env):
    settings, client, worker = env
    eid = str(uuid.uuid4())
    capture = replay(client, np.concatenate([silence(2), voice(40, 150), silence(4)]), start=STARTED)
    start_event(client, eid, capture, 1.0)
    end_event(client, eid, capture, 43.5)
    worker.tick(T0 + 400)
    worker.tick(T0 + 410)

    (row,) = convs(worker)
    assert row["status"] == "discarded" and row["enrollment_id"] == eid
    assert CountingStt.calls == 0 and row["note_path"] is None
    assert client.get("/v1/conversations/recent", headers=AUTH).json() == {"conversations": []}
    status = client.get(f"/v1/speakers/enrollments/{eid}", headers=AUTH).json()
    assert status["state"] == "accepted" and status["speech_s"] >= 20
    people = client.get("/v1/people", headers=AUTH).json()["people"]
    (me,) = [p for p in people if p["me"]]
    assert me["name"] == "Me" and me["samples"] == 1
    person_dir = worker.vault.omi / "people" / me["id"]
    assert (person_dir / "enrollment" / f"{eid}.omiaudio").exists()
    assert (worker.vault.omi / "speakers" / "enrollments" / f"{eid}.json").exists()
    # the decision is permanent: a rebuild derives "discarded" from the record
    record = json.loads(next(worker.vault.omi.glob(f"conversations/*/{row['id']}/conversation.json")).read_text())
    assert record["decision"]["enrollment_id"] == eid
    values, _ = row_from_record(record)
    assert values["status"] == "discarded"


def test_existing_me_gets_the_sample(env):
    _, client, worker = env
    me = str(uuid.uuid4())
    assert client.put(f"/v1/people/{me}", json={"name": "Alan", "me": True}, headers=AUTH).status_code == 201
    eid = str(uuid.uuid4())
    capture = replay(client, np.concatenate([silence(2), voice(40, 150), silence(4)]))
    start_event(client, eid, capture, 1.0)
    end_event(client, eid, capture, 43.5)
    worker.tick(T0 + 400)
    people = {p["id"]: p for p in client.get("/v1/people", headers=AUTH).json()["people"]}
    assert list(people) == [me] and people[me]["samples"] == 1


def test_a_conversation_waits_while_the_window_end_is_unknown(env):
    _, client, worker = env
    eid = str(uuid.uuid4())
    capture = replay(client, np.concatenate([silence(2), voice(40, 150), silence(4)]))
    start_event(client, eid, capture, 1.0)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "open" and row["waiting_for"] == "voice enrollment"
    assert client.get("/v1/conversations/recent", headers=AUTH).json() == {"conversations": []}
    assert client.get(f"/v1/speakers/enrollments/{eid}", headers=AUTH).json() == {"state": "waiting_audio"}
    end_event(client, eid, capture, 43.5)
    worker.tick(T0 + 410)
    (row,) = convs(worker)
    assert row["status"] == "discarded" and CountingStt.calls == 0


def test_a_cancelled_enrollment_is_not_learned_but_still_not_transcribed(env):
    _, client, worker = env
    eid = str(uuid.uuid4())
    capture = replay(client, np.concatenate([silence(2), voice(25, 150), silence(8)]))
    start_event(client, eid, capture, 1.0)
    end_event(client, eid, capture, 30.0, outcome="cancelled")  # the user stopped reading, then cancelled
    worker.tick(T0 + 400)
    assert client.get(f"/v1/speakers/enrollments/{eid}", headers=AUTH).json()["state"] == "cancelled"
    assert not [p for p in client.get("/v1/people", headers=AUTH).json()["people"] if p["me"]]
    assert CountingStt.calls == 0, "speech inside the window is never transcribed"
    (row,) = convs(worker)
    assert row["status"] == "discarded" and row["enrollment_id"] == eid


def test_speech_after_the_window_is_its_own_conversation(env):
    _, client, worker = env
    eid = str(uuid.uuid4())
    pcm = np.concatenate([silence(2), voice(40, 150), silence(3), voice(20, 150)])
    capture = replay(client, pcm)
    start_event(client, eid, capture, 1.0)
    end_event(client, eid, capture, 43.5)
    worker.tick(T0 + 400)
    worker.tick(T0 + 410)
    rows = sorted(convs(worker), key=lambda r: r["start"])
    assert [r["status"] for r in rows] == ["discarded", "done"]
    assert rows[1]["start"] >= T0 + 43.0 and CountingStt.calls == 1
    (recent,) = client.get("/v1/conversations/recent?limit=1", headers=AUTH).json()["conversations"]
    assert recent["id"] == rows[1]["id"] and recent["speakers_ready"] is True


def test_unknown_enrollment_is_404(env):
    _, client, _ = env
    r = client.get(f"/v1/speakers/enrollments/{uuid.uuid4()}", headers=AUTH)
    assert r.status_code == 404 and r.json()["error"] == "unknown_enrollment"


def test_undecided_enrollment_audio_survives_retention(env):
    settings, client, worker = env
    eid = str(uuid.uuid4())
    capture = replay(client, np.concatenate([silence(2), voice(40, 150), silence(4)]))
    start_event(client, eid, capture, 1.0)  # no end yet: undecided
    worker.tick(T0 + 400)
    worker.retention(T0 + (settings.raw_retention_days + 5) * 86400)
    alive = worker.db.query("SELECT raw_deleted FROM chunks WHERE capture_id=?", (capture,))
    assert alive and all(r["raw_deleted"] == 0 for r in alive)
