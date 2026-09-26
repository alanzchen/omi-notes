from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import yaml

from omi_notes.notes.daily import DailyEntry, render_daily
from omi_notes.notes.render import NoteData, render_note, render_stub
from omi_notes.notes.schema import ConversationNotes
from omi_notes.notes.writer import (
    MY_NOTES_END,
    MY_NOTES_START,
    conversation_relpath,
    extract_my_notes,
    sanitize_title,
    write_if_changed,
)

from .conftest import FIXTURES

TZ = ZoneInfo("America/Chicago")
T0 = datetime(2026, 9, 26, 14, 3, 12, tzinfo=TZ).timestamp()


def sample() -> NoteData:
    notes = ConversationNotes.model_validate(
        {
            "title": "Team Finalizes Q2 Budget",
            "emoji": "💰",
            "category": "work",
            "overview": "The team agreed on the Q2 budget and split the follow-ups.\nPriya owns the analytics events.",
            "sections": [
                {"heading": "Budget", "bullets": ["The budget was approved at the proposed level."]},
                {"heading": "Launch", "bullets": ["Offline sync still needs testing on a real phone."]},
            ],
            "action_items": [
                {"description": "Send the battery report", "owner": "other", "owner_name": "Daniel",
                 "due_date": "2026-10-02", "context": "Needed before the launch review."},
                {"description": "Book the dentist", "owner": "me"},
            ],  # fmt: skip
            "decisions": ["Test offline sync on Thursday"],
            "open_questions": ["Does the free tier keep offline sync?"],
            "events": [{"title": "Launch review", "start_local_iso": "2026-10-05T10:00", "duration_min": 45}],
            "people": [{"name": "Daniel", "note": "built the pairing screen"}],
            "memorable_facts": ["Daniel prefers async updates"],
            "speaker_names": [{"label": "S2", "name": "Daniel"}],
            "tags": ["launch", "budget"],
        }
    )
    segments = [
        {"start": T0, "end": T0 + 4, "speaker": "S1", "text": "Hi Daniel, thanks for making time."},
        {"start": T0 + 5, "end": T0 + 9, "speaker": "S2", "text": "Sure. I'll send the battery report by Friday."},
        {"start": T0 + 40, "end": T0 + 44, "speaker": "S1", "text": "Great, let's test offline sync on Thursday."},
    ]
    return NoteData(
        id="0192f6c1-0000-7000-8000-000000000001",
        status="completed",
        start=T0,
        end=T0 + 44,
        tz=TZ,
        segments=segments,
        speech_seconds=40,
        notes=notes,
        audio_gaps=[[T0 + 20, T0 + 25]],
        sources=["live"],
        device="Omi CV 1 · fw 3.0.21",
        stt="deepgram/nova-3",
        llm="claude-opus-5",
        prompt_version=1,
        revision=1,
        processed_at=T0 + 300,
        bookmarks=[T0 + 10],
        owner_name="Alan",
    )


def test_golden_note():
    golden = FIXTURES / "golden_note.md"
    rendered = render_note(sample())
    if not golden.exists():  # first run writes the golden file for review
        golden.write_text(rendered)
    assert rendered == golden.read_text()


def test_frontmatter_is_valid_yaml_even_with_hostile_titles():
    data = sample()
    data.notes.title = 'Deal: "yes" --- # not a comment\nstatus: hacked'
    text = render_note(data)
    front = yaml.safe_load(text.split("---\n")[1])
    assert front["title"] == 'Deal: "yes" --- # not a comment status: hacked' and front["status"] == "completed"


def test_my_notes_roundtrip():
    text = render_note(sample(), "\nMy own thoughts\n- keep me\n")
    assert extract_my_notes(text) == "\nMy own thoughts\n- keep me\n"
    assert f"{MY_NOTES_START}\nMy own thoughts\n- keep me\n{MY_NOTES_END}" in text
    assert extract_my_notes("no markers") is None


def test_discarded_and_transcript_only_variants():
    data = sample()
    data.status, data.discard_reason = "discarded", "microphone check"
    text = render_note(data)
    assert "Discarded: microphone check" in text and "## Transcript" in text
    data.status, data.summary_error = "transcript_only", "Anthropic auth error"
    text = render_note(data)
    assert "Summary unavailable (Anthropic auth error)" in text and "## Key Points" not in text
    assert "# Conversation" in text


def test_filenames_are_sanitized():
    assert sanitize_title('A/B: "C" #tag [[x]] | y?') == "A B C tag x y"
    assert sanitize_title("   ") == "Conversation"
    assert len(sanitize_title("word " * 40)) <= 80
    start = datetime(2026, 9, 26, 14, 3, tzinfo=TZ)
    assert conversation_relpath(start, "Team: Budget") == "Conversations/2026/2026-09/2026-09-26 1403 Team Budget.md"


def test_write_if_changed(tmp_path: Path):
    path = tmp_path / "a" / "b.md"
    assert write_if_changed(path, "x") is True
    mtime = path.stat().st_mtime_ns
    assert write_if_changed(path, "x") is False and path.stat().st_mtime_ns == mtime
    assert write_if_changed(path, "y") is True and path.read_text() == "y"
    assert not list(path.parent.glob(".*.tmp"))


def test_stub_and_daily_render():
    stub = render_stub(conv_id="abc", status="open", start=T0, end=T0 + 30, tz=TZ, speech_seconds=25,
                       waiting_for="end window", error=None)  # fmt: skip
    assert "Recording" in stub and "end window" in stub
    day = datetime(2026, 9, 26).date()
    daily = render_daily(
        day,
        [
            DailyEntry(start=T0, end=T0 + 600, status="completed", title="Budget | Review", emoji="💰",
                       relpath="Conversations/2026/2026-09/2026-09-26 1403 Budget Review.md",
                       action_items=["Send report — **Daniel**"], speech_seconds=500, stt_seconds=500,
                       llm_model="claude-opus-5", llm_usage={"input_tokens": 3000, "output_tokens": 800}),
            DailyEntry(start=T0 + 3600, end=T0 + 3610, status="discarded", title="x", relpath="_discarded/x.md",
                       discard_reason="microphone check", speech_seconds=5),
            DailyEntry(start=T0 + 7200, end=T0 + 7300, status="in_progress", title="Conversation"),
        ],
        TZ,
    )  # fmt: skip
    assert "| 14:03 | 💰 | [[Conversations/2026/2026-09/2026-09-26 1403 Budget Review\\|Budget - Review]] | 10 min |" in daily
    assert "- Send report — **Daniel** · [[" in daily
    assert "## Discarded" in daily and "## In Progress" in daily
    assert "- [ ]" not in daily  # never duplicate tasks for Obsidian Tasks
    assert "$0.04 transcription + $0.04 summaries" in daily
