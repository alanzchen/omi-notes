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
