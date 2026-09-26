import json

import httpx
import numpy as np
import pytest
import soundfile as sf

from omi_notes.audio.timeline import Piece
from omi_notes.pipeline.transcript import (
    MapSegment,
    assemble,
    map_time,
    merge_same_speaker,
    segments_from_deepgram,
)
from omi_notes.providers import ProviderError, SttRequest
from omi_notes.providers.deepgram import DeepgramStt

from .conftest import FIXTURES

SR = 16000


def ramp(seconds: float, offset: int = 0) -> np.ndarray:
    return ((np.arange(int(seconds * SR)) + offset) % 20000).astype(np.int16)


def test_assemble_blocks_with_spacers_and_time_map():
    pieces = [(0, Piece(990.0, ramp(30))), (0, Piece(1095.0, ramp(20, 7)))]
    audio = assemble([(1000.0, 1010.0), (1100.0, 1105.0)], pieces)
    assert audio.duration == pytest.approx(10 + 0.5 + 5)
    assert audio.blocks_out == [(0.0, 10.0), (10.5, 15.5)]
    assert audio.timemap == [MapSegment(0.0, 1000.0, 10.0), MapSegment(10.5, 1100.0, 5.0)]
    assert np.all(audio.pcm[10 * SR : int(10.5 * SR)] == 0)
    assert audio.missing == []
    decoded, rate = sf.read(__import__("io").BytesIO(audio.flac()), dtype="int16")
    assert rate == SR and np.array_equal(decoded, audio.pcm)


def test_assemble_reports_missing_audio_and_prefers_live():
    live = Piece(1000.0, np.full(5 * SR, 100, dtype=np.int16))
    ring = Piece(1000.0, np.full(8 * SR, 7, dtype=np.int16))
    audio = assemble([(1000.0, 1010.0)], [(2, ring), (0, live)])
    assert np.all(audio.pcm[: 5 * SR] == 100) and np.all(audio.pcm[5 * SR :] == 7)
    assert audio.missing == [(1008.0, 1010.0)]


def test_map_time_edges():
    tm = [MapSegment(0.0, 1000.0, 10.0), MapSegment(10.5, 1100.0, 5.0)]
    assert map_time(tm, 3.0) == 1003.0
    assert map_time(tm, 10.0) == 1010.0
    assert map_time(tm, 10.1) == 1010.0  # in the spacer, nearer the previous block
    assert map_time(tm, 10.45) == 1100.0  # in the spacer, nearer the next block
    assert map_time(tm, 12.0) == 1101.5
    assert map_time(tm, 99.0) == 1105.0
    assert map_time([], 5.0) == 5.0


def test_deepgram_response_to_wall_clock_segments():
    response = json.loads((FIXTURES / "deepgram_utterances.json").read_text())
    tm = [MapSegment(0.0, 1000.0, 10.0), MapSegment(10.5, 1100.0, 5.0)]
    segments = segments_from_deepgram(response, tm)
    assert [(s["start"], s["end"], s["speaker"]) for s in segments] == [
        (1000.5, 1004.0, "S1"),
        (1004.8, 1009.5, "S1"),
        (1100.1, 1104.5, "S2"),
    ]
    merged = merge_same_speaker(segments)
    assert [(s["start"], s["end"], s["speaker"]) for s in merged] == [(1000.5, 1009.5, "S1"), (1100.1, 1104.5, "S2")]
    assert merged[0]["text"] == "Hi Daniel, thanks for making time. I wanted to go over the launch plan."
    assert merged[0]["confidence"] == pytest.approx(0.95)


def test_speakers_are_numbered_by_first_appearance():
    response = {"results": {"utterances": [
        {"start": 0, "end": 1, "speaker": 3, "transcript": "a"},
        {"start": 2, "end": 3, "speaker": 0, "transcript": "b"},
    ]}}  # fmt: skip
    assert [s["speaker"] for s in segments_from_deepgram(response, [])] == ["S1", "S2"]


def test_words_fallback_without_utterances():
    response = json.loads((FIXTURES / "deepgram_utterances.json").read_text())
    del response["results"]["utterances"]
    segments = segments_from_deepgram(response, [MapSegment(0.0, 1000.0, 20.0)])
    assert [(s["speaker"], s["text"]) for s in segments] == [("S1", "Hi Daniel,"), ("S2", "Sure,")]


def test_merge_limits():
    segs = [
        {"start": 0, "end": 30, "speaker": "S1", "text": "a", "confidence": 1},
        {"start": 32, "end": 59, "speaker": "S1", "text": "b", "confidence": 1},
        {"start": 59.5, "end": 70, "speaker": "S1", "text": "c", "confidence": 1},  # would exceed 60 s
        {"start": 74, "end": 75, "speaker": "S1", "text": "d", "confidence": 1},  # gap 4 s
    ]
    assert [s["text"] for s in merge_same_speaker(segs)] == ["a b", "c", "d"]


def _stt(handler) -> DeepgramStt:
    return DeepgramStt("key", transport=httpx.MockTransport(handler))


def test_deepgram_request_shape():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = request.url
        seen["headers"] = request.headers
        seen["body"] = request.content
        return httpx.Response(200, json={"results": {"utterances": []}})

    _stt(handler).transcribe(SttRequest(flac=b"fLaC", duration=1, blocks=[], language="en", keyterms=["Omi", "Priya"]))
    params = seen["url"].params
    assert seen["url"].path == "/v1/listen"
    assert params["model"] == "nova-3" and params["diarize"] == "true" and params["utterances"] == "true"
    assert params["smart_format"] == "true" and params["punctuate"] == "true" and params["language"] == "en"
    assert params.get_list("keyterm") == ["Omi", "Priya"]
    assert seen["headers"]["authorization"] == "Token key" and seen["headers"]["content-type"] == "audio/flac"
    assert seen["body"] == b"fLaC"


@pytest.mark.parametrize("status, terminal, kind", [(401, True, "auth"), (402, True, "billing"), (403, True, "auth"),
                                                    (429, False, "transient"), (503, False, "transient"),
                                                    (400, True, "request")])  # fmt: skip
def test_deepgram_error_mapping(status, terminal, kind):
    stt = _stt(lambda request: httpx.Response(status, text="nope"))
    with pytest.raises(ProviderError) as info:
        stt.transcribe(SttRequest(flac=b"", duration=0, blocks=[], language="en", keyterms=[]))
    assert info.value.terminal is terminal and info.value.kind == kind


def test_deepgram_missing_key_is_terminal():
    with pytest.raises(ProviderError) as info:
        DeepgramStt("")
    assert info.value.terminal
