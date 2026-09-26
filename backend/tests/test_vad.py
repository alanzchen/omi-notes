from pathlib import Path

import numpy as np
import pytest

from omi_notes.audio.vad import EnergyVad, SileroVad, VadError, VadStream, make_vad, speech_intervals
from omi_notes.settings import MODELS_DIR

SR = 16000
MODEL = MODELS_DIR / "silero_vad.onnx"


def tone(seconds: float, level: int = 8000) -> np.ndarray:
    t = np.arange(int(round(seconds * SR))) / SR
    return (np.sin(2 * np.pi * 220 * t) * level).astype(np.int16)


def silence(seconds: float) -> np.ndarray:
    return np.zeros(int(round(seconds * SR)), dtype=np.int16)


def flat(intervals):
    return [x for iv in intervals for x in iv]


def test_energy_vad_finds_unpadded_tone_bursts():
    pcm = np.concatenate([silence(2), tone(1), silence(5), tone(2), silence(3)])
    assert flat(speech_intervals(EnergyVad(), pcm, start=1000.0)) == pytest.approx([1002.0, 1003.0, 1008.0, 1010.0])


def test_energy_vad_ignores_silence_and_quiet_noise():
    rng = np.random.default_rng(0)
    assert speech_intervals(EnergyVad(), silence(5), 0.0) == []
    assert speech_intervals(EnergyVad(), rng.normal(0, 30, 5 * SR).astype(np.int16), 0.0) == []


def test_minimum_length_applies_to_whole_segments():
    assert speech_intervals(EnergyVad(), np.concatenate([silence(1), tone(0.2), silence(1)]), 0.0) == []
    stream = VadStream(EnergyVad())
    first = stream.feed(np.concatenate([silence(1), tone(0.2)]), 0.0)  # split at a chunk boundary
    second = stream.feed(np.concatenate([tone(0.2), silence(1)]), 1.2)
    assert first == [] and flat(second + stream.end_run()) == pytest.approx([1.0, 1.4])


def test_split_feeds_match_one_shot_detection():
    pcm = np.concatenate([silence(1.37), tone(0.9), silence(0.5), tone(1.3), silence(2)])
    whole = speech_intervals(EnergyVad(), pcm, 50.0)
    stream = VadStream(EnergyVad())
    parts: list = []
    cut = [0, 12345, 29999, 30001, 51234, len(pcm)]
    for a, b in zip(cut, cut[1:], strict=False):
        parts += stream.feed(pcm[a:b], 50.0 + a / SR)
    parts += stream.end_run()
    assert flat(parts) == pytest.approx(flat(whole))


def test_state_round_trips_mid_segment():
    pcm = np.concatenate([silence(1), tone(2), silence(1)])
    stream = VadStream(EnergyVad())
    stream.feed(pcm[: int(1.7 * SR)], 0.0)
    assert stream.open_segment() == pytest.approx((1.0, 1.7))
    restored = VadStream(EnergyVad(), stream.to_state())
    out = restored.feed(pcm[int(1.7 * SR) :], 1.7) + restored.end_run()
    assert flat(out) == pytest.approx([1.0, 3.0])


def test_discontinuous_feed_ends_the_open_segment():
    stream = VadStream(EnergyVad())
    stream.feed(tone(1), 0.0)
    out = stream.feed(tone(1), 10.0)  # not where the previous piece ended
    assert flat(out) == pytest.approx([0.0, 1.0])


def test_empty_input():
    assert speech_intervals(EnergyVad(), silence(0), 0.0) == []


def test_vad_failure_raises_not_silence():
    class Broken(EnergyVad):
        name = "broken"

        def classify(self, windows, state):
            raise RuntimeError("onnx exploded")

    with pytest.raises(VadError):
        speech_intervals(Broken(), tone(1), 0.0)


def test_missing_model_falls_back_with_warning(tmp_path: Path):
    choice = make_vad("silero", tmp_path / "nope.onnx", 0.5)
    assert choice.vad.name == "energy" and "fetch-models" in (choice.warning or "")
    assert make_vad("energy", tmp_path / "nope.onnx", 0.5).warning is None


@pytest.mark.skipif(not MODEL.exists(), reason="Silero model not downloaded (omi-notes fetch-models)")
def test_silero_rejects_silence_tone_and_noise():
    vad = SileroVad(MODEL)
    rng = np.random.default_rng(1)
    for pcm in (silence(3), tone(3), rng.normal(0, 2000, 3 * SR).astype(np.int16)):
        assert speech_intervals(vad, pcm, 0.0) == []
    probs = vad.probabilities(silence(1))
    assert probs.shape == (32,) and float(probs.max()) < 0.5  # 16000 / 512 windows, zero padded


@pytest.mark.skipif(not MODEL.exists(), reason="Silero model not downloaded (omi-notes fetch-models)")
def test_silero_state_survives_serialization():
    vad = SileroVad(MODEL)
    rng = np.random.default_rng(2)
    pcm = rng.normal(0, 500, 4 * SR).astype(np.int16)
    one = VadStream(vad)
    one.feed(pcm, 0.0)
    split = VadStream(vad)
    split.feed(pcm[: 2 * SR + 100], 0.0)
    restored = VadStream(vad, split.to_state())
    restored.feed(pcm[2 * SR + 100 :], (2 * SR + 100) / SR)
    assert restored.model_state == one.model_state
