"""Putting Qwen3-ASR text on MOSS lines (the bench's `align` variant, scripts/hybrid.py `v_align`).

Each aligned unit (a Chinese character or English word with its time from Qwen3-ForcedAligner) goes to
the MOSS line whose span (+-0.2 s) holds its midpoint, else the line with the nearest edge, which is
stretched to cover it. A line that gets no text
keeps MOSS's own (backchannels such as 嗯 / 对 that Qwen skips).
"""

from __future__ import annotations

from dataclasses import dataclass

SLACK = 0.2


@dataclass
class Unit:
    start: float  # absolute seconds
    end: float
    text: str  # the piece of Qwen's text this unit stands for (punctuation and spacing kept)
    chunk_start: bool = False  # the first unit of a Qwen chunk (its text never carried the space before it)


def moss_lines(raw_segments: list[dict], offset: float = 0.0) -> list[dict]:
    """MOSS segments with a speaker → lines {start, end, speaker, moss_text}, shifted by `offset`."""
    lines = []
    for s in raw_segments:
        if not s.get("speaker_id"):
            continue
        text = str(s.get("text", ""))
        text = text.split("] ", 1)[-1] if text.startswith("[") else text
        lines.append({"start": float(s["start"]) + offset, "end": float(s["end"]) + offset,
                      "speaker": str(s["speaker_id"]), "moss_text": text.strip()})  # fmt: skip
    return lines


def spans_for(text: str, items: list[tuple[str, float, float]], offset: float) -> list[Unit]:
    """Aligner items (unit text, start, end relative to the chunk) → units carrying the slice of the
    original text up to the next unit, so punctuation and spacing survive."""
    cur, starts = 0, []
    for unit, _, _ in items:
        k = text.find(unit, cur)
        if k < 0:
            k = text.lower().find(unit.lower(), cur)
        starts.append(k if k >= 0 else None)
        if k >= 0:
            cur = k + len(unit)
    units = []
    first = next((k for k in starts if k is not None), None)
    for i, (unit, a, b) in enumerate(items):
        if starts[i] is None:
            piece = unit
        else:
            nxt = next((starts[j] for j in range(i + 1, len(starts)) if starts[j] is not None), len(text))
            # what precedes the first aligned unit ("-" of "-5", an opening quote) belongs to it
            piece = text[0 if starts[i] == first else starts[i] : nxt]
        units.append(Unit(offset + a, offset + b, piece, chunk_start=i == 0))
    return units


def _joined(left: str, right: str) -> str:
    """`left + right`, with a space where two chunks' Latin words would otherwise run together."""
    if left and right and not left[-1].isspace() and not right[0].isspace() and left[-1].isascii() and right[0].isascii() \
            and (left[-1].isalnum() or left[-1] in ".,;:!?") and right[0].isalnum():  # fmt: skip
        return left + " " + right
    return left + right


def assign(lines: list[dict], units: list[Unit]) -> tuple[list[dict], dict]:
    """Lines with `text` from the units (MOSS text where none landed) and assignment statistics."""
    out = [dict(line, text="") for line in lines]
    outside = 0
    for u in units:
        if not out:
            break
        m = (u.start + u.end) / 2
        inside = [j for j, s in enumerate(out) if s["start"] - SLACK <= m <= s["end"] + SLACK]
        if inside:
            j = min(inside, key=lambda j: abs((out[j]["start"] + out[j]["end"]) / 2 - m))
        else:  # the line with the nearest edge, stretched to cover the unit (its time stays honest)
            outside += 1
            j = min(range(len(out)), key=lambda j: max(out[j]["start"] - m, m - out[j]["end"]))
            out[j]["start"], out[j]["end"] = min(out[j]["start"], u.start), max(out[j]["end"], u.end)
        out[j]["text"] = _joined(out[j]["text"], u.text) if u.chunk_start else out[j]["text"] + u.text
    empty = 0
    for s in out:
        s["text"] = s["text"].strip()
        if not s["text"]:
            empty += 1
            s["text"] = s.get("moss_text", "")
    return out, {"units": len(units), "units_outside_lines": outside, "lines_with_moss_text": empty}
