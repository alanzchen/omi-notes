"""Local diarization: the pure utterance/turn assignment, plus an opt-in sherpa-onnx run."""

from __future__ import annotations

import shutil
import subprocess
import time

import pytest
import soundfile as sf

from omi_notes.audio.diarize import LocalDiarizer, Turn, assign_speakers, local_diarization_status
from omi_notes.settings import MODELS_DIR

TURNS = [Turn(0.0, 2.0, 0), Turn(2.0, 5.0, 1), Turn(6.0, 8.0, 0)]


def word(text, start, end):
    return {"word": text.lower().strip(".,"), "punctuated_word": text, "start": start, "end": end}


def speakers(utts):
    return [(u["speaker"], u["transcript"], u["start"], u["end"]) for u in utts]


@pytest.mark.parametrize(
    "utterance, expected",
    [
        pytest.param(
            {"start": 0.1, "end": 4.0, "transcript": "Hi there. Hello you.", "speaker": 7,
             "words": [word("Hi", 0.1, 0.5), word("there.", 0.6, 1.9), word("Hello", 2.1, 2.6), word("you.", 2.7, 4.0)]},
            [(0, "Hi there.", 0.1, 1.9), (1, "Hello you.", 2.1, 4.0)],
            id="split at the speaker change using word times",
        ),
        pytest.param(
            {"start": 1.7, "end": 2.9, "transcript": "Straddling words", "speaker": None,
             "words": [word("Straddling", 1.7, 2.5), word("words", 2.5, 2.9)]},
            [(1, "Straddling words", 1.7, 2.9)],
            id="a word goes to the turn holding its midpoint",
        ),
        pytest.param(
            {"start": 5.4, "end": 5.9, "transcript": "Gap.", "words": [word("Gap.", 5.4, 5.9)]},
            [(0, "Gap.", 5.4, 5.9)],
            id="a word between turns goes to the nearest turn",
        ),
        pytest.param(
            {"start": 1.0, "end": 4.5, "transcript": "No word timing"},
            [(1, "No word timing", 1.0, 4.5)],
            id="without words: the speaker with most overlap",
        ),
        pytest.param(
            {"start": 9.0, "end": 9.5, "transcript": "After everything"},
            [(0, "After everything", 9.0, 9.5)],
            id="no overlap at all: the nearest turn",
        ),
    ],
)  # fmt: skip
def test_assign_speakers(utterance, expected):
    assert speakers(assign_speakers([utterance], TURNS)) == expected


def test_words_keep_their_timing_and_confidence_carries_over():
    utt = {"start": 0.1, "end": 4.0, "transcript": "x", "confidence": 0.9,
           "words": [word("Hi", 0.1, 0.5), word("Hello", 2.1, 2.6)]}  # fmt: skip
    out = assign_speakers([utt], TURNS)
    assert [w["start"] for u in out for w in u["words"]] == [0.1, 2.1]
    assert all(u["confidence"] == 0.9 for u in out)


def test_no_turns_means_one_speaker():
    assert speakers(assign_speakers([{"start": 0, "end": 1, "transcript": "a"}], [])) == [(0, "a", 0, 1)]


def test_status_explains_what_is_missing(tmp_path):
    reason = local_diarization_status(tmp_path / "seg.onnx", tmp_path / "emb.onnx")
    assert reason is not None and ("sherpa-onnx" in reason or "fetch-models --diarization" in reason)


SEGMENTATION = MODELS_DIR / "pyannote-segmentation-3-0.onnx"
EMBEDDING = MODELS_DIR / "nemo_en_titanet_small.onnx"


@pytest.mark.skipif(
    local_diarization_status(SEGMENTATION, EMBEDDING) is not None or shutil.which("say") is None,
    reason="opt-in: needs `uv sync --extra diarization`, `omi-notes fetch-models --diarization` and macOS `say`",
)
def test_sherpa_onnx_separates_the_two_synth_voices(tmp_path):
    wav = tmp_path / "synth.wav"
    subprocess.run(["uv", "run", "omi-notes", "synth-wav", str(wav), "--pause", "5"], check=True, capture_output=True)
    pcm, rate = sf.read(wav, dtype="int16")
    assert rate == 16000
    started = time.monotonic()
    turns = LocalDiarizer(SEGMENTATION, EMBEDDING).diarize(pcm)
    elapsed = time.monotonic() - started
    print(f"\nsherpa-onnx: {len({t.speaker for t in turns})} speakers, {len(turns)} turns, "
          f"{len(pcm) / rate:.1f} s audio in {elapsed:.2f} s")  # fmt: skip
    assert len({t.speaker for t in turns}) >= 2
