"""Where speaker labels come from (provider, local diarization, none) and the diarization rule."""

from __future__ import annotations

import httpx
import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.audio.diarize import Turn
from omi_notes.db import Database
from omi_notes.devtools import synth_speech_like
from omi_notes.pipeline.speakers import resolve_speakers
from omi_notes.pipeline.worker import Worker
from omi_notes.providers import ProviderError
from omi_notes.providers.openai_stt import OpenAICompatStt
from omi_notes.speakers.voices import label_turns, select_clips

from .conftest import AUTH, make_settings
from .helpers import T0, convs, note_text, replay, silence


def response(speakers, pieces=1):
    utts = [{"start": float(i), "end": i + 0.9, "transcript": f"u{i}", "speaker": s,
             "words": [{"word": f"u{i}", "punctuated_word": f"u{i}", "start": float(i), "end": i + 0.9}]}
            for i, s in enumerate(speakers)]  # fmt: skip
    data = {"results": {"utterances": utts}}
    if pieces > 1:
        data["omi_notes"] = {"pieces": pieces}
    return data


LOCAL = [Turn(0.0, 1.5, 0), Turn(1.5, 3.0, 1)]


def local_available():
    return LOCAL


def local_missing():
    return None


def local_broken():
    raise RuntimeError("onnx exploded")


def labels(result):
    return [u["speaker"] for u in result.response["results"]["utterances"]]


@pytest.mark.parametrize(
    "mode, provider_speakers, pieces, local, source, consistent, expected",
    [
        ("auto", [0, 1, 0], 1, local_available, "provider", True, [0, 1, 0]),
        ("auto", [0, 1, 2], 3, local_available, "local", True, [0, 0, 1]),
        ("auto", [0, 1, 2], 3, local_missing, "provider", False, [0, 1, 2]),
        ("auto", [0, 1, 2], 3, local_broken, "provider", False, [0, 1, 2]),
        ("auto", [None, None, None], 1, local_available, "local", True, [0, 0, 1]),
        ("provider", [0, 1, 0], 1, local_available, "provider", True, [0, 1, 0]),
        ("provider", [0, 1, 2], 3, local_available, "provider", False, [0, 1, 2]),
        ("local", [0, 0, 0], 1, local_available, "local", True, [0, 0, 1]),
        ("off", [None, None, None], 1, local_available, "none", True, [0, 0, 0]),
        ("off", [0, 1, 0], 1, local_missing, "provider", True, [0, 1, 0]),
    ],
)
def test_speaker_source(mode, provider_speakers, pieces, local, source, consistent, expected):
    result = resolve_speakers(response(provider_speakers, pieces), mode, local)
    assert (result.source, result.consistent, labels(result)) == (source, consistent, expected)


@pytest.mark.parametrize(
    "mode, provider_speakers, local",
    [
        ("auto", [None, None], local_missing),
        ("auto", [None, None], local_broken),
        ("provider", [None, None], local_available),
        ("local", [0, 1], local_missing),
        ("local", [0, 1], local_broken),
    ],
)
def test_missing_diarization_is_a_terminal_error_that_says_what_to_do(mode, provider_speakers, local):
    with pytest.raises(ProviderError) as info:
        resolve_speakers(response(provider_speakers), mode, local)
    error = info.value
    assert error.terminal and error.kind == "diarization"
    text = str(error)
    if mode != "local":
        assert "diarizing" in text
    assert "--extra diarization" in text and "fetch-models --diarization" in text


# -- through the pipeline ----------------------------------------------------------------------------

SPEECH = np.concatenate([silence(1), synth_speech_like(10), silence(2)])


def openai_stt(payload, **kwargs) -> OpenAICompatStt:
    return OpenAICompatStt("http://localhost:8080/v1", "", "whisper-1", transport=httpx.MockTransport(lambda r: httpx.Response(200, json=payload)), **kwargs)


def pipeline(tmp_path, **overrides):
    settings = make_settings(tmp_path, stt_provider="openai", stt_base_url="http://localhost:8080/v1", stt_model="whisper-1", **overrides)
    client = TestClient(create_app(settings, start_worker=False))
    return settings, client, Worker(settings, Database(settings.db_path))


PLAIN = {"language": "en", "text": "We should ship it. Agreed, ship it on Friday.",
         "segments": [{"start": 0.1, "end": 4.0, "text": "We should ship the new build this week."},
                      {"start": 4.5, "end": 9.0, "text": "Agreed, let's ship it on Friday after the review."}]}  # fmt: skip


class FakeDiarizer:
    tag = "fake"

    def __init__(self):
        self.calls = 0

    def diarize(self, pcm):
        self.calls += 1
        return [Turn(0.0, 4.2, 0), Turn(4.2, 20.0, 1)]


def test_text_only_voice_evidence_uses_real_turns_with_transcript_label_order():
    data = {"results": {"utterances": [
        {"start": 0, "end": 12, "speaker": 7, "transcript": "Two speech turns in one request."},
        {"start": 12, "end": 18, "speaker": 2, "transcript": "A second person."},
    ]}}
    turns = [Turn(0.5, 5, 7), Turn(6, 11, 7), Turn(13, 17, 2)]
    spans = label_turns(data, local_turns=turns)
    assert spans == {"S1": [(0.5, 5), (6, 11)], "S2": [(13, 17)]}
    clips = select_clips(spans, [(0, 18)])
    assert len({c.turn for c in clips["S1"]}) == 2
    assert sum(c.seconds for c in clips["S1"]) >= 5


def test_text_only_cloud_transcription_preserves_local_speakers_and_reuses_cache(tmp_path):
    import json

    settings, client, worker = pipeline(tmp_path, stt_diarization="local")
    seen = []
    def handler(request):
        seen.append(request)
        return httpx.Response(200, json={"text": "We should ship this on Friday." if len(seen) == 1 else "I agree, after the review."})
    worker.providers._stt = OpenAICompatStt("https://transcription.example/v1", "", "gpt-transcribe", style="json",
                                          transport=httpx.MockTransport(handler))
    worker.providers._diarizer = FakeDiarizer()
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "done" and len(seen) == 2
    transcript = json.loads((worker.pipeline.conv_dir(row["id"]) / "transcript.json").read_text())
    assert {s["speaker"] for s in transcript["segments"]} == {"S1", "S2"}
    assert all(s["end"] > s["start"] for s in transcript["segments"])
    assert transcript["speaker_source"] == "local"
    worker.db.execute("UPDATE conversations SET status='closed' WHERE id=?", (row["id"],))
    worker.tick(T0 + 300)
    assert len(seen) == 2 and worker.providers._diarizer.calls == 1


def test_text_only_stt_cannot_send_audio_before_local_speakers_are_available(tmp_path):
    _, client, worker = pipeline(tmp_path, stt_diarization="local")
    def unexpected(request):
        pytest.fail("audio sent without local speaker windows")
    worker.providers._stt = OpenAICompatStt("https://example.test/v1", "", "gpt-transcribe",
                                          transport=httpx.MockTransport(unexpected))
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "failed" and row["error_kind"] == "diarization"


def test_transcript_without_speakers_fails_with_instructions(tmp_path):
    settings, client, worker = pipeline(tmp_path)
    worker.providers._stt = openai_stt(PLAIN)
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "failed" and row["error_kind"] == "diarization"
    status = (settings.vault_dir / "_status.md").read_text()
    assert "speaker labels" in status and "fetch-models --diarization" in status


def test_diarization_off_accepts_a_single_speaker(tmp_path):
    settings, client, worker = pipeline(tmp_path, stt_diarization="off")
    worker.providers._stt = openai_stt(PLAIN)
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "done"
    assert "**Speakers:** 1" in note_text(settings, row)


def test_local_diarization_labels_a_plain_transcript_once(tmp_path):
    settings, client, worker = pipeline(tmp_path)
    worker.providers._stt = openai_stt(PLAIN)
    diarizer = FakeDiarizer()
    worker.providers._diarizer = diarizer
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    text = note_text(settings, row)
    assert row["status"] == "done" and "**Speakers:** 2" in text
    assert "stt: openai/whisper-1+local-diarization" in text
    worker.db.execute("UPDATE conversations SET status='closed' WHERE id=?", (row["id"],))
    worker.tick(T0 + 300)  # re-transcribing reuses the cached diarization
    assert diarizer.calls == 1


def test_split_audio_without_local_diarization_warns_about_labels(tmp_path):
    settings, client, worker = pipeline(tmp_path)

    def handler(request):
        return httpx.Response(200, json={"segments": [{"start": 0.5, "end": 2.0, "text": "part of a long talk", "speaker": "A"}]})

    worker.providers._stt = OpenAICompatStt("http://gpu:8000/v1", "", "moss-diarize", max_request_seconds=5,
                                            transport=httpx.MockTransport(handler))  # fmt: skip
    speech = np.concatenate([silence(1), synth_speech_like(4, seed=1), silence(3), synth_speech_like(4, seed=2), silence(2)])
    replay(client, speech)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    text = note_text(settings, row)
    assert row["status"] == "done" and "speaker_labels_consistent: false" in text
    assert "Speaker labels restart" in text


def test_status_reports_openai_stt_readiness(tmp_path):
    settings, client, _ = pipeline(tmp_path)
    stt = client.get("/v1/status", headers=AUTH).json()["stt"]
    assert stt["provider"] == "openai" and stt["ready"] is True and stt["model"] == settings.stt_model
