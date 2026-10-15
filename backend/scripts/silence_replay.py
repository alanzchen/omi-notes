"""Replay prototype for conservative silence omission on the Apple Watch (not product code).

Builds a SYNTHETIC cohort with known speech intervals (quiet room, noisy room, short words, quiet
and far voices, a whisper, clicks), runs a conservative extreme-silence detector and reports:
how much would be omitted, whether any ground-truth speech or any span the local Silero VAD calls
speech falls inside an omitted span, and how much encoding/transfer that would avoid. Nothing
leaves this machine; no provider is called.

    cd backend && uv run python scripts/silence_replay.py [--out report.json]

Detector (per 20 ms frame, causal except for the pre-roll it keeps):
- noise floor: slow tracker of the quietest frames (rises at most `FLOOR_RISE` dB/s, falls at once);
- a frame is *silent* only if below the floor + `MARGIN_DB` **and** below `ABS_MAX_DBFS` (only near
  digital-silence quiet rooms qualify; any noisy room is kept whole);
- only runs of silent frames of at least `MIN_OMIT_S` are omitted, minus `PRE_ROLL_S` before and
  `TAIL_S` after any non-silent frame (kept as audio).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from omi_notes.audio.vad import SileroVad
from omi_notes.devtools import synth_speech_like

SR = 16_000
FRAME = 320  # 20 ms
MARGIN_DB = 3.0
ABS_MAX_DBFS = -50.0
FLOOR_RISE = 0.5  # dB per second
MIN_OMIT_S = 20.0
PRE_ROLL_S = 2.0
TAIL_S = 2.0


def dbfs(x: np.ndarray) -> float:
    rms = np.sqrt(np.mean((x.astype(np.float64) / 32768.0) ** 2) + 1e-20)
    return 20 * np.log10(rms)


def noise(seconds: float, level_dbfs: float, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    white = rng.normal(0, 1, int(seconds * SR))
    pink = np.cumsum(white) * 0.02  # brownish room tone
    pink -= np.convolve(pink, np.ones(400) / 400, mode="same")
    x = white * 0.3 + pink
    x /= np.sqrt(np.mean(x ** 2)) + 1e-12
    return x * (10 ** (level_dbfs / 20)) * 32768


def speech(seconds: float, level: float, seed: int) -> np.ndarray:
    return synth_speech_like(seconds, seed=seed, level=level).astype(np.float64)


def scenario(name: str, floor_dbfs: float, events: list[tuple[float, float, float]], total: float, seed: int, clicks=()):
    """events: (start s, seconds, level) speech-like bursts; returns (pcm int16, truth intervals)."""
    pcm = noise(total, floor_dbfs, seed)
    truth = []
    for i, (start, seconds, level) in enumerate(events):
        a = int(start * SR)
        burst = speech(seconds, level, seed + i + 1)
        pcm[a:a + len(burst)] += burst[: len(pcm) - a]
        truth.append((start, start + seconds))
    for t in clicks:  # short bumps (fabric, taps): not speech, must not break anything
        a = int(t * SR)
        pcm[a:a + 80] += np.hanning(80) * 6000
    return name, np.clip(pcm, -32768, 32767).astype(np.int16), truth


def detect(pcm: np.ndarray) -> list[tuple[float, float]]:
    """Spans that would be omitted (seconds)."""
    n = len(pcm) // FRAME
    energy = np.array([dbfs(pcm[i * FRAME:(i + 1) * FRAME]) for i in range(n)])
    floor = energy[0]
    silent = np.zeros(n, bool)
    step = FLOOR_RISE * FRAME / SR
    for i, e in enumerate(energy):
        floor = e if e < floor else min(floor + step, e)
        silent[i] = e < floor + MARGIN_DB and e < ABS_MAX_DBFS
    # keep pre-roll before and tail after every non-silent frame
    keep = ~silent
    pre, tail = int(PRE_ROLL_S * SR / FRAME), int(TAIL_S * SR / FRAME)
    idx = np.flatnonzero(keep)
    grown = keep.copy()
    for i in idx:
        grown[max(0, i - pre):i + tail + 1] = True
    spans, i = [], 0
    while i < n:
        if grown[i]:
            i += 1
            continue
        j = i
        while j < n and not grown[j]:
            j += 1
        if (j - i) * FRAME / SR >= MIN_OMIT_S:
            spans.append((i * FRAME / SR, j * FRAME / SR))
        i = j
    return spans


def overlap(a: list[tuple[float, float]], b: list[tuple[float, float]]) -> float:
    return sum(max(0.0, min(x2, y2) - max(x1, y1)) for x1, x2 in a for y1, y2 in b)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    vad = SileroVad(Path(__file__).resolve().parents[1] / "models" / "silero_vad.onnx")
    cohort = [
        scenario("quiet room: normal, quiet and far speech with long pauses", -62,
                 [(10, 6, 0.3), (60, 4, 0.03), (120, 3, 0.01), (200, 8, 0.3)], 300, 1),
        scenario("quiet room: short words alone (yes/no, 0.25 s)", -62,
                 [(30, 0.25, 0.3), (95, 0.3, 0.1), (160, 0.25, 0.05), (240, 0.4, 0.3)], 300, 2),
        scenario("quiet room: a whisper 6 dB above the room", -62, [(80, 3, 0.0012)], 240, 3),
        scenario("noisy room (fan, -38 dBFS): speech and quiet speech", -38,
                 [(20, 6, 0.3), (100, 4, 0.03)], 240, 4),
        scenario("quiet room with clicks, no speech", -62, [], 240, 5, clicks=(30, 31, 90, 150, 151, 152)),
    ]
    rows = []
    for name, pcm, truth in cohort:
        spans = detect(pcm)
        probs = vad.probabilities(pcm)
        win = vad.window / SR
        vad_speech = [(i * win, (i + 1) * win) for i, p in enumerate(probs) if p >= 0.5]
        total = len(pcm) / SR
        omitted = sum(b - a for a, b in spans)
        rows.append({
            "scenario": name, "seconds": total, "omitted_s": round(omitted, 1), "omitted_share": round(omitted / total, 3),
            "spans": [(round(a, 1), round(b, 1)) for a, b in spans],
            "truth_speech_lost_s": round(overlap(truth, spans), 3),
            "silero_speech_in_omitted_s": round(overlap(vad_speech, spans), 3),
            "room_dbfs": round(dbfs(pcm[: SR]), 1),
        })  # fmt: skip
    report = {"synthetic": True, "detector": {"margin_db": MARGIN_DB, "abs_max_dbfs": ABS_MAX_DBFS, "floor_rise_db_s": FLOOR_RISE,
              "min_omit_s": MIN_OMIT_S, "pre_roll_s": PRE_ROLL_S, "tail_s": TAIL_S}, "scenarios": rows}  # fmt: skip
    text = json.dumps(report, indent=1)
    print(text)
    if args.out:
        args.out.write_text(text)


if __name__ == "__main__":
    main()
