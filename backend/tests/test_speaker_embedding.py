"""Opt-in: WeSpeaker embeddings (sherpa-onnx) of macOS `say` voices — same voice vs different voices."""

from __future__ import annotations

import shutil
import subprocess
from itertools import combinations

import numpy as np
import pytest
import soundfile as sf

from omi_notes.audio.embed import SherpaEmbedder, speaker_embedding_status
from omi_notes.settings import MODELS_DIR
from omi_notes.speakers.match import build_models, match
from omi_notes.speakers.voices import Clip, cosine_distance, embed_voices

MODEL = MODELS_DIR / "wespeaker_en_voxceleb_resnet34_LM.onnx"
SENTENCES = [
    "I finished the pairing screen yesterday, but the offline sync still needs testing on a real phone.",
    "Let's aim to test offline sync on Thursday and send the battery numbers by Friday afternoon.",
    "Remind me to order a replacement charging cable for the pendant before the weekend.",
    "The dentist appointment moved to Monday at nine thirty, so I will leave a little earlier.",
]


def say(tmp_path, voice: str, text: str, name: str) -> np.ndarray:
    path = tmp_path / f"{name}.wav"
    subprocess.run(["say", "-v", voice, "-o", str(path), "--file-format=WAVE", "--data-format=LEI16@16000", text],
                   check=True, capture_output=True)  # fmt: skip
    pcm, rate = sf.read(path, dtype="int16")
    assert rate == 16000
    return np.asarray(pcm, dtype=np.int16)


@pytest.mark.skipif(
    speaker_embedding_status(MODEL) is not None or shutil.which("say") is None,
    reason="opt-in: needs `uv sync --extra diarization`, `omi-notes fetch-models --speakers` and macOS `say`",
)
def test_wespeaker_puts_the_same_synthetic_voice_closer_than_another(tmp_path):
    embedder = SherpaEmbedder(MODEL)
    assert embedder.dim == 256
    voices = {name: [say(tmp_path, name, text, f"{name}{i}") for i, text in enumerate(SENTENCES)]
              for name in ("Samantha", "Daniel")}  # fmt: skip
    vectors = {name: [embedder.embed(pcm) for pcm in clips] for name, clips in voices.items()}
    same = [cosine_distance(a, b) for vs in vectors.values() for a, b in combinations(vs, 2)]
    different = [cosine_distance(a, b) for a in vectors["Samantha"] for b in vectors["Daniel"]]
    print(f"\nWeSpeaker ResNet34 on `say` voices: same voice {min(same):.3f}-{max(same):.3f} (mean {np.mean(same):.3f}); "
          f"different voices {min(different):.3f}-{max(different):.3f} (mean {np.mean(different):.3f})")  # fmt: skip
    assert max(same) < min(different)

    # End to end through the pure matching: three sentences enroll each voice, the fourth is recognized.
    from omi_notes.speakers.match import Sample

    samples = [Sample(f"{name}-{i}", name, v, "user", f"2026-09-2{i}", f"s{i}", float(i))
               for name, vs in vectors.items() for i, v in enumerate(vs[:3])]  # fmt: skip
    models = build_models(samples)
    for name, clips in voices.items():
        pcm = np.concatenate([clips[3], np.zeros(8000, np.int16), clips[3]])
        half = len(clips[3]) / 16000
        (label_voice,) = embed_voices({"S1": [Clip(0.0, half, 0), Clip(half + 0.5, 2 * half + 0.5, 1)]}, pcm,
                                      embedder).values()  # fmt: skip
        found = match(label_voice, models)
        print(f"{name}: → {found.person_id} distance {found.distance} margin {found.margin} ({found.reason or 'accepted'})")
        assert found.person_id == name
