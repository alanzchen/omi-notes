"""Comparing voices after removing what every recording from this microphone shares.

Raw WeSpeaker voiceprints of one setup sit close together: Alan's and Gigi's person centroids are 0.92
apart in cosine, so raw distances can't tell them apart (asr-backfill-20261108). Subtracting the mean of
stored voices (the background) and comparing directions leaves -0.33 between them, Alan's own dictation at
0.53-0.83 and other people's voices near -0.5. A person's centred centroid is the median of their centred
samples, so a few mislabeled samples don't drag it (20 of Gigi's 57 sit closer to someone else).

Recording-mean (rm) scoring (spk/a0-20261109/REPORT.md, recommendations 1-2; voices-hub plan, Revision 4):
- GA, the global mean, is the mean of the currently consent-eligible stored vectors (voices files under
  `SpeakerStore.vector_labels`, plus eligible samples), computed in memory whenever models are built and
  never persisted, so a revocation leaves nothing behind.
- A person's centroid is the median of their samples centred by GA.
- A conversation's label is centred by its recording mean, the mean of that conversation's label vectors:
  all of them at the voices stage (`conversation`), the stored, consented ones in a relabel (`partial`),
  GA with fewer than two (`ga`). A label within 0.20 of its recording mean has nothing left to compare
  (in a two-label conversation the two halves are exactly opposite) and uses GA too.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

RESIDUAL_GUARD = 0.20


def _unit(v: np.ndarray) -> np.ndarray:
    v = np.asarray(v, dtype=np.float64)
    return v / (np.linalg.norm(v) or 1.0)


def centred(vector: np.ndarray, background: np.ndarray) -> np.ndarray:
    return _unit(_unit(vector) - np.asarray(background, dtype=np.float64))


def background_of(vectors: list[np.ndarray]) -> np.ndarray | None:
    """The mean of unit voices (what they share), or None without any."""
    return np.mean([_unit(v) for v in vectors], axis=0) if vectors else None


def centred_centroids(samples: dict[str, list[np.ndarray]], background: np.ndarray) -> dict[str, np.ndarray]:
    """person → unit median of their centred samples."""
    return {pid: _unit(np.median(np.stack([centred(v, background) for v in vs]), axis=0)) for pid, vs in samples.items() if vs}


def score(vector: np.ndarray, centroid: np.ndarray, background: np.ndarray) -> float:
    """Cosine between a voice and a person's centred centroid (about 0.5-0.8 for the same person here)."""
    return float(centred(vector, background) @ centroid)


@dataclass
class RmSpace:
    ga: np.ndarray  # never persisted
    centroids: dict[str, np.ndarray] = field(default_factory=dict)  # person → GA-centred centroid
    count: int = 0  # vectors GA is the mean of


def build_space(vectors: list[np.ndarray], samples: dict[str, list[np.ndarray]]) -> RmSpace | None:
    """GA over `vectors` (every consent-eligible stored vector, samples included) and each person's
    GA-centred centroid; None without any vector."""
    ga = background_of(vectors)
    if ga is None:
        return None
    return RmSpace(ga, centred_centroids(samples, ga), len(vectors))


def label_centre(vector: np.ndarray, label_vectors: list[np.ndarray], ga: np.ndarray, *, full: bool) -> tuple[np.ndarray, str]:
    """(what to centre this label by, its basis: conversation | partial | ga). `label_vectors`: the
    conversation's label vectors at hand (all of them at the voices stage: `full`)."""
    if len(label_vectors) >= 2:
        rm = background_of(label_vectors)
        if np.linalg.norm(_unit(vector) - rm) >= RESIDUAL_GUARD:
            return rm, "conversation" if full else "partial"
    return np.asarray(ga, dtype=np.float64), "ga"


def ranking(vector: np.ndarray, label_vectors: list[np.ndarray], space: RmSpace, *, full: bool) -> tuple[list[tuple[float, str]], str]:
    """People by rm score, best first, and the basis used."""
    centre, basis = label_centre(vector, label_vectors, space.ga, full=full)
    scored = sorted(((score(vector, c, centre), pid) for pid, c in space.centroids.items()), key=lambda x: (-x[0], x[1]))
    return scored, basis
