"""Local speaker diarization with sherpa-onnx (ONNX Runtime, no torch).

Optional: `uv sync --extra diarization` installs sherpa-onnx, `omi-notes fetch-models
--diarization` downloads the models (pyannote segmentation-3.0, MIT; NeMo TitaNet-small speaker
embeddings, CC-BY-4.0). It runs on exactly the PCM that was sent for transcription, so its turns
share the provider's clock, and `assign_speakers` then labels (and where needed splits) the
provider's utterances. sherpa-onnx's real-time factor is ~0.05-0.12 on Apple Silicon.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

import numpy as np

log = logging.getLogger(__name__)

SAMPLE_RATE = 16000


@dataclass(frozen=True)
class ModelFile:
    url: str
    sha256: str  # of the download
    target: str  # file name under the models directory
    member: str | None = None  # file to extract when the download is an archive
    member_sha256: str | None = None


RELEASES = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
SEGMENTATION = ModelFile(
    url=f"{RELEASES}/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
    sha256="24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488",
    target="pyannote-segmentation-3-0.onnx",
    member="sherpa-onnx-pyannote-segmentation-3-0/model.onnx",
    member_sha256="220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
)
EMBEDDING = ModelFile(
    url=f"{RELEASES}/speaker-recongition-models/nemo_en_titanet_small.onnx",  # sic: the release tag's spelling
    sha256="ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e",
    target="nemo_en_titanet_small.onnx",
)
INSTALL_HINT = "`uv sync --extra diarization && uv run omi-notes fetch-models --diarization`"


@dataclass(frozen=True)
class Turn:
    start: float
    end: float
    speaker: int


def local_diarization_status(segmentation: Path, embedding: Path) -> str | None:
    """None when local diarization can run, otherwise what is missing (and how to fix it)."""
    try:
        import sherpa_onnx  # noqa: F401
    except ImportError as exc:
        return f"sherpa-onnx is not installed ({exc}); run {INSTALL_HINT}"
    missing = [str(p) for p in (segmentation, embedding) if not p.exists()]
    if missing:
        return f"diarization models missing ({', '.join(missing)}); run `uv run omi-notes fetch-models --diarization`"
    return None


class LocalDiarizer:
    def __init__(
        self,
        segmentation: Path,
        embedding: Path,
        *,
        num_speakers: int = 0,
        threshold: float = 0.5,
        num_threads: int = 4,
    ) -> None:
        import sherpa_onnx

        config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
            segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
                pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(segmentation)),
                num_threads=num_threads,
                provider="cpu",
            ),
            embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(embedding), num_threads=num_threads),
            # num_clusters > 0 fixes the speaker count (threshold ignored); otherwise the threshold
            # decides: smaller means more speakers.
            clustering=sherpa_onnx.FastClusteringConfig(num_clusters=num_speakers or -1, threshold=threshold),
            min_duration_on=0.3,
            min_duration_off=0.5,
        )
        if not config.validate():
            raise RuntimeError("invalid sherpa-onnx diarization configuration (check the model files)")
        self._engine = sherpa_onnx.OfflineSpeakerDiarization(config)
        if self._engine.sample_rate != SAMPLE_RATE:
            raise RuntimeError(f"diarization expects {self._engine.sample_rate} Hz audio")
        # Part of the cache key: different models or clustering give different turns.
        self.tag = f"sherpa-{segmentation.stem}-{embedding.stem}-n{num_speakers}-t{threshold:g}"

    def diarize(self, pcm: np.ndarray) -> list[Turn]:
        samples = pcm.astype(np.float32) / 32768.0
        result = self._engine.process(samples).sort_by_start_time()
        return [Turn(float(s.start), float(s.end), int(s.speaker)) for s in result]


# -- assignment (pure) -----------------------------------------------------------------------------


def _overlap(a: float, b: float, turn: Turn) -> float:
    return max(0.0, min(b, turn.end) - max(a, turn.start))


def _nearest(t: float, turns: list[Turn]) -> int:
    return min(turns, key=lambda turn: 0.0 if turn.start <= t <= turn.end else min(abs(t - turn.start), abs(t - turn.end))).speaker


def _word_speaker(a: float, b: float, turns: list[Turn]) -> int:
    middle = (a + b) / 2
    for turn in turns:
        if turn.start <= middle < turn.end:
            return turn.speaker
    best = max(turns, key=lambda turn: _overlap(a, b, turn))
    return best.speaker if _overlap(a, b, best) > 0 else _nearest(middle, turns)


def _span_speaker(a: float, b: float, turns: list[Turn]) -> int:
    totals: dict[int, float] = {}
    for turn in turns:
        totals[turn.speaker] = totals.get(turn.speaker, 0.0) + _overlap(a, b, turn)
    speaker, amount = max(totals.items(), key=lambda item: item[1])
    return speaker if amount > 0 else _nearest((a + b) / 2, turns)


def assign_speakers(utterances: list[dict], turns: list[Turn]) -> list[dict]:
    """Label utterances with local diarization turns (all in the same audio clock).

    With word timestamps each word goes to the turn holding its midpoint (else the one it overlaps
    most, else the nearest), and an utterance is split wherever the speaker changes. Without words
    the whole utterance goes to the speaker it overlaps most. No turns at all means one speaker.
    """
    if not turns:
        return [dict(u, speaker=0) for u in utterances]
    out: list[dict] = []
    for utt in utterances:
        words = [w for w in utt.get("words") or [] if w.get("start") is not None and w.get("end") is not None]
        if not words:
            out.append(dict(utt, speaker=_span_speaker(utt["start"], utt["end"], turns)))
            continue
        runs: list[tuple[int, list[dict]]] = []
        for w in words:
            speaker = _word_speaker(w["start"], w["end"], turns)
            if runs and runs[-1][0] == speaker:
                runs[-1][1].append(w)
            else:
                runs.append((speaker, [w]))
        for speaker, run in runs:
            piece = {
                "start": run[0]["start"],
                "end": run[-1]["end"],
                "transcript": " ".join(str(w.get("punctuated_word") or w.get("word") or "") for w in run).strip(),
                "speaker": speaker,
                "words": [dict(w, speaker=speaker) for w in run],
            }
            if utt.get("confidence") is not None:
                piece["confidence"] = utt["confidence"]
            out.append(piece)
    return out
