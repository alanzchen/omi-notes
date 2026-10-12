"""The same conversation recorded by two devices (Apple Watch and the pendant).

Resends of the same chunk are a different problem (chunk idempotency, `ingest.py`); this is about
two microphones hearing one event. Policy (docs/capture-format-v1.md, "Apple Watch"):

- Only a conversation recorded by the Watch alone (source `watch_mic`) is ever set aside, never a
  pendant conversation, and never because of timestamps or text alone.
- It waits (at most WAIT_LIMIT after it ended) until every other device's conversations overlapping
  it are finished, so a late pendant upload is not missed in the usual case.
- The two recordings' loudness over time (log energy in 0.1 s steps, wall clock) is correlated over
  lags of ±MAX_SKEW to absorb clock differences. Two microphones hearing the same speech follow each
  other closely; unrelated speech doesn't.
- `alternate`: strong correlation (≥ SAME) and the pendant heard ≥ COVER of the Watch's speech. The
  Watch conversation gets no note of its own; it is listed (with its audio kept like any other) as
  an alternate recording of the pendant note. `partial`, `uncertain` and `distinct`: both notes stay.
- The decision is written to the vault (`<conversation dir>/source.json`) with its evidence, before
  it is used; deleting that file and reprocessing the conversation reverses it.
"""

from __future__ import annotations

import json
import logging
import math
import sqlite3

import numpy as np

from ..audio.timeline import SAMPLE_RATE
from ..vault import Vault

log = logging.getLogger(__name__)

WATCH = "watch_mic"
STEP = 0.1  # envelope resolution, seconds
MAX_SKEW = 15.0  # clock difference searched, seconds
SAME = 0.6  # correlation at least this: the same sound
UNSURE = 0.35  # between UNSURE and SAME: can't tell, keep both
COVER = 0.8  # share of the Watch's audio the pendant must also have heard
MIN_OVERLAP = 8.0  # seconds of audio both heard, at least, to compare at all
WAIT_LIMIT = 1800.0  # how long a Watch conversation waits for overlapping ones to finish
FORMAT = 1


def watch_only(db, row) -> bool:
    sources = {r["source"] for r in db.query("SELECT DISTINCT source FROM captures WHERE device_id=?", (row["device_id"],))}
    return bool(sources) and sources <= {WATCH}


def overlapping(db, row) -> list[sqlite3.Row]:
    """Other devices' (non-Watch) conversations near this one."""
    return [
        r for r in db.query(
            "SELECT * FROM conversations WHERE device_id<>? AND start < ? AND end > ? ORDER BY start",
            (row["device_id"], row["end"] + MAX_SKEW, row["start"] - MAX_SKEW),
        )
        if not watch_only(db, r)
    ]  # fmt: skip


def read(pipeline, conv_id: str) -> dict | None:
    try:
        data = Vault.read_json(pipeline.conv_dir(conv_id) / "source.json")
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and data.get("format") == FORMAT else None


def ready(pipeline, row, now: float) -> bool:
    """Every overlapping conversation is finished (or it has waited long enough)."""
    if now - row["end"] >= WAIT_LIMIT:
        return True
    return all(r["status"] in ("done", "discarded", "failed") for r in overlapping(pipeline.db, row))


def envelope(pipeline, rows, lo: float, hi: float) -> np.ndarray:
    """Log energy per STEP over [lo, hi] (wall clock); NaN where there is no audio."""
    n = max(0, int(math.ceil((hi - lo) / STEP)))
    out = np.full(n, np.nan)
    hop = int(STEP * SAMPLE_RATE)
    for row in rows:
        audio = pipeline.conversation_audio(row)
        for m in audio.timemap:
            pcm = audio.pcm[int(round(m.out_start * SAMPLE_RATE)): int(round(m.out_end * SAMPLE_RATE))]
            frames = len(pcm) // hop
            if frames == 0:
                continue
            energy = np.log10(np.mean(pcm[: frames * hop].astype(np.float64).reshape(frames, hop) ** 2, axis=1) + 1e-10)
            first = int(round((m.wall_start - lo) / STEP))
            for k in range(frames):
                i = first + k
                if 0 <= i < n:
                    out[i] = energy[k]
    return out


def compare(watch: np.ndarray, other: np.ndarray) -> tuple[float, float, float]:
    """(best correlation, its lag in seconds, share of the Watch's audio the other also has there)."""
    best = (-1.0, 0.0, 0.0)
    max_lag = int(MAX_SKEW / STEP)
    have = ~np.isnan(watch)
    total = int(have.sum())
    if total == 0:
        return best
    for lag in range(-max_lag, max_lag + 1):
        shifted = np.full_like(other, np.nan)
        if lag >= 0:
            shifted[lag:] = other[: len(other) - lag]
        else:
            shifted[:lag] = other[-lag:]
        both = have & ~np.isnan(shifted)
        if both.sum() * STEP < MIN_OVERLAP:
            continue
        a, b = watch[both], shifted[both]
        if a.std() < 1e-6 or b.std() < 1e-6:
            continue
        r = float(np.corrcoef(a, b)[0, 1])
        if r > best[0]:
            best = (r, lag * STEP, float(both.sum()) / total)
    return best


def decide(pipeline, row, now: float) -> dict:
    """Decide (once) and record in the vault before it is used."""
    existing = read(pipeline, row["id"])
    if existing is not None:
        return existing
    others = overlapping(pipeline.db, row)
    data = {"format": FORMAT, "decided_at": now, "decision": "distinct", "of": [], "correlation": None,
            "lag_seconds": None, "coverage": None}  # fmt: skip
    finished = [r for r in others if r["status"] == "done"]
    if finished:
        lo, hi = row["start"] - MAX_SKEW, row["end"] + MAX_SKEW
        r, lag, cover = compare(envelope(pipeline, [row], lo, hi), envelope(pipeline, finished, lo, hi))
        data |= {"correlation": round(r, 3), "lag_seconds": round(lag, 1), "coverage": round(cover, 3),
                 "of": [c["id"] for c in finished]}  # fmt: skip
        if r >= SAME and cover >= COVER:
            data["decision"] = "alternate"
        elif r >= SAME:
            data["decision"] = "partial"  # the same event, but the Watch has more of it: keep its note
        elif r >= UNSURE:
            data["decision"] = "uncertain"
    if others and not finished:
        data["note"] = "overlapping conversations unfinished after the wait; kept separately"
    Vault.write_json(pipeline.conv_dir(row["id"]) / "source.json", data)
    log.info("watch conversation %s: %s (r=%s, lag=%s s, coverage=%s)", row["id"], data["decision"],
             data["correlation"], data["lag_seconds"], data["coverage"])  # fmt: skip
    return data


def alternate_reason(pipeline, data: dict) -> str | None:
    """Why a Watch conversation has no note of its own, or None."""
    if data.get("decision") != "alternate" or not data.get("of"):
        return None
    of = pipeline.db.one("SELECT start, title FROM conversations WHERE id=?", (data["of"][0],))
    when = pipeline._local(of["start"]).strftime("%H:%M") if of else "the same time"
    title = f" “{of['title']}”" if of and of["title"] else ""
    return f"also recorded by the pendant (note{title} at {when}); the Apple Watch audio is kept as an alternate recording"


def dumps(data: dict) -> str:
    return json.dumps(data, sort_keys=True)
