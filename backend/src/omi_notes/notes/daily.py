"""Deterministic daily index `Daily/YYYY-MM-DD.md` (no LLM)."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime
from zoneinfo import ZoneInfo

import yaml

from .writer import link_target

STT_USD_PER_MINUTE = 0.0043  # Deepgram nova-3 pre-recorded, diarization included
# USD per million tokens: (input, output). Cache reads bill at 0.1x input, writes at 1.25x.
LLM_PRICES = {
    "claude-opus-5": (5.0, 25.0),
    "claude-opus-5-5": (4.0, 20.0),
    "claude-sonnet-5": (2.0, 10.0),
    "claude-haiku-4-5": (1.0, 5.0),
}


@dataclass
class DailyEntry:
    start: float
    end: float
    status: str  # completed | transcript_only | discarded | in_progress | failed
    title: str
    emoji: str = ""
    relpath: str | None = None
    action_items: list[str] = field(default_factory=list)
    speech_seconds: float = 0.0
    stt_seconds: float = 0.0
    llm_model: str | None = None
    llm_usage: dict = field(default_factory=dict)
    late_audio: bool = False
    provisional: bool = False
    discard_reason: str | None = None


def llm_cost(model: str | None, usage: dict) -> float:
    if not model or not usage:
        return 0.0
    price = next((p for name, p in LLM_PRICES.items() if model.startswith(name)), None)
    if price is None:
        return 0.0
    inp, outp = price
    return (
        usage.get("input_tokens", 0) * inp
        + usage.get("cache_read_input_tokens", 0) * inp * 0.1
        + usage.get("cache_creation_input_tokens", 0) * inp * 1.25
        + usage.get("output_tokens", 0) * outp
    ) / 1e6


def _link(relpath: str, label: str) -> str:
    return f"[[{link_target(relpath)}\\|{label.replace('|', '-')}]]"


def render_daily(day: date, entries: list[DailyEntry], tz: ZoneInfo) -> str:
    entries = sorted(entries, key=lambda e: e.start)
    kept = [e for e in entries if e.status in ("completed", "transcript_only")]
    discarded = [e for e in entries if e.status == "discarded"]
    pending = [e for e in entries if e.status in ("in_progress", "failed")]
    speech = sum(e.speech_seconds for e in kept + discarded)
    stt_cost = sum(e.stt_seconds for e in entries) / 60 * STT_USD_PER_MINUTE
    llm_total = sum(llm_cost(e.llm_model, e.llm_usage) for e in entries)
    fm = yaml.safe_dump(
        {
            "type": "omi-daily",
            "date": day.isoformat(),
            "conversations": len(kept),
            "discarded": len(discarded),
            "speech_min": round(speech / 60, 1),
        },
        sort_keys=False,
    )
    out = ["---", fm.rstrip("\n"), "---", "", f"# {day:%A, %B} {day.day}, {day:%Y}", ""]
    if kept:
        out += ["| Time | | Conversation | Duration |", "|---|---|---|---|"]
        for e in kept:
            local = datetime.fromtimestamp(e.start, tz)
            flags = "".join(
                [" · late audio" if e.late_audio else "", " · provisional" if e.provisional else "",
                 " · transcript only" if e.status == "transcript_only" else ""]
            )  # fmt: skip
            name = _link(e.relpath, e.title) if e.relpath else e.title
            minutes = max(1, round((e.end - e.start) / 60))
            out.append(f"| {local:%H:%M} | {e.emoji} | {name}{flags} | {minutes} min |")
        out.append("")
    else:
        out += ["_No conversations yet._", ""]

    items = [(e, item) for e in kept for item in e.action_items]
    if items:
        out += ["## Action Items", ""]
        # Plain bullets on purpose: checkboxes here would duplicate the notes' tasks in Obsidian Tasks.
        out += [f"- {item} · {_link(e.relpath, e.title)}" if e.relpath else f"- {item}" for e, item in items]
        out.append("")
    if pending:
        out += ["## In Progress", ""]
        for e in pending:
            local = datetime.fromtimestamp(e.start, tz)
            out.append(f"- {local:%H:%M} · {'processing failed' if e.status == 'failed' else 'in progress'}")
        out.append("")
    if discarded:
        out += ["## Discarded", ""]
        for e in discarded:
            local = datetime.fromtimestamp(e.start, tz)
            label = f"{local:%H:%M} · {e.discard_reason or 'no meaningful content'}"
            out.append(f"- {_link(e.relpath, label)}" if e.relpath else f"- {label}")
        out.append("")
    out += [
        f"Speech: {speech / 60:.1f} min · Estimated cost: ${stt_cost:.2f} transcription"
        + (f" + ${llm_total:.2f} summaries" if llm_total else ""),
    ]
    return "\n".join(out) + "\n"
