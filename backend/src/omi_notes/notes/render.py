"""Render one conversation note (pure: data in, markdown out).

Layout (architecture.md #14): YAML frontmatter (always via `yaml.safe_dump`), `# emoji Title`,
summary callout, when/duration/speakers line, capture caveats, Key Points, Action Items
(Obsidian-Tasks compatible), Decisions, Open Questions, Events, People, Worth Remembering,
Bookmarks, My Notes (preserved verbatim between markers), Transcript.

All model- and transcript-derived text is untrusted: `<!--` is neutralized (so nothing can
imitate the My Notes markers) and single-line fields are collapsed to one line (so nothing can
start its own Markdown heading or list).
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import datetime
from typing import Literal
from zoneinfo import ZoneInfo

import yaml

from .schema import ActionItem, ConversationNotes
from .writer import MY_NOTES_END, MY_NOTES_START

NoteStatus = Literal["completed", "discarded", "transcript_only"]
BOOKMARK_CONTEXT_SECONDS = 30.0


@dataclass
class NoteData:
    id: str
    status: NoteStatus
    start: float
    end: float
    tz: ZoneInfo
    segments: list[dict]
    speech_seconds: float
    notes: ConversationNotes | None = None
    provisional: bool = False
    late_audio: bool = False
    related: str | None = None  # wikilink target of the related note, or its id
    audio_gaps: list[list[float]] = field(default_factory=list)
    sources: list[str] = field(default_factory=list)
    device: str | None = None
    language: str = "en"
    stt: str = ""
    llm: str | None = None
    prompt_version: int | None = None
    revision: int = 1
    processed_at: float | None = None
    bookmarks: list[float] = field(default_factory=list)
    discard_reason: str | None = None
    summary_error: str | None = None
    owner_name: str = ""
    late_double_taps: list[float] = field(default_factory=list)
    lost_seconds: float = 0.0
    clock_suspect: bool = False
    speaker_labels_consistent: bool = True
    # Local diarization found no speaker turns: one window, speaker explicitly unknown.
    speakers_unknown: bool = False
    # Speaker labels recognized by voice → the person's People note name (docs/speaker-learning.md).
    voice_names: dict[str, str] = field(default_factory=dict)


def neutralize(text: str) -> str:
    return text.replace("<!--", "&lt;!--")


def one_line(text: str) -> str:
    return " ".join(neutralize(text).split())


def _clean(value, *, multiline_keys: frozenset = frozenset({"overview"}), key: str = ""):
    if isinstance(value, str):
        return neutralize(value) if key in multiline_keys else one_line(value)
    if isinstance(value, dict):
        return {k: _clean(v, key=k) for k, v in value.items()}
    if isinstance(value, list):
        return [_clean(v, key=key) for v in value]
    return value


def sanitized(d: NoteData) -> NoteData:
    """A copy of `d` whose untrusted strings cannot break the note's structure."""
    notes = ConversationNotes.model_validate(_clean(d.notes.model_dump())) if d.notes else None
    segments = [seg | {"text": one_line(seg["text"]), "speaker": one_line(seg["speaker"])} for seg in d.segments]
    fields = {k: one_line(v) if isinstance(v, str) else v for k, v in
              (("discard_reason", d.discard_reason), ("summary_error", d.summary_error),
               ("related", d.related), ("device", d.device))}  # fmt: skip
    voice_names = {label: _link_safe(one_line(name)) for label, name in d.voice_names.items()}
    return replace(d, notes=notes, segments=segments, voice_names=voice_names, **fields)


def _link_safe(name: str) -> str:
    """A People note name usable inside `[[...]]`."""
    return "".join(ch for ch in name if ch not in "[]|#^") or "?"


def _local(epoch: float, tz: ZoneInfo) -> datetime:
    return datetime.fromtimestamp(epoch, tz)


def _iso(epoch: float | None, tz: ZoneInfo) -> str | None:
    return None if epoch is None else _local(epoch, tz).isoformat(timespec="seconds")


def speaker_label(label: str, notes: ConversationNotes | None, voice_names: dict[str, str] | None = None) -> str:
    """`S2` → `Priya` when recognized by voice, `Priya (Speaker 2)` when the summary named it (a
    hint from the transcript), else `Speaker 2`."""
    if voice_names and label in voice_names:
        return voice_names[label]
    number = label[1:] if label.startswith("S") and label[1:].isdigit() else label
    generic = f"Speaker {number}"
    name = notes.speaker_names.get(label) if notes else None
    return f"{name} ({generic})" if name else generic


def title_of(d: NoteData) -> str:
    if d.notes and d.notes.title and d.status != "transcript_only":
        return d.notes.title
    return "Conversation" if d.status != "discarded" else "Discarded conversation"


def owner_display(item: ActionItem, owner_name: str) -> str | None:
    if item.owner == "me":
        return owner_name or "me"
    if item.owner_name:
        return item.owner_name
    return "someone else" if item.owner == "other" else None


def _clock(epoch: float, tz: ZoneInfo) -> str:
    return _local(epoch, tz).strftime("%H:%M:%S")


def _transcript_line(seg: dict, d: NoteData) -> str:
    return f"**{_clock(seg['start'], d.tz)} · {speaker_label(seg['speaker'], d.notes, d.voice_names)}:** {seg['text']}"


def _duration_text(seconds: float) -> str:
    minutes = seconds / 60
    if minutes < 1:
        return f"{max(1, round(seconds))} s"
    if minutes < 90:
        return f"{round(minutes)} min"
    return f"{int(minutes // 60)} h {round(minutes % 60)} min"


def frontmatter(d: NoteData) -> dict:
    notes = d.notes if d.status != "transcript_only" else None
    items = notes.action_items if notes else []
    words = sum(len(s["text"].split()) for s in d.segments)
    labels = sorted({s["speaker"] for s in d.segments}, key=lambda x: (int(x[1:]) if x[1:].isdigit() else 10**6, x))
    speakers: int | list[str] = len(labels)
    people: dict = {}
    if d.voice_names:
        # Read-only projections of speakers.json (Obsidian links them to the People notes).
        speakers = [f"{label}: [[{d.voice_names[label]}]]" if label in d.voice_names else f"{label}: ?" for label in labels]
        people = {"people": list(dict.fromkeys(f"[[{d.voice_names[label]}]]" for label in labels if label in d.voice_names))}
    return {
        "id": d.id,
        "type": "omi-conversation",
        "status": d.status,
        "provisional": d.provisional,
        "late_audio": d.late_audio,
        "related": f"[[{d.related}]]" if d.related and "/" in d.related else d.related,
        "title": title_of(d),
        "emoji": notes.emoji if notes else "",
        "category": notes.category if notes else None,
        "started_at": _iso(d.start, d.tz),
        "ended_at": _iso(d.end, d.tz),
        "duration_min": round((d.end - d.start) / 60, 1),
        "speech_min": round(d.speech_seconds / 60, 1),
        "speakers": speakers,
        **people,
        "word_count": words,
        "language": d.language,
        "device": d.device,
        "sources": d.sources,
        "audio_gaps": [f"{_clock(a, d.tz)}–{_clock(b, d.tz)}" for a, b in d.audio_gaps],
        "audio_lost_s": round(d.lost_seconds, 1),
        "clock_suspect": d.clock_suspect,
        "speaker_labels_consistent": d.speaker_labels_consistent,
        "action_items_open": len(items),
        "tags": (notes.tags if notes else []),
        "discard_reason": d.discard_reason if d.status == "discarded" else None,
        "stt": d.stt,
        "llm": d.llm,
        "prompt_version": d.prompt_version,
        "revision": d.revision,
        "processed_at": _iso(d.processed_at, d.tz),
    }


def render_note(d: NoteData, my_notes: str | None = None) -> str:
    d = sanitized(d)
    fm = yaml.safe_dump(frontmatter(d), sort_keys=False, allow_unicode=True, width=10_000)
    notes = d.notes if d.status != "transcript_only" else None
    start_local, end_local = _local(d.start, d.tz), _local(d.end, d.tz)
    title = title_of(d)
    emoji = f"{notes.emoji} " if notes and notes.emoji else ""
    out: list[str] = ["---", fm.rstrip("\n"), "---", "", f"# {emoji}{title}", ""]

    if notes and notes.overview:
        out += ["> [!summary]", *[f"> {line}" if line else ">" for line in notes.overview.splitlines()], ""]
    speakers = len({s["speaker"] for s in d.segments})
    out += [
        f"**When:** {start_local:%a %d %b %Y, %H:%M}–{end_local:%H:%M} · "
        f"**Duration:** {_duration_text(d.end - d.start)} · **Speakers:** {'unknown' if d.speakers_unknown else speakers}",
        "",
    ]

    if d.status == "discarded":
        out += [f"> [!note] Discarded: {d.discard_reason or 'no meaningful content'}", ""]
    if d.status == "transcript_only":
        reason = d.summary_error or "no summarizer configured"
        out += [f"> [!note] Summary unavailable ({reason}). The transcript is below.", ""]
    if d.late_audio:
        target = f"[[{d.related}]]" if d.related and "/" in d.related else (d.related or "an earlier conversation")
        out += [f"> [!info] Late audio: this arrived after {target} was finalized.", ""]
    if d.provisional:
        out += [
            "> [!warning] Provisional: closed before every stretch of audio around it was confirmed. "
            "Audio that arrives later becomes a separate note.",
            "",
        ]
    if d.audio_gaps:
        spans = ", ".join(f"{_clock(a, d.tz)}–{_clock(b, d.tz)}" for a, b in d.audio_gaps)
        out += [f"> [!warning] Audio missing: {spans}.", ""]
    if d.lost_seconds >= 0.05:
        out += [
            f"> [!warning] About {d.lost_seconds:.1f} s of audio was lost in transmission around this conversation "
            "(short dropouts are concealed).",
            "",
        ]
    if d.speakers_unknown:
        out += [
            "> [!warning] Local speaker separation found no distinct speaker in this audio, so the speaker is "
            "unknown. The text is the automated transcription and hasn't been checked.",
            "",
        ]
    elif not d.speaker_labels_consistent:
        out += [
            "> [!warning] Speaker labels restart in each part this audio was transcribed in, so the same person "
            "may appear under different labels. Install local diarization for consistent speakers.",
            "",
        ]
    if d.clock_suspect:
        out += ["> [!warning] The pendant's clock jumped while this audio was recorded offline; times may be off.", ""]
    for tap in d.late_double_taps:
        out += [
            f"> [!note] Double tap at {_clock(tap, d.tz)} arrived after this note was written, "
            "so the conversation was not split there.",
            "",
        ]

    if notes:
        if notes.sections:
            out += ["## Key Points", ""]
            for section in notes.sections:
                out += [f"### {section.heading}", *[f"- {b}" for b in section.bullets], ""]
        if notes.action_items:
            out += ["## Action Items", ""]
            for item in notes.action_items:
                line = f"- [ ] {item.description}"
                owner = owner_display(item, d.owner_name)
                if owner:
                    line += f" — **{owner}**"
                if item.due_date:
                    line += f" 📅 {item.due_date.isoformat()}"
                out.append(line)
                if item.context:
                    out.append(f"    - {item.context}")
            out.append("")
        for heading, values in (("Decisions", notes.decisions), ("Open Questions", notes.open_questions)):
            if values:
                out += [f"## {heading}", "", *[f"- {v}" for v in values], ""]
        if notes.events:
            out += ["## Events", ""]
            for event in notes.events:
                when = f" — {event.start_local_iso.replace('T', ' ')}" if event.start_local_iso else ""
                length = f" ({event.duration_min} min)" if event.duration_min else ""
                out.append(f"- {event.title}{when}{length}")
            out.append("")
        if notes.people:
            out += ["## People", "", *[f"- **{p.name}**" + (f" — {p.note}" if p.note else "") for p in notes.people], ""]
        if notes.memorable_facts:
            out += ["## Worth Remembering", "", *[f"- {f}" for f in notes.memorable_facts], ""]

    if d.bookmarks:
        out += ["## Bookmarks", ""]
        for mark in sorted(d.bookmarks):
            out.append(f"- **{_clock(mark, d.tz)}**")
            context = [s for s in d.segments if s["end"] >= mark - BOOKMARK_CONTEXT_SECONDS and s["start"] <= mark]
            out += [f"    > {_transcript_line(s, d)}" for s in context]
        out.append("")

    body_notes = my_notes if my_notes is not None else "\n\n"
    out += ["## My Notes", "", f"{MY_NOTES_START}{body_notes}{MY_NOTES_END}", ""]

    out += ["## Transcript", ""]
    if d.segments:
        for seg in d.segments:
            out += [_transcript_line(seg, d), ""]
    else:
        out += ["_No speech was transcribed._", ""]
    return "\n".join(out).rstrip("\n") + "\n"


def render_stub(
    *,
    conv_id: str,
    status: str,
    start: float,
    end: float,
    tz: ZoneInfo,
    speech_seconds: float,
    waiting_for: str | None,
    error: str | None,
) -> str:
    fm = yaml.safe_dump(
        {
            "id": conv_id,
            "type": "omi-conversation",
            "status": "in_progress",
            "stage": status,
            "started_at": _iso(start, tz),
            "last_speech_at": _iso(end, tz),
            "speech_min": round(speech_seconds / 60, 1),
        },
        sort_keys=False,
        allow_unicode=True,
    )
    labels = {
        "open": "Recording — waiting for the conversation to end",
        "closed": "Queued for transcription",
        "transcribing": "Transcribing",
        "summarizing": "Summarizing",
        "failed": "Processing failed — see _status.md (`omi-notes retry-failed`)",
    }
    lines = [
        "---",
        fm.rstrip("\n"),
        "---",
        "",
        f"# ⏳ Conversation started {_local(start, tz):%H:%M}",
        "",
        f"**Status:** {labels.get(status, status)}",
        "",
        f"- Started: {_local(start, tz):%a %d %b %Y, %H:%M:%S}",
        f"- Last speech: {_local(end, tz):%H:%M:%S}",
        f"- Speech so far: {_duration_text(speech_seconds)}",
    ]
    if waiting_for and status == "open":
        lines.append(f"- Waiting for: audio evidence covering the {waiting_for}")
    if error:
        lines.append(f"- Last error: {error}")
    lines += ["", "_This file is replaced by the finished note._"]
    return "\n".join(lines) + "\n"
