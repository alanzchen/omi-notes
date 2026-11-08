"""Comparing voices after removing what every recording from this microphone shares.

Raw WeSpeaker voiceprints of one setup sit close together: Alan's and Gigi's person centroids are 0.92
apart in cosine, so raw distances can't tell them apart (asr-backfill-20261108). Subtracting the mean of
stored voices (the background) and comparing directions leaves -0.33 between them, Alan's own dictation at
0.53-0.83 and other people's voices near -0.5. A person's centred centroid is the median of their centred
samples, so a few mislabeled samples don't drag it (20 of Gigi's 57 sit closer to someone else).
"""

from __future__ import annotations

import numpy as np


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
