"""The HTTP contract with a fake engine (no models): diarized shape, context terms, loopback-only."""

import io

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from omi_asr import server


class FakeEngine:
    loaded = False

    def __init__(self):
        self.calls = []

    def transcribe(self, pcm, context):
        self.calls.append((len(pcm), context))
        return {"text": "你好 hi", "language": "zh", "duration": len(pcm) / 16000,
                "segments": [{"start": 0.0, "end": 1.0, "speaker_id": "S01", "text": "你好"},
                             {"start": 1.2, "end": 2.0, "speaker_id": "S02", "text": "hi"}],
                "omi_asr": {"seconds": 0.1, "rtf": 0.05}}

    def unload_if_idle(self):
        return False

    def self_test(self):
        pass


def flac(seconds=2.0, rate=16000):
    buf = io.BytesIO()
    sf.write(buf, np.zeros(int(seconds * rate), np.float32), rate, format="FLAC", subtype="PCM_16")
    return buf.getvalue()


def test_transcriptions_returns_the_diarized_shape_and_takes_context_not_as_a_moss_prompt():
    engine = FakeEngine()
    client = TestClient(server.create_app(engine))
    assert client.get("/health").json()["ok"] is True
    r = client.post("/v1/audio/transcriptions", files={"file": ("a.flac", flac(), "audio/flac")},
                    data={"model": "omi-asr", "response_format": "diarized_json", "context": "Overleaf, Grok\nreactance",
                          "prompt": "Grok, Omi"})
    assert r.status_code == 200
    body = r.json()
    assert [s["speaker_id"] for s in body["segments"]] == ["S01", "S02"] and body["duration"] == 2.0
    assert engine.calls == [(32000, ["Overleaf", "Grok", "reactance", "Omi"])]


def test_other_rates_are_resampled_and_bad_audio_is_400():
    engine = FakeEngine()
    client = TestClient(server.create_app(engine))
    assert client.post("/v1/audio/transcriptions", files={"file": ("a.flac", flac(1.0, 48000), "audio/flac")}).status_code == 200
    assert engine.calls[-1][0] == 16000
    assert client.post("/v1/audio/transcriptions", files={"file": ("a.flac", b"not audio", "audio/flac")}).status_code == 400


def test_it_refuses_to_bind_beyond_loopback(monkeypatch):
    monkeypatch.setenv("OMI_ASR_HOST", "0.0.0.0")
    with pytest.raises(SystemExit):
        server.main()


class BrokenEngine(FakeEngine):
    def self_test(self):
        raise RuntimeError("metal device lost")


def test_a_failed_startup_self_test_makes_health_fail():
    app = server.create_app(BrokenEngine())
    app.state.guard.self_test()
    r = TestClient(app).get("/health")
    assert r.status_code == 503 and "self-test" in r.json()["reason"]


def test_a_passing_self_test_is_reported():
    app = server.create_app(FakeEngine())
    app.state.guard.self_test()
    assert TestClient(app).get("/health").json()["self_test"] == "ok"


def test_a_request_stuck_past_its_deadline_fails_health_and_the_watchdog_exits():
    exits = []
    app = server.create_app(FakeEngine(), exit=exits.append)
    guard = app.state.guard
    guard.busy_since, guard.deadline = 0.0, 1.0  # a 1 s budget that started at the epoch
    r = TestClient(app).get("/health")
    assert r.status_code == 503 and "stuck" in r.json()["reason"]
    guard.check()
    assert exits == [70]


class SlowEngine(FakeEngine):
    def __init__(self):
        super().__init__()
        import threading
        self.release = threading.Event()
        self.started = threading.Event()

    def transcribe(self, pcm, context):
        self.started.set()
        self.release.wait(5)
        self.release.clear()
        return super().transcribe(pcm, context)


def test_the_deadline_always_belongs_to_the_request_running_now():
    import threading
    import time as _t

    engine = SlowEngine()
    app = server.create_app(engine)
    guard = app.state.guard
    pcm = np.zeros(16000, np.float32)
    first = threading.Thread(target=guard.run, args=(pcm, []))
    first.start()
    engine.started.wait(2)
    engine.started.clear()
    running = guard.deadline
    second = threading.Thread(target=guard.run, args=(pcm, []))
    second.start()
    _t.sleep(0.2)
    assert guard.deadline == running, "a queued request must not move the running one's deadline"
    engine.release.set()
    engine.started.wait(2)
    assert guard.deadline is not None and guard.deadline != running, "the second request now owns it"
    engine.release.set()
    first.join(2)
    second.join(2)
    assert guard.deadline is None


def test_an_engine_failure_answers_503_fails_health_and_restarts_the_service():
    class Failing(FakeEngine):
        def transcribe(self, pcm, context):
            raise RuntimeError("[METAL] Command buffer execution failed")

    exits = []
    app = server.create_app(Failing(), exit=exits.append)
    client = TestClient(app)
    r = client.post("/v1/audio/transcriptions", files={"file": ("a.flac", flac(), "audio/flac")})
    assert r.status_code == 503
    h = client.get("/health")
    assert h.status_code == 503 and "engine failed" in h.json()["reason"]
    app.state.guard.check()
    assert exits == [70]


def test_an_incomplete_transcription_is_a_422_and_not_an_engine_failure():
    from omi_asr.engine import IncompleteTranscription

    class Incomplete(FakeEngine):
        def transcribe(self, pcm, context):
            raise IncompleteTranscription("Qwen failed on 0-30 s and MOSS has no text there")

    exits = []
    app = server.create_app(Incomplete(), exit=exits.append)
    client = TestClient(app)
    r = client.post("/v1/audio/transcriptions", files={"file": ("a.flac", flac(), "audio/flac")})
    assert r.status_code == 422
    assert client.get("/health").status_code == 200
    app.state.guard.check()
    assert exits == []
