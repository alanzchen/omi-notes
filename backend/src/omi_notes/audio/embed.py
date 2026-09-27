"""Speaker embeddings for recognizing people across conversations (docs/speaker-learning.md).

WeSpeaker ResNet34 (`wespeaker_en_voxceleb_resnet34_LM.onnx`, CC-BY-4.0, 256-dim) through
sherpa-onnx's `SpeakerEmbeddingExtractor` — the architecture Omi calibrated its operating points
on. It is installed like local diarization (`uv sync --extra diarization`, then
`omi-notes fetch-models --speakers`). TitaNet stays the diarization embedding.

Every vector records the model name and file sha; vectors from different models are never
compared. Embeddings are computed locally and never sent to a provider.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Protocol

import numpy as np

from .diarize import RELEASES, ModelFile

SAMPLE_RATE = 16000
SPEAKER_MODEL = ModelFile(
    url=f"{RELEASES}/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx",  # sic: the tag's spelling
    sha256="e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012",
    target="wespeaker_en_voxceleb_resnet34_LM.onnx",
)
SPEAKERS_HINT = "`uv sync --extra diarization && uv run omi-notes fetch-models --speakers`"


class Embedder(Protocol):
    model: str  # e.g. "wespeaker_en_voxceleb_resnet34_LM"
    model_sha: str
    dim: int

    def embed(self, pcm: np.ndarray) -> np.ndarray:
        """16 kHz int16 PCM → L2-normalized float32 vector."""
        ...


def normalized(vector: np.ndarray) -> np.ndarray:
    v = np.asarray(vector, dtype=np.float32)
    norm = float(np.linalg.norm(v))
    return v / norm if norm > 0 else v


def speaker_embedding_status(model: Path) -> str | None:
    """None when speaker recognition can run, otherwise what is missing (and how to fix it)."""
    try:
        import sherpa_onnx  # noqa: F401
    except ImportError as exc:
        return f"sherpa-onnx is not installed ({exc}); run {SPEAKERS_HINT}"
    if not model.exists():
        return f"speaker model missing ({model}); run `uv run omi-notes fetch-models --speakers`"
    return None


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


class SherpaEmbedder:
    def __init__(self, model: Path, *, num_threads: int = 2) -> None:
        import sherpa_onnx

        config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(model), num_threads=num_threads, provider="cpu")
        if not config.validate():
            raise RuntimeError(f"invalid speaker embedding model {model}")
        self._extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
        self.model = model.stem
        self.model_sha = file_sha256(model)
        self.dim = int(self._extractor.dim)

    def embed(self, pcm: np.ndarray) -> np.ndarray:
        stream = self._extractor.create_stream()
        stream.accept_waveform(SAMPLE_RATE, (np.asarray(pcm, dtype=np.float32) / 32768.0))
        stream.input_finished()
        if not self._extractor.is_ready(stream):
            raise ValueError("clip too short for a speaker embedding")
        return normalized(np.array(self._extractor.compute(stream), dtype=np.float32))
