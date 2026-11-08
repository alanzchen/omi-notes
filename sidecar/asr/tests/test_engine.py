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
    assert out["segments"][-1]["end"] >= 55, "the line holding the late words covers them"
    assert out["omi_asr"]["truncated_unresolved"] == 1


def test_a_window_where_moss_found_no_lines_keeps_qwens_text_under_one_flagged_label():
    e, _ = engine([])
    out = e.transcribe(speech(30), [])
    assert len(out["text"].split()) == 15
    assert len({s["speaker_id"] for s in out["segments"]}) == 1
    assert out["omi_asr"]["unlabeled_windows"] == 1


def test_the_language_is_a_plain_name_even_though_qwen_reports_a_list():
    e, _ = engine([{"start": 0.0, "end": 30.0, "speaker_id": "S01", "text": "x"}])
    assert e.transcribe(speech(30), [])["language"] == "English"
