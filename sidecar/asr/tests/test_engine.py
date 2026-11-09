"""The engine's window/chunk orchestration with fake models (no MLX inference): no speech is left out of
Qwen's chunks, and what MOSS couldn't finish is flagged."""

from types import SimpleNamespace

import numpy as np
import pytest

pytest.importorskip("mlx.core")

from omi_asr import plan  # noqa: E402
from omi_asr.engine import Engine  # noqa: E402

SR = plan.SR


class FakeMoss:
    def __init__(self, segments):
        self.segments = segments

    def generate(self, audio, max_tokens):
        return SimpleNamespace(segments=self.segments, generation_tokens=100, prompt_tokens=10)


class FakeQwen:
    """Five words per 10 s of audio it is given."""

    def __init__(self):
        self.seconds = []

    def generate(self, audio, hotwords=None, max_tokens=0, **_):
        seconds = audio.shape[0] / SR
        self.seconds.append(seconds)
        words = [f"w{len(self.seconds)}x{i}" for i in range(int(seconds / 2))]
        return SimpleNamespace(text=" ".join(words), generation_tokens=len(words), language=["English"])  # as mlx-audio 0.6.3


class FakeAligner:
    """Spreads the words evenly over the chunk."""

    def generate(self, chunk, text, language):
        words, seconds = text.split(), len(chunk) / SR
        step = seconds / max(len(words), 1)
        return SimpleNamespace(items=[SimpleNamespace(text=w, start_time=i * step, end_time=(i + 0.8) * step)
                                      for i, w in enumerate(words)])  # fmt: skip


def engine(moss_segments):
    e = Engine()
    qwen = FakeQwen()
    e.models = (FakeMoss(moss_segments), qwen, FakeAligner())
    return e, qwen


def speech(seconds):
    return (np.random.default_rng(0).normal(0, 0.1, int(seconds * SR))).astype(np.float32)


def test_speech_after_mosss_last_line_still_reaches_qwen_and_the_truncation_is_flagged():
    e, qwen = engine([{"start": 0.0, "end": 20.0, "speaker_id": "S01", "text": "[0.00][S01] early"}])
    out = e.transcribe(speech(60), [])
    assert sum(qwen.seconds) == pytest.approx(60, abs=0.1), "Qwen hears the whole window, not just MOSS's lines"
    assert len(out["text"].split()) == 30
    assert out["omi_asr"]["truncated_unresolved"] == 1
    late = [x for x in out["segments"] if x["speaker_id"] == "UNKNOWN"]
    assert late and late[-1]["end"] >= 55, "words past where MOSS stopped are kept, attributed to nobody"
    assert max(x["end"] for x in out["segments"] if x["speaker_id"] == "S01") <= 21, "not given to the last speaker"


def test_a_window_where_moss_found_no_lines_keeps_qwens_text_under_one_flagged_label():
    e, _ = engine([])
    out = e.transcribe(speech(30), [])
    assert len(out["text"].split()) == 15
    assert {s["speaker_id"] for s in out["segments"]} == {"UNKNOWN"}, "no speaker is invented"
    assert out["omi_asr"]["unlabeled_windows"] == 1


def test_the_language_is_a_plain_name_even_though_qwen_reports_a_list():
    e, _ = engine([{"start": 0.0, "end": 30.0, "speaker_id": "S01", "text": "x"}])
    assert e.transcribe(speech(30), [])["language"] == "English"


class SplittingMoss:
    """Truncated on anything over 150 s (the token cap is hit); one speaker per half otherwise."""

    def generate(self, audio, max_tokens):
        seconds = audio.shape[0] / SR
        if seconds > 150:
            return SimpleNamespace(segments=[{"start": 0.0, "end": 10.0, "speaker_id": "S01", "text": "x"}],
                                   generation_tokens=max_tokens, prompt_tokens=10)  # fmt: skip
        return SimpleNamespace(segments=[{"start": 0.0, "end": seconds - 1, "speaker_id": "S01", "text": "x"}],
                               generation_tokens=100, prompt_tokens=10)  # fmt: skip


def test_the_windows_moss_ran_on_are_reported_with_their_label_prefixes():
    e = Engine()
    e.models = (SplittingMoss(), FakeQwen(), FakeAligner())
    out = e.transcribe(speech(200), [])
    assert out["omi_asr"]["resplits"] == 1
    windows = out["windows"]
    assert [w["label_prefix"] for w in windows] == ["", "W1.2-"]
    assert windows[0]["start"] == 0.0 and windows[-1]["end"] == pytest.approx(200, abs=0.01)
    assert windows[0]["end"] == windows[1]["start"]
    assert {s["speaker_id"] for s in out["segments"]} == {"S01", "W1.2-S01"}


def test_the_self_test_loads_the_models_and_runs_qwen_briefly_without_moss():
    class NoMoss:
        def generate(self, *a, **k):
            raise AssertionError("MOSS runs to its token cap on non-speech: not part of the self-test")

    e, qwen = engine([])
    e.models = (NoMoss(), qwen, FakeAligner())
    e.self_test()
    assert qwen.seconds == [1.0]


class CappingQwen(FakeQwen):
    """Runs into its token cap (a repetition loop) on anything longer than `limit` seconds."""

    def __init__(self, limit):
        super().__init__()
        self.limit = limit

    def generate(self, audio, hotwords=None, max_tokens=0, **_):
        r = super().generate(audio, hotwords, max_tokens)
        if audio.shape[0] / SR > self.limit:
            r.generation_tokens = max_tokens
        return r


def lines_every(seconds, total, label="S01"):
    return [{"start": float(t), "end": float(t) + seconds - 0.5, "speaker_id": label, "text": f"[{t}][{label}] moss{t}"}
            for t in range(0, int(total), int(seconds))]  # fmt: skip


def test_a_capped_qwen_chunk_is_retried_in_halves_before_falling_back():
    e = Engine()
    qwen = CappingQwen(limit=100)
    e.models = (FakeMoss(lines_every(10, 150)), qwen, FakeAligner())
    out = e.transcribe(speech(150), [])
    assert out["omi_asr"]["qwen_capped"] == 0 and out["omi_asr"]["qwen_split"] == 1
    assert "moss" not in out["text"]


def test_lines_under_a_chunk_qwen_cannot_do_keep_mosss_text_even_if_some_units_landed():
    e = Engine()
    e.models = (FakeMoss(lines_every(10, 60)), CappingQwen(limit=0), FakeAligner())
    out = e.transcribe(speech(60), [])
    assert out["omi_asr"]["qwen_capped"] >= 1
    assert [x["text"] for x in out["segments"]] == [f"moss{t}" for t in range(0, 60, 10)]


def test_a_long_line_partly_under_a_failed_span_keeps_mosss_whole_text():
    # one MOSS line over 0-240 s; Qwen fails beyond 180 s (forced chunk cut there), the line's middle is not in it
    class LateCap(FakeQwen):
        def __init__(self):
            super().__init__()
            self.offset = 0.0

        def generate(self, audio, hotwords=None, max_tokens=0, **_):
            r = super().generate(audio, hotwords, max_tokens)
            if audio.shape[0] / SR < 70:  # the 60 s tail and its halves
                r.generation_tokens = max_tokens
            return r

    e = Engine()
    e.models = (FakeMoss([{"start": 0.0, "end": 239.5, "speaker_id": "S01", "text": "[0][S01] whole moss line"}]), LateCap(), FakeAligner())
    out = e.transcribe(speech(240), [])
    assert out["omi_asr"]["qwen_capped"] >= 1
    assert out["segments"][0]["text"] == "whole moss line", "nothing of the failed tail may silently vanish"


def test_words_qwen_could_not_produce_where_moss_has_none_are_an_error_not_silence():
    from omi_asr.engine import IncompleteTranscription

    e = Engine()
    e.models = (FakeMoss([]), CappingQwen(limit=0), FakeAligner())
    with pytest.raises(IncompleteTranscription):
        e.transcribe(speech(30), [])


def test_a_failed_span_only_partly_under_moss_lines_is_incomplete_not_silently_short():
    from omi_asr.engine import IncompleteTranscription

    e = Engine()
    # MOSS covers only the first second of 10 s of speech (one chunk, too short to halve); Qwen fails on it
    e.models = (FakeMoss([{"start": 0.0, "end": 1.0, "speaker_id": "S01", "text": "[0][S01] hi"}]), CappingQwen(limit=0), FakeAligner())
    with pytest.raises(IncompleteTranscription):
        e.transcribe(speech(10), [])


def test_a_short_failed_span_with_no_moss_words_is_still_an_error():
    from omi_asr.engine import IncompleteTranscription

    e = Engine()
    e.models = (FakeMoss([]), CappingQwen(limit=0), FakeAligner())
    with pytest.raises(IncompleteTranscription):
        e.transcribe(speech(0.8), [])


def test_a_failed_tail_just_after_a_line_is_not_covered_by_timing_slack():
    from omi_asr.engine import _check_fallback, IncompleteTranscription

    pcm = speech(181)
    lines = [{"start": 100.0, "end": 180.0, "speaker": "S01", "moss_text": "words"}]
    with pytest.raises(IncompleteTranscription):
        _check_fallback(pcm, [(180.0, 180.8)], lines)
    _check_fallback(pcm, [(100.0, 180.0)], lines)  # a span MOSS words lie over is fine


def test_a_half_that_still_hits_the_cap_is_halved_once_more_before_mosss_gaps_make_it_incomplete():
    # 01a13ccd (2026-11-08 19:27): a 92 s chunk capped, its 46 s half capped again, and MOSS had no words
    # for 14 s there: refused, though Qwen manages the same speech in shorter pieces
    e = Engine()
    e.models = (FakeMoss(lines_every(10, 40)), CappingQwen(limit=35), FakeAligner())  # the cuts fall at pauses: 61 + 31, then 34 + 27
    out = e.transcribe(speech(92), [])
    assert out["omi_asr"]["qwen_capped"] == 0 and out["omi_asr"]["qwen_split"] == 2
    assert "moss" not in out["text"]
