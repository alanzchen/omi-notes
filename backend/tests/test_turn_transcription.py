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
    # not periodic: windows cut at different times never carry identical samples
    pcm = np.random.default_rng(seconds).integers(-3000, 3000, seconds * 16000).astype(np.int16)
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


# -- windows shorter than the service accepts (docs/architecture.md #11) ----------------------------

SERVICE_MINIMUM = 0.1  # OpenAI-style transcription rejects shorter audio (the proxy answers 502)


def strict_service(seen, texts=None):
    """A text-only service that refuses audio under 0.1 s, like the configured proxy."""
    def handler(req):
        fields = form(req)
        pcm = sf.read(io.BytesIO(fields["file"][0][2]), dtype="int16")[0]
        seen.append(pcm)
        if len(pcm) / 16000 < SERVICE_MINIMUM:
            return httpx.Response(502, text="<!DOCTYPE html><title>Bad Gateway</title>")
        text = (texts or {}).get(len(seen), "")
        return httpx.Response(200, json={"text": text})
    return OpenAICompatStt("https://example.test/v1", "", "gpt-transcribe", style="json",
                           transport=httpx.MockTransport(handler), max_request_seconds=30)


def test_a_sliver_window_is_padded_with_silence_not_merged_into_another_speaker(tmp_path):
    assembled, request = audio(6)
    # a 34 ms turn of speaker 9 between two real turns: what local diarization produces at edges
    turns = [Turn(0, 3, 1), Turn(3, 3.034, 9), Turn(3.034, 6, 1)]
    seen = []
    provider = strict_service(seen, texts={1: "First part.", 2: "Mm.", 3: "Second part."})
    result = transcribe_windows(provider, assembled, request, turns, tmp_path / "stt.json")
    utterances = result["results"]["utterances"]
    # every window was sent on its own, in order; nothing was dropped or merged across speakers
    assert [u["speaker"] for u in utterances] == [1, 9, 1]
    assert [(round(u["start"], 3), round(u["end"], 3)) for u in utterances] == [(0, 3), (3, 3.034), (3.034, 6)]
    # the sliver's request is its own samples followed by silence, long enough for the service
    sliver = seen[1]
    own = assembled.pcm[round(3 * 16000):round(3.034 * 16000)]
    np.testing.assert_array_equal(sliver[: len(own)], own)
    assert not sliver[len(own):].any() and len(sliver) / 16000 >= 0.25
    # all original samples were sent exactly once
    np.testing.assert_array_equal(np.concatenate([s[: len(o)] for s, o in zip(seen, (
        assembled.pcm[:48000], own, assembled.pcm[round(3.034 * 16000):]))]), assembled.pcm)


def test_a_valid_short_word_keeps_its_text_speaker_and_own_times(tmp_path):
    assembled, request = audio(4)
    turns = [Turn(0, 2, 1), Turn(2, 2.15, 2), Turn(2.15, 4, 1)]
    seen = []
    provider = strict_service(seen, texts={1: "Shall we start?", 2: "Yes.", 3: "Good."})
    utterances = transcribe_windows(provider, assembled, request, turns, tmp_path / "stt.json")["results"]["utterances"]
    word = utterances[1]
    assert word["transcript"] == "Yes." and word["speaker"] == 2
    assert (round(word["start"], 3), round(word["end"], 3)) == (2, 2.15)  # padding never stretches the time
    assert len(seen[1]) / 16000 >= 0.25


def test_index_named_window_caches_from_an_older_segmentation_are_not_reused(tmp_path):
    assembled, request = audio(4)
    cache = tmp_path / "stt.json"
    stale = {"results": {"utterances": [{"start": 0, "end": 4, "transcript": "STALE TEXT", "speaker": None}]}}
    (tmp_path / "stt-window-0-0.json").write_text(__import__("json").dumps(stale))  # the old naming
    seen = []
    result = transcribe_windows(strict_service(seen, texts={1: "fresh"}), assembled, request, [Turn(0, 4, 1)], cache)
    assert "STALE TEXT" not in str(result) and len(seen) == 1
    assert (tmp_path / "stt-window-0-0.json").exists()  # kept, never deleted


def test_a_cached_window_is_reused_only_for_the_same_audio(tmp_path):
    assembled, request = audio(4)
    cache = tmp_path / "stt.json"
    seen = []
    provider = strict_service(seen, texts={1: "first", 2: "second"})
    transcribe_windows(provider, assembled, request, [Turn(0, 4, 1)], cache)
    transcribe_windows(provider, assembled, request, [Turn(0, 4, 1)], cache)
    assert len(seen) == 1  # same audio: reused
    changed_pcm = assembled.pcm.copy()
    changed_pcm[100:200] = 7
    changed = ConversationAudio(changed_pcm, assembled.timemap, assembled.blocks_out, [])
    result = transcribe_windows(provider, changed, SttRequest(changed.flac(), 4, [(0, 4)], "en", []), [Turn(0, 4, 1)], cache)
    assert len(seen) == 2 and result["results"]["utterances"][0]["transcript"] == "second"
