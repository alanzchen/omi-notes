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
    """Spreads the words evenly over the chunk, nearly touching (as words of continuous speech are)."""

    def generate(self, chunk, text, language):
        words, seconds = text.split(), len(chunk) / SR
        step = seconds / max(len(words), 1)
        return SimpleNamespace(items=[SimpleNamespace(text=w, start_time=i * step, end_time=(i + 0.9) * step)
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


def test_a_quarter_that_still_hits_the_cap_is_halved_again_down_to_twenty_seconds():
    # 01a13ccd again (2026-11-09 00:25): the 46 s span's 29 s quarter still looped; MOSS lacked 8 s there
    e = Engine()
    e.models = (FakeMoss(lines_every(10, 40)), CappingQwen(limit=20), FakeAligner())
    out = e.transcribe(speech(92), [])
    assert out["omi_asr"]["qwen_capped"] == 0
    assert "moss" not in out["text"]


def test_the_smallest_piece_is_tried_once_without_the_context_before_mosss_text():
    class LoopsWithContext(FakeQwen):  # a hotword prompt can set off the repetition loop
        def generate(self, audio, hotwords=None, max_tokens=0, **_):
            r = super().generate(audio, hotwords, max_tokens)
            if hotwords:
                r.generation_tokens = max_tokens
            return r

    e = Engine()
    e.models = (FakeMoss([]), LoopsWithContext(), FakeAligner())
    out = e.transcribe(speech(15), ["Freedom"])
    assert out["omi_asr"]["qwen_capped"] == 0 and out["omi_asr"]["qwen_without_context"] == 1


def test_an_empty_answer_from_the_context_free_retry_is_still_incomplete_not_silence():
    # Astra IT1-01: the retry came back short of the cap but with no words; with no MOSS words there, the
    # span's speech vanished as an empty success instead of IncompleteTranscription
    from omi_asr.engine import IncompleteTranscription

    class EmptyWithoutContext(FakeQwen):
        def generate(self, audio, hotwords=None, max_tokens=0, **_):
            r = super().generate(audio, hotwords, max_tokens)
            if hotwords:
                r.generation_tokens = max_tokens
            else:
                r.text, r.generation_tokens = "  ", 1
            return r

    e = Engine()
    e.models = (FakeMoss([]), EmptyWithoutContext(), FakeAligner())
    with pytest.raises(IncompleteTranscription):
        e.transcribe(speech(15), ["Freedom"])


def test_an_empty_context_free_retry_under_moss_words_keeps_mosss_text():
    class EmptyWithoutContext(FakeQwen):
        def generate(self, audio, hotwords=None, max_tokens=0, **_):
            r = super().generate(audio, hotwords, max_tokens)
            if hotwords:
                r.generation_tokens = max_tokens
            else:
                r.text, r.generation_tokens = "", 0
            return r

    e = Engine()
    e.models = (FakeMoss(lines_every(5, 15)), EmptyWithoutContext(), FakeAligner())
    out = e.transcribe(speech(15), ["Freedom"])
    assert out["omi_asr"]["qwen_capped"] == 1 and [s["text"] for s in out["segments"]] == ["moss0", "moss5", "moss10"]


class NoAlignment(FakeAligner):
    """Aligns nothing (mlx-audio 0.6.3 gives no items for a punctuation-only text such as "…?!")."""

    def generate(self, chunk, text, language):
        return SimpleNamespace(items=[])


class PunctuationWithoutContext(FakeQwen):
    def generate(self, audio, hotwords=None, max_tokens=0, **_):
        r = super().generate(audio, hotwords, max_tokens)
        if hotwords:
            r.generation_tokens = max_tokens
        else:
            r.text, r.generation_tokens = "…?!", 3
        return r


@pytest.mark.parametrize("moss", [[], [{"start": 0.0, "end": 3.0, "speaker_id": "S01", "text": "[0][S01] first three seconds"}]],
                         ids=["no-moss", "moss-0-3s"])
def test_a_retry_that_aligns_to_nothing_is_still_a_failed_piece(moss):
    # Astra IT2-01: a nonempty retry counted as recovered before alignment; with no items the 15 s span vanished
    from omi_asr.engine import IncompleteTranscription

    e = Engine()
    e.models = (FakeMoss(moss), PunctuationWithoutContext(), NoAlignment())
    with pytest.raises(IncompleteTranscription):
        e.transcribe(speech(15), ["Freedom"])


def test_a_retry_that_aligns_to_nothing_under_full_moss_words_keeps_mosss_text():
    e = Engine()
    e.models = (FakeMoss(lines_every(5, 15)), PunctuationWithoutContext(), NoAlignment())
    out = e.transcribe(speech(15), ["Freedom"])
    assert out["omi_asr"]["qwen_unaligned"] == 1 and [s["text"] for s in out["segments"]] == ["moss0", "moss5", "moss10"]


def test_a_first_answer_that_aligns_to_nothing_is_a_failed_piece_too():
    from omi_asr.engine import IncompleteTranscription

    e = Engine()
    e.models = (FakeMoss([]), FakeQwen(), NoAlignment())
    with pytest.raises(IncompleteTranscription):
        e.transcribe(speech(15), [])


def test_a_moss_loop_on_a_short_window_stops_at_its_small_cap_and_still_fails_honestly():
    # 2026-11-09 20:08 (01a1c313, 7.3 s): MOSS looped to 16,384 tokens, then Qwen hit its cap: an honest 422,
    # but after 97 s of GPU. The loop now stops at the short-window cap; the outcome is the same.
    from omi_asr.engine import IncompleteTranscription

    class LoopingMoss(FakeMoss):
        def __init__(self):
            super().__init__([])
            self.caps = []

        def generate(self, audio, max_tokens=0, **_):
            self.caps.append(max_tokens)
            return SimpleNamespace(segments=[], generation_tokens=max_tokens)

    moss = LoopingMoss()
    e = Engine()
    e.models = (moss, CappingQwen(limit=0), FakeAligner())
    with pytest.raises(IncompleteTranscription):
        e.transcribe(speech(7.3), [])
    assert moss.caps and max(moss.caps) <= 1024


class DenseMoss(FakeMoss):
    """Two speakers trading a reply every `step` s over the window, each reply costing `cost` tokens (the real
    tokenizer gives ~18 for "[0.40][S02]Yes.[0.80]": timestamps go digit by digit). Stops at the cap with only
    the replies it finished, as a capped generation does."""

    def __init__(self, step=0.4, cost=18):
        super().__init__([])
        self.step, self.cost, self.caps = step, cost, []

    def generate(self, audio, max_tokens=0, **_):
        self.caps.append(max_tokens)
        n = round(audio.shape[0] / SR / self.step)
        done = min(n, max_tokens // self.cost)
        lines = [{"start": round(i * self.step, 2), "end": round((i + 1) * self.step, 2), "speaker_id": f"S0{i % 2 + 1}",
                  "text": f"[{i * self.step:.2f}][S0{i % 2 + 1}] r{i}"} for i in range(done)]  # fmt: skip
        return SimpleNamespace(segments=lines, generation_tokens=min(n * self.cost, max_tokens))


def test_a_dense_short_window_that_hits_the_short_cap_is_tried_again_and_keeps_every_reply():
    # nightly review 2026-11-10 (IT1-01): 75 replies in 30 s are ~1,345 real tokens, over the 1,200 short cap;
    # with Qwen also capped, MOSS's prefix passed fallback and 67 of 75 replies came back as a 200
    moss = DenseMoss()
    e = Engine()
    e.models = (moss, CappingQwen(limit=0), FakeAligner())
    out = e.transcribe(speech(30), [])
    assert moss.caps == [1200, 4800]
    assert out["omi_asr"]["moss_retries"] == 1 and out["omi_asr"]["truncated_unresolved"] == 0
    assert [s["text"] for s in out["segments"]] == [f"r{i}" for i in range(75)]


def test_a_window_still_capped_after_its_retry_with_qwen_failing_on_the_tail_is_incomplete_not_shortened():
    from omi_asr.engine import IncompleteTranscription

    moss = DenseMoss(cost=70)  # 75 replies need 5,250 tokens: past the 4,800 retry too; MOSS stops at 68 (27.2 s)
    e = Engine()
    e.models = (moss, CappingQwen(limit=0), FakeAligner())
    with pytest.raises(IncompleteTranscription):
        e.transcribe(speech(30), [])
    assert moss.caps == [1200, 4800]


def test_a_window_still_capped_after_its_retry_keeps_qwen_s_tail_when_qwen_manages():
    e = Engine()
    e.models = (DenseMoss(cost=70), FakeQwen(), FakeAligner())
    out = e.transcribe(speech(30), [])
    assert out["omi_asr"]["truncated_unresolved"] == 1
    assert any(s["speaker_id"] == "UNKNOWN" and s["end"] >= 29 for s in out["segments"])


def test_the_dense_window_over_http_is_complete_or_422_and_health_stays_up():
    import io

    import soundfile as sf
    from fastapi.testclient import TestClient

    from omi_asr import server

    buf = io.BytesIO()
    sf.write(buf, speech(30), SR, format="FLAC", subtype="PCM_16")
    for cost, status in ((18, 200), (70, 422)):
        e = Engine()
        e.models = (DenseMoss(cost=cost), CappingQwen(limit=0), FakeAligner())
        client = TestClient(server.create_app(e, exit=lambda _: pytest.fail("unexpected watchdog exit")))
        r = client.post("/v1/audio/transcriptions", files={"file": ("a.flac", buf.getvalue(), "audio/flac")})
        assert r.status_code == status
        if status == 200:
            assert len(r.json()["segments"]) == 75
        assert client.get("/health").status_code == 200


class PrefixMoss(DenseMoss):
    """Astra's IT3 counterexamples (nightly-2026-11-10-it3, test_repair_edges.py): a greedy decoder gives the same
    67 replies (to 26.8 s) on every try, then an unfinished segment that loops for `loop` tokens; a try with a
    larger cap than that ends on its own, still without a reply after 26.8 s."""

    def __init__(self, loop):
        super().__init__()
        self.loop = loop

    def generate(self, audio, max_tokens=0, **_):
        self.caps.append(max_tokens)
        full = 67 * self.cost + self.loop
        lines = [{"start": round(i * self.step, 2), "end": round((i + 1) * self.step, 2), "speaker_id": f"S0{i % 2 + 1}",
                  "text": f"[{i * self.step:.2f}][S0{i % 2 + 1}] r{i}"} for i in range(min(67, max_tokens // self.cost))]  # fmt: skip
        return SimpleNamespace(segments=lines, generation_tokens=min(full, max_tokens))


def test_a_retry_that_ends_below_its_cap_still_has_its_unworded_tail_checked():
    # ASTRA-20261110-IT3-01: 1200/1200, then 2006/4800 with the same 67 replies; Qwen fails throughout. The
    # retry's normal stop erased the cap hit and the 3.2 s tail passed the 25% allowance: a 200 ending at 26.8 s
    from omi_asr.engine import IncompleteTranscription

    moss = PrefixMoss(loop=800)
    e = Engine()
    e.models = (moss, CappingQwen(limit=0), FakeAligner())
    with pytest.raises(IncompleteTranscription):
        e.transcribe(speech(30), [])
    assert moss.caps == [1200, 4800]


class OneWordQwen(FakeQwen):
    def generate(self, audio, hotwords=None, max_tokens=0, **_):
        return SimpleNamespace(text="tailword", generation_tokens=2, language=["English"])


class AtAligner:
    def generate(self, chunk, text, language):
        return SimpleNamespace(items=[SimpleNamespace(text=text, start_time=27.0, end_time=28.0)])


def test_qwen_wording_only_part_of_a_capped_tail_does_not_make_the_window_complete():
    # ASTRA-20261110-IT3-02: both MOSS tries capped at 26.8 s; Qwen aligns one word at 27-28 s and nothing up to
    # 30 s, without being marked failed: a 200 ending at 28 s
    from omi_asr.engine import IncompleteTranscription

    e = Engine()
    e.models = (PrefixMoss(loop=6000), OneWordQwen(), AtAligner())
    with pytest.raises(IncompleteTranscription):
        e.transcribe(speech(30), [])


def test_a_capped_window_with_a_silent_tail_still_passes():
    samples = speech(30)
    samples[round(26.8 * SR) :] = 0.0
    e = Engine()
    e.models = (PrefixMoss(loop=6000), CappingQwen(limit=0), FakeAligner())
    out = e.transcribe(samples, [])
    assert len(out["segments"]) == 67 and out["omi_asr"]["truncated_unresolved"] == 1


def test_a_retry_that_completes_the_window_is_counted_and_returns_every_reply_with_a_good_qwen():
    moss = DenseMoss()
    e = Engine()
    e.models = (moss, FakeQwen(), FakeAligner())
    out = e.transcribe(speech(30), [])
    assert moss.caps == [1200, 4800] and out["omi_asr"]["capped_then_complete"] == 1
    assert max(s["end"] for s in out["segments"]) >= 29.5


class PlacedQwen(FakeQwen):
    def __init__(self, positions):
        super().__init__()
        self.positions = positions

    def generate(self, audio, hotwords=None, max_tokens=0, **_):
        return SimpleNamespace(text=" ".join(f"word{i}" for i in range(len(self.positions))), generation_tokens=8, language=["English"])


class PlacedAligner:
    def __init__(self, positions):
        self.positions = positions

    def generate(self, chunk, text, language):
        return SimpleNamespace(items=[SimpleNamespace(text=w, start_time=a, end_time=b) for w, (a, b) in zip(text.split(), self.positions, strict=True)])


def test_chained_short_holes_in_a_capped_tail_add_up_and_make_it_incomplete():
    # ASTRA-20261110-IT3FIX-01: three 0.1 s words at 27.6, 28.6 and 29.6 s after MOSS's last line at 26.8 s; each hole
    # is under 1 s, so bridging them certified 1.5 s of speech without a word (a 200)
    from omi_asr.engine import IncompleteTranscription

    positions = [(27.6, 27.7), (28.6, 28.7), (29.6, 29.7)]
    e = Engine()
    e.models = (PrefixMoss(loop=6000), PlacedQwen(positions), PlacedAligner(positions))
    with pytest.raises(IncompleteTranscription):
        e.transcribe(np.full(30 * SR, 0.1, np.float32), [])


def test_quiet_pauses_between_the_words_of_a_capped_tail_need_no_words():
    positions = [(27.6, 27.7), (28.6, 28.7), (29.6, 29.7)]
    samples = np.full(30 * SR, 0.1, np.float32)
    samples[round(26.8 * SR) :] = 0.0
    for a, b in positions:
        samples[round(a * SR) : round(b * SR)] = 0.1
    e = Engine()
    e.models = (PrefixMoss(loop=6000), PlacedQwen(positions), PlacedAligner(positions))
    out = e.transcribe(samples, [])
    assert out["omi_asr"]["truncated_unresolved"] == 1
    assert [s["speaker_id"] for s in out["segments"]][-1] == "UNKNOWN" and max(s["end"] for s in out["segments"]) >= 29.6
