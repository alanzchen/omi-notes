"""Speaker identities for a whole conversation from labels that restart per window (local ASR path).

The sidecar labels speakers per request window (up to 20 min; longer audio is several windows, which
overlap by ~40 s at a pause, and a truncated MOSS window may be re-split inside one). `link` turns the
(window, label) units into conversation-level speakers by constrained agglomerative clustering:
- cannot-link: two labels of the same window are different people (the provider told them apart);
- must-link: labels covering the same speech in two windows' shared stretch (`omi_notes.anchors`, from
  `providers.local_asr.anchors`) join first, with no voiceprint needed;
- then, repeatedly, the two most alike compatible clusters join while above the bar, and only when each is
  the other's closest cluster of all (one closest to a cluster it may not join is never given to the
  runner-up).
Each label's voiceprint is the WeSpeaker embedding of its clean speech (not overlapped by another
speaker, clips of at least 0.5 s, the longest first up to a minute).

Raw voiceprints of one recording share a large common part (room, microphone, distance): in a noisy
64-minute conversation every label was 0.93-0.99 from every other. So they are compared after removing
it: with at least `centre_min` labels, the conversation's own mean voiceprint; with fewer, the mean of
stored voices from other conversations (`background`); with neither, raw. The bar comes from the
conversation itself: a join must be closer than any two labels of one window (known different people) by
`gap`, and at least 0.5 centred / 0.85 raw. A provider that over-split one voice inside a window only
raises the bar: mistakes fall on the side of too many speakers, never a false merge. Measured
(asr-backfill-20261108): a 42-minute lecture, different people <= 0.33 against 0.89-0.93 for the same
voice (8 labels -> 3 speakers); the noisy conversation, <= 0.77 against up to 0.94.
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
CENTRE_MIN = 6  # labels needed to estimate the conversation's common part
FLOOR = 0.30  # in a centred space: different people mostly fall below (asr-bench-20261108 longwin, dinner)
UNCALIBRATED = 0.5  # centred bar when no window holds two labels
APART_QUANTILE_MIN = 10  # known-different pairs needed before an outlier among them is discounted
GAP = 0.05
TIE = 0.02  # closer than this to a cluster that is surely someone else: ambiguous, no join


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
    if embedder is None:  # no voice model: only overlap anchors can join labels
        return None
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


def bar(apart: list[float], *, centred: bool, raw_threshold: float = THRESHOLD) -> float:
    """The similarity a join must reach, from the known-different pairs (labels of one window). Raw: above the
    closest such pair (everything sounds alike). Centred: different people mostly fall below 0.3
    (asr-bench-20261108 longwin); one outlier pair (a provider over-split inside a window) must not hold back
    every join, so the 90th percentile once there are enough pairs."""
    if not centred:
        return max(raw_threshold, max(apart) + GAP) if apart else raw_threshold
    if not apart:  # one label per window: nothing to calibrate against, stay cautious
        return UNCALIBRATED
    level = float(np.percentile(apart, 90)) if len(apart) >= APART_QUANTILE_MIN else max(apart)
    return max(FLOOR, level + GAP)


def _groups(meta: dict, utterances: list[dict]) -> dict[int, int]:
    """label → the window (group) it was heard in: `omi_notes.groups` when the provider says (overlapping
    windows), else by each label's first utterance middle against the piece offsets."""
    if meta.get("groups"):
        return {int(label): int(group) for label, group in meta["groups"]}
    offsets = sorted(float(o) for o in meta.get("offsets") or [])
    out: dict[int, int] = {}
    for u in utterances:
        if u.get("speaker") is not None:
            # by the utterance's middle: offsets are rounded to the millisecond, a start can fall just before its own
            out.setdefault(u["speaker"], max(0, bisect.bisect_right(offsets, (float(u["start"]) + float(u["end"])) / 2) - 1))
    return out


def link(response: dict, pcm: np.ndarray, embedder, threshold: float = THRESHOLD, margin: float = MARGIN, *,
         background: np.ndarray | None = None, centre_min: int = CENTRE_MIN) -> dict:  # fmt: skip
    """The response with speakers numbered for the whole conversation (and `omi_notes.speakers_linked`), or
    unchanged when it was heard in one window or has no labels.

    Constrained agglomerative clustering over (window, label) units: labels the provider heard in the same
    window never join (cannot-link); labels tied by the same speech in two overlapping windows
    (`omi_notes.anchors`) join first (must-link, no voiceprint needed); then, repeatedly, the two most alike
    compatible clusters join while above the bar and each is the other's closest cluster of all (a cluster
    closest to one it may not join is not given to the runner-up)."""
    meta = response.get("omi_notes") or {}
    utterances = (response.get("results") or {}).get("utterances") or []
    group_of = _groups(meta, utterances)
    if len(set(group_of.values())) < 2:
        return response
    overlaps = overlap_spans(utterances)
    clips: dict[int, list[tuple[float, float]]] = {}
    first: dict[int, float] = {}
    for u in utterances:
        label = u.get("speaker")
        if label is None:
            continue
        start, end = float(u["start"]), float(u["end"])
        first[label] = min(first.get(label, start), start)
        clips.setdefault(label, []).extend(_clean(start, end, overlaps))
    order = sorted(first, key=first.get)
    prints = {label: _voiceprint(clips.get(label, []), pcm, embedder) for label in order}
    known = [v for v in prints.values() if v is not None]
    space, common = "raw", None
    if len(known) >= centre_min:
        space, common = "conversation", np.mean(known, axis=0)
    elif background is not None and known:
        space, common = "background", np.asarray(background, dtype=np.float64)
    if common is not None:
        for label, v in prints.items():
            if v is not None:
                v = v - common
                prints[label] = v / (np.linalg.norm(v) or 1.0)
    # labels of one window are different people: a link must be closer than any of them (in any space)
    apart = [float(np.dot(prints[a], prints[b])) for i, a in enumerate(order) for b in order[i + 1 :]
             if group_of.get(a) == group_of.get(b) and prints[a] is not None and prints[b] is not None]  # fmt: skip
    threshold = bar(apart, centred=common is not None, raw_threshold=threshold)
    weight = {label: sum(e - s for s, e in clips.get(label, [])) or 1.0 for label in order}
    clusters: dict[int, dict] = {label: {"labels": [label], "groups": {group_of.get(label, -1)}} for label in order}

    def centroid(c: dict) -> np.ndarray | None:
        vs = [(prints[lab], weight[lab]) for lab in c["labels"] if prints[lab] is not None]
        if not vs:
            return None
        mean = sum(v * w for v, w in vs)
        return mean / (np.linalg.norm(mean) or 1.0)

    def merge(a: int, b: int) -> None:
        clusters[a]["labels"] += clusters[b]["labels"]
        clusters[a]["groups"] |= clusters[b]["groups"]
        del clusters[b]

    def find(label: int) -> int:
        return next(k for k, c in clusters.items() if label in c["labels"])

    used_anchors = []
    for a, b in meta.get("anchors") or []:  # must-link: the same speech, heard in two windows
        if int(a) not in first or int(b) not in first:  # one side kept no speech of its own (all in the shared stretch)
            continue
        ka, kb = find(int(a)), find(int(b))
        if ka != kb and not clusters[ka]["groups"] & clusters[kb]["groups"]:
            merge(min(ka, kb), max(ka, kb))
            used_anchors.append([int(a), int(b)])
    merges = []
    while True:
        cents = {k: centroid(c) for k, c in clusters.items()}
        keys = [k for k in clusters if cents[k] is not None]
        sim = {(i, j): float(np.dot(cents[i], cents[j])) for i in keys for j in keys if i < j}

        def s(i: int, j: int) -> float:
            return sim[(min(i, j), max(i, j))]

        best = None
        for (i, j), v in sorted(sim.items(), key=lambda kv: -kv[1]):
            if v < threshold:
                break
            if clusters[i]["groups"] & clusters[j]["groups"]:
                continue
            # each must be the other's closest cluster of all, compatible or not
            if any(s(i, k) > v for k in keys if k not in (i, j)) or any(s(j, k) > v for k in keys if k not in (i, j)):
                continue
            # and clearly so against a cluster that is someone else for sure (it shares a window with the partner):
            # a voice as close to two people who were heard apart belongs to neither
            if any(s(i, k) >= v - TIE for k in keys if k not in (i, j) and clusters[k]["groups"] & clusters[j]["groups"]) or \
                    any(s(j, k) >= v - TIE for k in keys if k not in (i, j) and clusters[k]["groups"] & clusters[i]["groups"]):  # fmt: skip
                continue
            best = (i, j, v)
            break
        if best is None:
            break
        merges.append([best[0], best[1], round(best[2], 3)])
        merge(best[0], best[1])
    numbered = sorted(clusters.values(), key=lambda c: min(first[lab] for lab in c["labels"]))
    mapping = {lab: n for n, c in enumerate(numbered) for lab in c["labels"]}
    linked = [dict(u, speaker=mapping[u["speaker"]]) if u.get("speaker") is not None else u for u in utterances]
    out = dict(response, results=dict(response.get("results") or {}, utterances=linked))
    out["omi_notes"] = dict(meta, speakers_linked={"labels": len(order), "speakers": len(numbered), "space": space,
                                                   "threshold": round(threshold, 3), "anchors": used_anchors,
                                                   "merges": merges})  # fmt: skip
    log.info("clustered %d window labels into %d speakers (%d anchored)", len(order), len(numbered), len(used_anchors))
    return out
