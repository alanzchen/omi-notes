"""Linking a split transcript's speaker labels across pieces with voiceprints (local ASR path).

The provider labels speakers per request piece (up to 15 min), and `merge_pieces` numbers each piece's
labels apart. For every label, the voiceprint of its clean speech (not overlapped by another speaker,
clips of at least 0.5 s, the longest first up to a minute) is compared with the speakers found so far:
it joins the closest one when the cosine is at least `threshold` and beats the runner-up by `margin`,
otherwise it is a new speaker. Two labels of the same piece never join (the provider told them apart).
Measured on the bench (asr-bench-20261108): meeting links at 0.97 against at most 0.78 for others; a
noisy dinner is ambiguous (0.876 vs 0.890), which the margin rule leaves as separate speakers.
"""

from __future__ import annotations

import bisect
import logging

import numpy as np

log = logging.getLogger(__name__)

SR = 16000
THRESHOLD = 0.85
MARGIN = 0.05
MIN_CLIP = 0.5
MAX_SECONDS_PER_LABEL = 60.0


def overlap_spans(utterances: list[dict]) -> list[tuple[float, float]]:
    """Where utterances of different speakers overlap (excluded from voiceprints)."""
    spans = []
    ordered = sorted(utterances, key=lambda u: float(u["start"]))
    for i, a in enumerate(ordered):
        for b in ordered[i + 1 :]:
            if float(b["start"]) >= float(a["end"]):
                break
            if b.get("speaker") != a.get("speaker"):
                spans.append((max(float(a["start"]), float(b["start"])), min(float(a["end"]), float(b["end"]))))
    return spans


def _clean(start: float, end: float, overlaps: list[tuple[float, float]]) -> list[tuple[float, float]]:
    parts = [(start, end)]
    for a, b in overlaps:
        nxt = []
        for s, e in parts:
            if b <= s or a >= e:
                nxt.append((s, e))
                continue
            if a > s:
                nxt.append((s, a))
            if b < e:
                nxt.append((b, e))
        parts = nxt
    return [(s, e) for s, e in parts if e - s >= MIN_CLIP]


def _voiceprint(clips: list[tuple[float, float]], pcm: np.ndarray, embedder) -> np.ndarray | None:
    vectors, weights, total = [], [], 0.0
    for s, e in sorted(clips, key=lambda c: c[1] - c[0], reverse=True):
        if total >= MAX_SECONDS_PER_LABEL:
            break
        try:
            v = embedder.embed(pcm[int(round(s * SR)) : int(round(e * SR))])
        except ValueError:  # too short for this model
            continue
        vectors.append(np.asarray(v, dtype=np.float64))
        weights.append(e - s)
        total += e - s
    if not vectors:
        return None
    mean = np.average(np.stack(vectors), axis=0, weights=weights)
    return mean / (np.linalg.norm(mean) or 1.0)


def link(response: dict, pcm: np.ndarray, embedder, threshold: float = THRESHOLD, margin: float = MARGIN) -> dict:
    """The response with speakers numbered across pieces (and `omi_notes.speakers_linked`), or unchanged
    when it wasn't split or has no labels."""
    meta = response.get("omi_notes") or {}
    offsets = sorted(float(o) for o in meta.get("offsets") or [])
    utterances = (response.get("results") or {}).get("utterances") or []
    if len(offsets) < 2 or not any(u.get("speaker") is not None for u in utterances):
        return response
    overlaps = overlap_spans(utterances)
    piece_of: dict[int, int] = {}
    clips: dict[int, list[tuple[float, float]]] = {}
    first: dict[int, float] = {}
    for u in utterances:
        label = u.get("speaker")
        if label is None:
            continue
        start, end = float(u["start"]), float(u["end"])
        # by the utterance's middle: offsets are rounded to the millisecond, a start can fall just before its own
        piece_of.setdefault(label, max(0, bisect.bisect_right(offsets, (start + end) / 2) - 1))
        first[label] = min(first.get(label, start), start)
        clips.setdefault(label, []).extend(_clean(start, end, overlaps))
    speakers: list[dict] = []  # {vector, weight, pieces}
    mapping: dict[int, int] = {}
    links = []
    for label in sorted(first, key=first.get):
        vector = _voiceprint(clips.get(label, []), pcm, embedder)
        piece = piece_of[label]
        best, best_cos, second = None, -1.0, -1.0
        if vector is not None:
            for k, sp in enumerate(speakers):
                if sp["vector"] is None or piece in sp["pieces"]:
                    continue
                cos = float(np.dot(vector, sp["vector"]))
                if cos > best_cos:
                    best, best_cos, second = k, cos, best_cos
                elif cos > second:
                    second = cos
        joined = best is not None and best_cos >= threshold and best_cos - second >= margin
        if joined:
            sp = speakers[best]
            w = sum(e - s for s, e in clips.get(label, [])) or 1.0
            mixed = sp["vector"] * sp["weight"] + vector * w
            sp["vector"], sp["weight"] = mixed / (np.linalg.norm(mixed) or 1.0), sp["weight"] + w
            sp["pieces"].add(piece)
            mapping[label] = best
        else:
            speakers.append({"vector": vector, "weight": sum(e - s for s, e in clips.get(label, [])) or 1.0, "pieces": {piece}})
            mapping[label] = len(speakers) - 1
        links.append({"label": label, "piece": piece, "speaker": mapping[label], "cosine": round(best_cos, 3),
                      "runner_up": round(second, 3), "joined": joined})  # fmt: skip
    linked = [dict(u, speaker=mapping[u["speaker"]]) if u.get("speaker") is not None else u for u in utterances]
    out = dict(response, results=dict(response.get("results") or {}, utterances=linked))
    out["omi_notes"] = dict(meta, speakers_linked={"labels": len(first), "speakers": len(speakers), "links": links})
    log.info("linked %d piece labels into %d speakers", len(first), len(speakers))
    return out
