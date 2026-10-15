"""Apple Watch performance summaries (capture-format-v1.md, "Watch performance").

The Watch samples its battery and work counters while recording and sends them, through the phone,
as `watch_perf` events (stored like any event: vault first, then the index). This module only reads
them back and summarizes one recording at a time, claiming no more than the samples show:

- An interval between two consecutive samples counts as *measured* only if both are from the same
  boot (same `boot_id`) with monotonic offsets (`mono_s`, increasing), at most `GAP` apart, recording, on
  battery (not charging/full) and with known levels. Anything else is a gap, charging or unknown
  time, reported separately and never bridged.
- The rate (percentage points per hour) is the whole-Watch battery change over measured intervals,
  not Omi Notes' own energy. It is given only with at least `MIN_MEASURED` seconds measured, and
  marked `coarse` when the change is smaller than `COARSE_PP` (level steps dominate).
- Counters are cumulative per app launch: deltas are taken within a `launch_id` only (a relaunch
  resets them) and never go negative. Callback counts are not hardware wakes; `append_ms` is
  elapsed time inside the capture path, not CPU use.
- Samples may arrive late, out of order or twice: they are de-duplicated by id and ordered by the
  Watch's own clock and monotonic offset. The Watch never sends its boot time: `boot_id` is random. A recording with no `stopped`/`recovered` sample is incomplete.
"""

from __future__ import annotations

import json
from datetime import datetime

EVENT_TYPE = "watch_perf"
GAP = 15 * 60
MIN_MEASURED = 45 * 60
COARSE_PP = 3.0
GAUGES = ("outbox_parts", "awaiting_ack")


def _epoch(value) -> float | None:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def load(db, since: float) -> tuple[list[dict], dict[str, int]]:
    """Samples of `watch_perf` events whose time is at or after `since` (each sample once), and
    the batches each device reported discarding."""
    seen: set[str] = set()
    out: list[dict] = []
    dropped: dict[str, int] = {}
    for row in db.query("SELECT device_id, body_json FROM events WHERE type=? AND at >= ? ORDER BY at", (EVENT_TYPE, since)):
        try:
            data = json.loads(row["body_json"]).get("data") or {}
        except ValueError:
            continue
        if isinstance(data.get("dropped_batches"), int) and data["dropped_batches"] > 0:
            dropped[row["device_id"]] = dropped.get(row["device_id"], 0) + data["dropped_batches"]
        for s in data.get("samples") or []:
            if not isinstance(s, dict) or not isinstance(s.get("id"), str) or s["id"] in seen:
                continue
            at, mono = _epoch(s.get("at")), s.get("mono_s")
            if at is None or not isinstance(s.get("boot_id"), str):
                continue
            seen.add(s["id"])
            ok = isinstance(mono, (int, float)) and not isinstance(mono, bool)
            out.append({**s, "device_id": row["device_id"], "_at": at, "_mono": float(mono) if ok else None})
    return out, dropped


def _level(s: dict) -> float | None:
    b = s.get("battery")
    return float(b) if isinstance(b, (int, float)) and not isinstance(b, bool) and 0 <= b <= 1 else None


def summarize(samples: list[dict]) -> list[dict]:
    """One summary per recording, newest first."""
    by_recording: dict[str, list[dict]] = {}
    for s in samples:
        if isinstance(s.get("recording_id"), str):
            by_recording.setdefault(s["recording_id"], []).append(s)
    return sorted((_session(rid, rows) for rid, rows in by_recording.items()), key=lambda x: x["started_at"], reverse=True)


def _session(recording_id: str, rows: list[dict]) -> dict:
    rows = sorted(rows, key=lambda s: (s["_at"], s["_mono"] if s["_mono"] is not None else -1))
    measured = charging = unknown = paused = drop = 0.0
    gaps: list[dict] = []
    for a, b in zip(rows, rows[1:]):
        same_boot = (a["boot_id"] == b["boot_id"] and a["_mono"] is not None and b["_mono"] is not None
                     and b["_mono"] >= a["_mono"])  # fmt: skip
        dt = b["_mono"] - a["_mono"] if same_boot else None
        if dt is None or dt > GAP:
            reason = ("restart" if a["boot_id"] != b["boot_id"] else "no_monotonic_time") if dt is None else "no_samples"
            gaps.append({"from": a["at"], "to": b["at"], "reason": reason})
            continue
        if a.get("battery_state") in ("charging", "full") or b.get("battery_state") in ("charging", "full"):
            charging += dt
        elif a.get("state") != "recording":
            paused += dt
        elif _level(a) is None or _level(b) is None or "unknown" in (a.get("battery_state"), b.get("battery_state")):
            unknown += dt
        else:
            measured += dt
            drop += (_level(a) - _level(b)) * 100
    rate = quality = None
    if measured >= MIN_MEASURED:
        rate = round(drop / (measured / 3600), 2)
        quality = "coarse" if abs(drop) < COARSE_PP else "ok"
    known = [s for s in rows if _level(s) is not None]
    return {
        "recording_id": recording_id,
        "device_id": rows[0]["device_id"],
        "started_at": rows[0]["at"],
        "last_at": rows[-1]["at"],
        "complete": any(s.get("event") in ("stopped", "recovered") for s in rows),
        "samples": len(rows),
        "samples_battery_unknown": len(rows) - len(known),
        "battery_start": _level(known[0]) if known else None,
        "battery_end": _level(known[-1]) if known else None,
        "measured_s": round(measured, 1),
        "battery_drop_pp": round(drop, 1),
        "rate_pp_per_hour": rate,
        "rate_quality": quality or "insufficient",
        "charging_s": round(charging, 1),
        "battery_unknown_s": round(unknown, 1),
        "not_recording_s": round(paused, 1),
        "gaps": len(gaps),
        "gap_list": gaps[:20],
        "events": [s.get("event") for s in rows if s.get("event") != "periodic"],
        "counters": _deltas(rows),
        "gauges_last": {k: rows[-1].get("gauges", {}).get(k) for k in GAUGES if isinstance(rows[-1].get("gauges"), dict)},
        "builds": sorted({s.get("app") for s in rows if isinstance(s.get("app"), str)}),
        "os": sorted({s.get("os") for s in rows if isinstance(s.get("os"), str)}),
        "models": sorted({s.get("model") for s in rows if isinstance(s.get("model"), str)}),
        "launches": len({s.get("launch_id") for s in rows}),
    }


def _deltas(rows: list[dict]) -> dict[str, int]:
    """Counter growth during the recording, summed over app launches (never across one)."""
    total: dict[str, int] = {}
    by_launch: dict[str, list[dict]] = {}
    for s in rows:
        by_launch.setdefault(str(s.get("launch_id")), []).append(s)
    for launch in by_launch.values():
        launch.sort(key=lambda s: s["_at"])
        first: dict[str, int] = {}
        last: dict[str, int] = {}
        for s in launch:  # each counter's first and last observed value (a sample may lack one)
            for key, value in (s.get("counters") or {}).items():
                if isinstance(value, int) and not isinstance(value, bool):
                    first.setdefault(key, value)
                    last[key] = value
        for key, value in last.items():
            total[key] = total.get(key, 0) + max(0, value - first[key])
    return dict(sorted(total.items()))
