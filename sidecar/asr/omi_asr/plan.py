"""Pure planning rules for the align+v pipeline (no models here, so they are testable anywhere).

From the 2026-11-08 bench (omi-notes-reviews/asr-bench-20261108):
- MOSS gets windows of 10-15 min cut at pauses, never over 20 min (a 19-min dense window already uses
  29k of its 40,960-token context), and an explicit max_tokens: its default of 2048 silently truncates
  a 10-min window after 2:38-4:03.
- A MOSS answer is truncated when it hit max_tokens, or when its last segment ends long before the last
  speech; the window is then cut at its middle pause and done again.
- Qwen3-ASR transcribes <= 180 s chunks cut at MOSS pauses, with max_tokens ~ 12 per second (a
  repetition loop of "I think." x300 appeared on an uncapped 12 s block).
"""

from __future__ import annotations

import math

import numpy as np

SR = 16000
MOSS_CONTEXT = 40_960
MOSS_PROMPT_TOKENS_PER_SECOND = 13.2  # measured: prompt tokens per audio second
TARGET_WINDOW = 12 * 60.0
MIN_WINDOW_CUT = 10 * 60.0
MAX_WINDOW_CUT = 15 * 60.0
HARD_MAX_WINDOW = 20 * 60.0
TRUNCATION_SLACK = 20.0  # s between the last segment's end and the last speech
QWEN_CHUNK_MIN, QWEN_CHUNK_MAX = 90.0, 180.0
QWEN_TOKENS_PER_SECOND = 12
_FRAME = SR // 50  # 20 ms


def moss_max_tokens(seconds: float) -> int:
    """At least 16k, 20 per audio second, within what the context leaves after the audio prompt."""
    prompt = math.ceil(MOSS_PROMPT_TOKENS_PER_SECOND * seconds)
    return max(256, min(MOSS_CONTEXT - prompt - 256, max(16_384, math.ceil(20 * seconds))))


def qwen_max_tokens(seconds: float) -> int:
    return math.ceil(QWEN_TOKENS_PER_SECOND * max(seconds, 1.0)) + 32


def frame_energy(pcm: np.ndarray) -> np.ndarray:
    n = len(pcm) // _FRAME
    if n == 0:
        return np.zeros(0)
    x = pcm[: n * _FRAME].astype(np.float64).reshape(n, _FRAME)
    return (x**2).mean(axis=1)


def _threshold(energy: np.ndarray) -> float:
    loud = energy[energy > 0]
    return 0.1 * float(np.median(loud)) if len(loud) else 0.0


def pauses(pcm: np.ndarray, min_seconds: float = 0.3) -> list[tuple[float, float]]:
    """Quiet runs (20 ms frames below 10% of the median frame energy) of at least `min_seconds`, as
    (start, end) seconds."""
    energy = frame_energy(pcm)
    if len(energy) == 0:
        return []
    quiet = np.concatenate([[False], energy <= _threshold(energy), [False]])
    edges = np.flatnonzero(quiet[1:] != quiet[:-1])
    out = []
    for a, b in zip(edges[::2], edges[1::2], strict=False):
        if (b - a) * _FRAME / SR >= min_seconds:
            out.append((a * _FRAME / SR, b * _FRAME / SR))
    return out


def speech_end(pcm: np.ndarray) -> float:
    """End of the last non-quiet frame (s)."""
    energy = frame_energy(pcm)
    loud = np.flatnonzero(energy > _threshold(energy)) if len(energy) else []
    return (int(loud[-1]) + 1) * _FRAME / SR if len(loud) else 0.0


def _cut_in(pcm: np.ndarray, lo: float, hi: float, quiet: list[tuple[float, float]]) -> float:
    """The middle of the longest pause in [lo, hi], else the quietest frame there."""
    inside = [(max(a, lo), min(b, hi)) for a, b in quiet if b > lo and a < hi]
    if inside:
        a, b = max(inside, key=lambda p: p[1] - p[0])
        return (a + b) / 2
    energy = frame_energy(pcm)
    i, j = int(lo * SR) // _FRAME, max(int(lo * SR) // _FRAME + 1, int(hi * SR) // _FRAME)
    return (i + int(np.argmin(energy[i:j]))) * _FRAME / SR if j <= len(energy) and j > i else hi


def plan_windows(pcm: np.ndarray, target_lo: float = MIN_WINDOW_CUT, target_hi: float = MAX_WINDOW_CUT,
                 hard_max: float = HARD_MAX_WINDOW) -> list[tuple[float, float]]:  # fmt: skip
    """(start, end) windows covering all audio: up to `hard_max` in one window; beyond that, cut at the
    longest pause 10-15 min in (else 5-20 min, else the quietest moment before 20 min)."""
    duration = len(pcm) / SR
    if duration <= hard_max:
        return [(0.0, duration)]
    quiet = pauses(pcm)
    cuts, start = [0.0], 0.0
    while duration - start > hard_max:
        lo, hi = start + target_lo, min(start + target_hi, duration)
        cut = _cut_in(pcm, lo, hi, quiet) if any(b > lo and a < hi for a, b in quiet) else None
        if cut is None:
            cut = _cut_in(pcm, start + 5 * 60, min(start + hard_max, duration), quiet)
        cut = min(max(cut, start + 60.0), start + hard_max)
        cuts.append(cut)
        start = cut
    return list(zip(cuts, [*cuts[1:], duration], strict=True))


def middle_cut(pcm: np.ndarray, start: float, end: float) -> float:
    """Where to cut a truncated window again: the longest pause in its middle third."""
    third = (end - start) / 3
    return _cut_in(pcm, start + third, end - third, pauses(pcm))


def is_truncated(segments: list[dict], generation_tokens: int, max_tokens: int, last_speech: float) -> bool:
    if generation_tokens >= max_tokens:
        return True
    ends = [float(s["end"]) for s in segments if s.get("end") is not None]
    return last_speech - (max(ends) if ends else 0.0) > TRUNCATION_SLACK


def chunk_cuts(segments: list[dict], duration: float, lo: float = QWEN_CHUNK_MIN, hi: float = QWEN_CHUNK_MAX) -> list[float]:
    """Cut points for Qwen chunks at MOSS pauses (gaps between the union of segments), each lo..hi s."""
    union: list[list[float]] = []
    for a, b in sorted((float(s["start"]), float(s["end"])) for s in segments):
        if union and a <= union[-1][1]:
            union[-1][1] = max(union[-1][1], b)
        else:
            union.append([a, b])
    gaps = [((union[i][1] + union[i + 1][0]) / 2, union[i + 1][0] - union[i][1]) for i in range(len(union) - 1)]
    cuts, t = [0.0], 0.0
    while duration - t > hi:
        candidates = [g for g in gaps if t + lo <= g[0] <= t + hi]
        t = max(candidates, key=lambda g: g[1])[0] if candidates else t + hi
        cuts.append(t)
    return [*cuts, duration]
