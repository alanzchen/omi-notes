"""Text-only cloud STT must keep all audio, stable speakers and successful work on retry."""

import io

import httpx
import numpy as np
import pytest
import soundfile as sf

from omi_notes.audio.diarize import Turn
from omi_notes.pipeline.transcript import ConversationAudio, MapSegment
from omi_notes.pipeline.turn_transcription import speaker_windows, transcribe_windows
from omi_notes.providers import ProviderError, SttRequest
from omi_notes.providers.openai_stt import OpenAICompatStt

from .test_openai_stt import form


def audio(seconds=6):
    pcm = (np.arange(seconds * 16000) % 1000).astype(np.int16)
    assembled = ConversationAudio(pcm, [MapSegment(0, 0, seconds)], [(0, seconds)], [])
    return assembled, SttRequest(assembled.flac(), seconds, [(0, seconds)], "en", [])


def test_windows_cover_gaps_and_keep_overlaps_out_of_voiceprint_evidence():
    windows, overlaps = speaker_windows([Turn(1, 4, 0), Turn(3, 5, 1), Turn(7, 9, 0)], 10)
    assert windows[0].start == 0 and windows[-1].end == 10
    assert all(a.end == b.start for a, b in zip(windows, windows[1:]))
    assert sum(w.end - w.start for w in windows) == 10
    assert {w.speaker for w in windows} == {0, 1}
    assert overlaps == [(3, 4)]


@pytest.mark.parametrize("turns", [[], [Turn(float("nan"), 5, 0)], [Turn(3, 2, 0)], [Turn(20, 30, 0)]])
def test_missing_or_invalid_turns_fail_instead_of_becoming_silence(turns):
    with pytest.raises(ProviderError):
        speaker_windows(turns, 10)


def test_a_partial_failure_reuses_the_successful_window_and_keeps_all_samples(tmp_path):
    assembled, request = audio()
    seen = []
    def handler(req):
        seen.append(form(req))
        if len(seen) == 2:
            return httpx.Response(503, json={"error": "try again"})
        return httpx.Response(200, json={"text": "Remember this appointment."})
    provider = OpenAICompatStt("https://example.test/v1", "", "gpt-transcribe",
                               transport=httpx.MockTransport(handler), max_request_seconds=2)
    turns = [Turn(0, 3, 7), Turn(3, 6, 2)]
    cache = tmp_path / "stt.json"
    with pytest.raises(ProviderError):
        transcribe_windows(provider, assembled, request, turns, cache)
    result = transcribe_windows(provider, assembled, request, turns, cache)
    utterances = result["results"]["utterances"]
    assert [u["speaker"] for u in utterances] == [7, 7, 2, 2]
    assert utterances[0]["start"] == 0 and utterances[-1]["end"] == 6
    assert all(a["end"] == b["start"] for a, b in zip(utterances, utterances[1:]))
    # The first request succeeded before the outage; it was not sent again.
    successful = [seen[0], *seen[2:]]
    decoded = [sf.read(io.BytesIO(fields["file"][0][2]), dtype="int16")[0] for fields in successful]
    np.testing.assert_array_equal(np.concatenate(decoded), assembled.pcm)
    before = len(seen)
    assert transcribe_windows(provider, assembled, request, turns, cache) == result
    assert len(seen) == before
