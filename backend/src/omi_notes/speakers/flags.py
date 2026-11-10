"""Which confirmed samples the owner should look at first (pure; docs/speaker-learning.md, "Review").

A flag only orders the review queue; it never takes a sample out of the model (the evidence study found
no held-out gain from excluding flagged samples: spk/a0-20261109/REPORT.md, recommendation 7). Only the
owner's reject removes one. Per person, over their eligible samples, with robust statistics
(MAD × 1.4826 ≈ one standard deviation):

- `pitch`: the sample's F0 lies outside the person's own band, median ± max(25 Hz, 2.5 MAD). There is
  no fixed 165 Hz split: each person is judged against their own voice.
- `score`: its raw cosine to the person's robust centroid is below median − 3 MAD of those scores.
- `enrollment`: the person's model is enrollment-only (≥ 60 s) and the sample is ≥ 0.50 from it.

Statistics need ≥ 5 samples (≥ 5 known F0s for `pitch`); fewer flag nothing. A flag is keyed by an
evidence fingerprint (its reasons and the sample's F0 measurement); a confirm records that fingerprint,
so unchanged evidence never asks again.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass

import numpy as np

from .match import THRESHOLD
from .voices import cosine_distance

VERSION = 1
MAD_SCALE = 1.4826
MIN_SAMPLES = 5
PITCH_FLOOR_HZ = 25.0
PITCH_MADS = 2.5
SCORE_MADS = 3.0
SCORE_MIN_SPREAD = 0.01  # a near-zero MAD (near-identical samples) must not flag ordinary jitter


@dataclass(frozen=True)
class FlagInput:
    id: str
    person_id: str
    vector: np.ndarray
    f0: float | None = None
    weight: float = 1.0  # enrollment samples count more in the robust centroid


def _unit(v) -> np.ndarray:
    v = np.asarray(v, dtype=np.float64)
    return v / (np.linalg.norm(v) or 1.0)


def robust_centroid(vectors: list[np.ndarray], weights: list[float] | None = None, iterations: int = 30) -> np.ndarray:
    """Geometric median of unit vectors (Weiszfeld), normalized: a few mislabeled samples don't drag it."""
    x = np.stack([_unit(v) for v in vectors])
    w = np.asarray(weights if weights is not None else [1.0] * len(vectors), dtype=np.float64)
    m = _unit((x * w[:, None]).sum(axis=0))
    for _ in range(iterations):
        d = np.linalg.norm(x - m, axis=1).clip(1e-6)
        nxt = _unit(((w / d)[:, None] * x).sum(axis=0))
        if np.linalg.norm(nxt - m) < 1e-7:
            break
        m = nxt
    return m


def mad(values: list[float]) -> tuple[float, float]:
    a = np.asarray(values, dtype=np.float64)
    med = float(np.median(a))
    return med, float(np.median(np.abs(a - med))) * MAD_SCALE


def evaluate(samples: list[FlagInput], enrollment_centroids: dict[str, np.ndarray] | None = None) -> dict[str, list[str]]:
    """sample id → reasons (empty: nothing to ask) for every sample given."""
    out: dict[str, list[str]] = {s.id: [] for s in samples}
    by_person: dict[str, list[FlagInput]] = {}
    for s in samples:
        by_person.setdefault(s.person_id, []).append(s)
    for pid, items in by_person.items():
        enrolled = (enrollment_centroids or {}).get(pid)
        if len(items) >= MIN_SAMPLES:
            # an enrollment-only model is the reference once there is one: the rest are re-scored against it
            centre = _unit(enrolled) if enrolled is not None else robust_centroid([s.vector for s in items], [s.weight for s in items])
            scores = [float(_unit(s.vector) @ centre) for s in items]
            med, spread = mad(scores)
            spread = max(spread, SCORE_MIN_SPREAD)
            for s, value in zip(items, scores, strict=True):
                if value < med - SCORE_MADS * spread:
                    out[s.id].append("score")
            known = [s for s in items if s.f0 is not None]
            if len(known) >= MIN_SAMPLES:
                med, spread = mad([s.f0 for s in known])
                half = max(PITCH_FLOOR_HZ, PITCH_MADS * spread)
                for s in known:
                    if abs(s.f0 - med) > half:
                        out[s.id].append("pitch")
        if enrolled is not None:
            for s in items:
                if cosine_distance(s.vector, enrolled) >= THRESHOLD:
                    out[s.id].append("enrollment")
    return {sid: sorted(set(reasons)) for sid, reasons in out.items()}


def fingerprint(reasons: list[str], sample: dict) -> str:
    """What a flag asks about: its reasons and the sample's F0 measurement (the vector never changes)."""
    evidence = {"v": VERSION, "reasons": sorted(reasons), "f0": None if sample.get("f0") is None else round(float(sample["f0"])),
                "f0_source": sample.get("f0_source")}  # fmt: skip
    return hashlib.sha256(json.dumps(evidence, sort_keys=True).encode()).hexdigest()[:16]
