"""Per-label voiceprints for one conversation (pure; docs/speaker-learning.md, "Model and voices").

Clips come from each speaker label's turns on the submitted-audio clock (the provider's or local
diarization's utterances, *before* same-speaker merging): turns of at least 1.5 s that don't
overlap another label (±0.25 s), cut to the speech blocks (never the 0.5 s spacers) minus known
losses (concealed audio), trimmed 0.25 s at each end; longest first, up to 30 s in clips of at
most 10 s (cf. Omi `backend/utils/stt/sync_speaker_evidence.py`). A label's voice is the
duration-weighted mean of its normalized clip embeddings, normalized; its spread is the largest
cosine distance between two of its clips, and it is "mixed" (two people under one label) when the
spread exceeds 0.6.
"""

from __future__ import annotations

import base64
import math
from dataclasses import dataclass, field

import numpy as np

from ..pipeline.segmenter import Interval, intersect, subtract, union

SAMPLE_RATE = 16000
MIN_TURN = 1.5
OVERLAP_GUARD = 0.25
TRIM = 0.25
MAX_CLIP = 10.0
MAX_TOTAL = 30.0
MIXED_SPREAD = 0.6


@dataclass(frozen=True)
class Clip:
    start: float  # submitted-audio seconds
    end: float
    turn: int  # index of the turn it was cut from

    @property
    def seconds(self) -> float:
        return self.end - self.start


@dataclass
class LabelVoice:
    label: str
    clips: list[Clip]
    vector: np.ndarray | None = None
    spread: float = 0.0
    rms_db: float | None = None
    clip_vectors: list[np.ndarray] = field(default_factory=list, repr=False)

    @property
    def seconds(self) -> float:
        return round(sum(c.seconds for c in self.clips), 3)

    @property
    def turns(self) -> int:
        return len({c.turn for c in self.clips})

    @property
    def mixed(self) -> bool:
        return self.spread > MIXED_SPREAD


def label_turns(response: dict) -> dict[str, list[Interval]]:
    """Each label's utterance spans (submitted-audio seconds), labels numbered S1, S2… by first
    appearance exactly as `transcript.segments_from_deepgram` numbers them."""
    utterances = (response.get("results") or {}).get("utterances") or []
    labels: dict[object, str] = {}
    turns: dict[str, list[Interval]] = {}
    for utt in sorted(utterances, key=lambda u: float(u.get("start", 0))):
        if not str(utt.get("transcript", "")).strip():
            continue
        speaker = utt.get("speaker", 0)
        if speaker not in labels:
            labels[speaker] = f"S{len(labels) + 1}"
        start, end = float(utt.get("start", 0)), float(utt.get("end", 0))
        if end > start:
            turns.setdefault(labels[speaker], []).append((start, end))
    return turns


def select_clips(turns: dict[str, list[Interval]], usable: list[Interval]) -> dict[str, list[Clip]]:
    """Clean clips per label (see module docstring)."""
    out: dict[str, list[Clip]] = {}
    for label, spans in turns.items():
        others = union([(a - OVERLAP_GUARD, b + OVERLAP_GUARD) for other, s in turns.items() if other != label for a, b in s])
        pieces: list[tuple[float, int, float, float]] = []
        for index, (a, b) in enumerate(spans):
            if intersect([(a, b)], others):
                continue  # overlaps another speaker: not clean
            for x, y in intersect([(a, b)], usable):
                if y - x >= MIN_TURN:
                    pieces.append((y - x, index, x + TRIM, y - TRIM))
        pieces.sort(key=lambda p: (-p[0], p[2]))
        clips: list[Clip] = []
        total = 0.0
        for _, index, x, y in pieces:
            t = x
            while t < y - 1e-6 and total < MAX_TOTAL - 1e-6:
                end = min(y, t + MAX_CLIP, t + (MAX_TOTAL - total))
                clips.append(Clip(round(t, 3), round(end, 3), index))
                total += end - t
                t = end
        if clips:
            out[label] = clips
    return out


def usable_spans(blocks_out: list[Interval], losses_out: list[Interval]) -> list[Interval]:
    """Submitted-audio time that is real speech-block audio (not spacer, not concealed loss)."""
    return subtract(union(blocks_out), losses_out)


def centroid(vectors: list[np.ndarray], weights: list[float] | None = None) -> np.ndarray:
    weights = weights or [1.0] * len(vectors)
    stacked = np.stack([v / (np.linalg.norm(v) or 1.0) for v in vectors]).astype(np.float64)
    mean = (stacked * np.asarray(weights, dtype=np.float64)[:, None]).sum(axis=0)
    norm = np.linalg.norm(mean)
    return (mean / norm if norm > 0 else mean).astype(np.float32)


def cosine_distance(a: np.ndarray, b: np.ndarray) -> float:
    return float(1.0 - np.dot(a, b) / ((np.linalg.norm(a) * np.linalg.norm(b)) or 1.0))


def embed_voices(clips: dict[str, list[Clip]], pcm: np.ndarray, embedder) -> dict[str, LabelVoice]:
    voices: dict[str, LabelVoice] = {}
    for label, label_clips in clips.items():
        vectors, weights, kept, energy = [], [], [], []
        for clip in label_clips:
            samples = pcm[int(round(clip.start * SAMPLE_RATE)) : int(round(clip.end * SAMPLE_RATE))]
            if len(samples) < SAMPLE_RATE // 2:
                continue
            try:
                vectors.append(np.asarray(embedder.embed(samples), dtype=np.float32))
            except ValueError:
                continue
            weights.append(clip.seconds)
            kept.append(clip)
            energy.append(float(np.mean(samples.astype(np.float64) ** 2)))
        voice = LabelVoice(label, kept)
        if vectors:
            voice.vector = centroid(vectors, weights)
            voice.clip_vectors = vectors
            voice.spread = round(max((cosine_distance(a, b) for i, a in enumerate(vectors) for b in vectors[i + 1 :]),
                                     default=0.0), 4)  # fmt: skip
            mean_energy = sum(e * w for e, w in zip(energy, weights, strict=True)) / sum(weights)
            voice.rms_db = round(10 * math.log10(mean_energy / 32768.0**2), 2) if mean_energy > 0 else -120.0
        voices[label] = voice
    return voices


def encode_vector(vector: np.ndarray) -> str:
    return base64.b64encode(np.asarray(vector, dtype="<f4").tobytes()).decode()


def decode_vector(text: str) -> np.ndarray:
    return np.frombuffer(base64.b64decode(text), dtype="<f4").astype(np.float32)
