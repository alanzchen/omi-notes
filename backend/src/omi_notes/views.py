"""Read-only projections for the phone app (capture-format-v1.md, "App views").

Nothing here writes: no provider calls, no label migration, no index repair. The index row says
which transcript and summary are current; an artifact that belongs to another generation (a
reprocess in flight) is reported as updating rather than mixed into the answer. Error text shown
to the user is chosen by `error_kind`, never the provider's exception string.
"""

from __future__ import annotations

import json
import math
import os
import shlex
import sqlite3
import sys
from pathlib import Path

from pydantic import ValidationError

from .notes.schema import ConversationNotes
from .notes.writer import UserRegionError, extract_my_notes, generated_sha, read_note_id
from .util import canonical_json, iso_utc_epoch, sha256_hex

PREVIEW_CHARS = 160
SEGMENT_PAGE = 500
ISSUE_LIMIT = 20

# Rows the app lists: voice-enrollment readings are never conversations.
LISTED = "enrollment_id IS NULL AND COALESCE(waiting_for, '') <> 'voice enrollment'"

_SERVICE = {"transcribing": "transcription service", "summarizing": "summary service"}


def failure_message(kind: str | None, stage: str | None) -> str:
    service = _SERVICE.get(stage or "", "processing service")
    return {
        "auth": f"The {service} rejected the server's credentials.",
        "billing": f"The {service} refused the request because of the account's billing or quota.",
        "config": f"The {service} isn't configured correctly on the server.",
        "transient": f"The {service} is temporarily unavailable.",
        "diarization": "The server couldn't tell the speakers apart.",
        "audio": "There was no usable audio in this conversation.",
        "notes": "The note's My Notes section is ambiguous, so the server won't overwrite it.",
        "io": "The server couldn't write the note file.",
        "move": "The server couldn't move the note file.",
    }.get(kind or "", f"The {service} failed.")


def command(args: str) -> str:
    """A command line for this deployment: the server's own `omi-notes` and environment file, so
    it acts on this vault rather than whatever an unconfigured shell would pick."""
    exe = Path(sys.executable).with_name("omi-notes")
    env = os.environ.get("OMI_NOTES_ENV_FILE")
    prefix = f"OMI_NOTES_ENV_FILE={shlex.quote(env)} " if env else ""
    return f"`{prefix}{shlex.quote(str(exe)) if exe.exists() else 'omi-notes'} {args}`"


def next_step(kind: str | None, stage: str | None, *, retrying: bool) -> str:
    """What to do, given whether the server will try again on its own (`retrying`) or gave up."""
    mac = " If transcription runs on a Mac, make sure it is awake and logged in." if stage == "transcribing" else ""
    if retrying:
        return ("The server retries on its own." + mac) if kind in ("transient", None, "io", "move") else \
            "The server retries on its own, but this usually needs a fix first: " + next_step(kind, stage, retrying=False)
    retry = f"then retry on the server with {command('retry-failed')}."
    if kind in ("auth", "billing", "config"):
        return "Fix the provider's key, account or settings on the server, " + retry
    if kind == "transient":
        return "The server stopped retrying after several attempts." + mac + " Once the service works again, " + retry
    if kind == "notes":
        return "Fix the My Notes markers in the note by hand, " + retry
    if kind in ("io", "move"):
        return "Check the vault folder's disk space and permissions, " + retry
    return "See _status.md in your vault for details, " + retry


# -- conversation state ---------------------------------------------------------------------------


def _waiting_message(waiting_for: str | None) -> str:
    if waiting_for == "end window":
        return "Waiting to see whether the conversation continues"
    if waiting_for == "start window":
        return "Waiting for earlier audio"
    return "Waiting for more audio"


def state(row: sqlite3.Row) -> dict:
    """The display chip: one code per row, by explicit precedence. The raw `status` stays alongside."""
    status = row["status"]
    if status == "open":
        return {"code": "listening", "message": _waiting_message(row["waiting_for"])}
    if status in ("closed", "transcribing", "summarizing"):
        if row["error"] and row["next_attempt_at"]:
            return {"code": "retrying", "message": failure_message(row["error_kind"], _stage(status)) + " Retrying."}
        return {"code": "processing", "message": "Writing the summary" if status == "summarizing" else "Transcribing"}
    if status == "discarded":
        return {"code": "discarded", "message": "Skipped: " + (_index(row).get("discard_reason") or "nothing worth keeping")}
    if status == "failed":
        if row["note_path"] and row["failed_stage"] == "summarizing":
            return {"code": "transcript_only", "message": "Transcript ready; summary unavailable"}
        if row["note_path"]:
            return {"code": "ready", "message": "Note ready"}  # an earlier note survives a failed reprocess
        return {"code": "failed", "message": failure_message(row["error_kind"], row["failed_stage"])}
    if row["llm_status"] == "none":
        return {"code": "transcript_only", "message": "Transcript ready; summaries are turned off"}
    return {"code": "ready", "message": "Note ready"}


def issues(row: sqlite3.Row) -> list[dict]:
    """Problems that coexist with readable content (caveats like provisional are separate fields)."""
    out = []
    if row["status"] == "failed" and row["note_path"] and row["failed_stage"] != "summarizing":
        out.append({"code": "reprocess_failed", "message": "Reprocessing failed; showing the earlier note. "
                    + failure_message(row["error_kind"], row["failed_stage"])})  # fmt: skip
    if row["edited"] and not row["frozen"] and row["note_path"]:
        out.append({"code": "note_conflict", "message": "The note was changed outside My Notes, so the server stopped "
                    "updating it."})  # fmt: skip
    elif row["status"] in ("done", "discarded") and row["needs_render"] and row["error"] and row["next_attempt_at"]:
        out.append({"code": "render_retrying", "message": failure_message(row["error_kind"], None) + " Retrying."})
    return out


def _stage(status: str) -> str:
    return "summarizing" if status == "summarizing" else "transcribing"


def _index(row: sqlite3.Row) -> dict:
    try:
        return json.loads(row["index_json"]) if row["index_json"] else {}
    except json.JSONDecodeError:
        return {}


def duration(row: sqlite3.Row) -> float:
    return round(max(0.0, row["end"] - row["start"]), 3)


# -- artifacts ------------------------------------------------------------------------------------


def summary(conv_dir: Path, row: sqlite3.Row) -> tuple[ConversationNotes | None, str]:
    """(notes, availability): ready | pending | disabled | failed | not_applicable | updating | unavailable."""
    if row["llm_status"] == "none":
        return None, "disabled"
    if not row["llm_ref"]:
        if row["status"] == "failed" and row["failed_stage"] == "summarizing":
            return None, "failed"
        if row["status"] == "discarded":
            return None, "not_applicable"
        return None, "pending" if row["status"] != "failed" else "unavailable"
    sha = row["transcript_sha"]
    if not sha or f"-{sha[:16]}" not in row["llm_ref"]:
        return None, "updating"  # the referenced summary was made from another transcript
    try:
        cached = json.loads((conv_dir / row["llm_ref"]).read_text())
        return ConversationNotes.model_validate(cached["data"]), "ready"
    except (OSError, ValueError, KeyError, TypeError, ValidationError):
        return None, "unavailable"


def transcript(conv_dir: Path, row: sqlite3.Row) -> tuple[list[dict] | None, str]:
    """(segments, availability): ready | pending | updating | unavailable."""
    if not row["transcript_sha"]:
        return None, "pending"
    try:
        segments = json.loads((conv_dir / "transcript.json").read_text())["segments"]
    except (OSError, ValueError, KeyError, TypeError):
        return None, "unavailable"
    if not isinstance(segments, list) or sha256_hex(canonical_json(segments).encode()) != row["transcript_sha"]:
        return None, "updating"
    return segments, "ready"


def speaker_names(store, conv_id: str, transcript_sha: str | None) -> dict[str, str]:
    """label → person name, only when the stored assignments were made for this transcript."""
    try:
        if not transcript_sha or store.labels_transcript(conv_id) != transcript_sha:
            return {}
        return {label: n["name"] for label, n in store.names(conv_id).items()}
    except (OSError, ValueError, TypeError, AttributeError, KeyError):
        return {}  # an unreadable speakers file costs the names, never the row


def note_file(root: Path, row: sqlite3.Row) -> dict:
    """The saved Markdown: whether it still matches what the server wrote, and the My Notes text."""
    out: dict = {"state": "none", "my_notes": None, "my_notes_unreadable": False}
    if not row["note_path"]:
        return out
    base = root.resolve()
    path = (root / row["note_path"]).resolve()
    if base not in path.parents:
        return out | {"state": "missing"}
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return out | {"state": "missing"}
    if read_note_id(path) != row["id"]:
        return out | {"state": "missing"}
    differs = bool(row["written_sha"]) and generated_sha(text) != row["written_sha"]
    out["state"] = "differs" if differs else "matches"
    try:
        mine = extract_my_notes(text)
        out["my_notes"] = (mine or "").strip() or None
    except UserRegionError:
        out["my_notes_unreadable"] = True
    return out


# -- responses ------------------------------------------------------------------------------------


def summary_row(pipeline, row: sqlite3.Row) -> dict:
    """One `/v1/conversations/recent` entry."""
    notes, _ = summary(pipeline.conv_dir(row["id"]), row)
    names = speaker_names(pipeline.speakers, row["id"], row["transcript_sha"])
    overview = notes.overview if notes else ""
    return {
        "id": row["id"],
        "status": row["status"],
        "state": state(row),
        "issues": issues(row),
        "started_at": iso_utc_epoch(row["start"]),
        "ended_at": iso_utc_epoch(row["end"]),
        "duration_s": duration(row),
        "title": row["title"] if row["note_path"] else None,
        "emoji": (_index(row).get("emoji") or None) if row["note_path"] else None,
        "preview": (overview[:PREVIEW_CHARS].rstrip() + ("…" if len(overview) > PREVIEW_CHARS else "")) or None,
        "speaker_names": sorted(set(names.values())),
        "note_path": row["note_path"],
        "late_audio": bool(row["late_audio"]),
        "provisional": bool(row["provisional"]),
        "speakers_ready": row["status"] != "open" and row["transcript_sha"] is not None,
    }


def parse_cursor(cursor: str) -> tuple[float, str] | None:
    start, sep, conv_id = cursor.partition(":")
    try:
        value = float(start)
    except ValueError:
        return None
    if not sep or not conv_id or not math.isfinite(value) or len(conv_id) > 64:
        return None
    return value, conv_id


def make_cursor(row: sqlite3.Row) -> str:
    return f"{row['start']!r}:{row['id']}"


def detail(pipeline, row: sqlite3.Row, *, segments_from: int = 0) -> dict:
    conv_dir = pipeline.conv_dir(row["id"])
    notes, summary_state = summary(conv_dir, row)
    segments, transcript_state = transcript(conv_dir, row)
    names = speaker_names(pipeline.speakers, row["id"], row["transcript_sha"]) if segments is not None else {}
    note = note_file(pipeline.settings.vault_dir, row)
    idx = _index(row)
    body = summary_row(pipeline, row) | {
        "speech_s": round(row["speech_seconds"], 3),
        "lost_s": round(row["lost_seconds"], 3),
        "note_state": note["state"],
        "note_frozen": bool(row["frozen"]),
        "my_notes": note["my_notes"],
        "my_notes_unreadable": note["my_notes_unreadable"],
        "discard_reason": idx.get("discard_reason") if row["status"] == "discarded" else None,
        "transcript_sha": row["transcript_sha"],
        "speakers_revision": row["speakers_revision"],
        "revision": row["revision"],
        "summary_state": summary_state,
        "summary": None,
        "transcript_state": transcript_state,
        "speakers": [],
        "transcript": None,
    }
    if row["status"] == "failed" and summary_state == "failed":
        body["summary_error"] = failure_message(row["error_kind"], "summarizing")
    if notes is not None:
        owner = _owner_name(pipeline, row)
        body["summary"] = {
            "overview": notes.overview,
            "sections": [{"heading": s.heading, "bullets": s.bullets} for s in notes.sections],
            "action_items": [
                {"description": a.description, "owner": a.owner,
                 "owner_name": owner if a.owner == "me" and owner else a.owner_name,
                 "due_date": a.due_date.isoformat() if a.due_date else None}  # fmt: skip
                for a in notes.action_items
            ],
            "decisions": notes.decisions,
            "open_questions": notes.open_questions,
        }
    if segments is not None:
        labels = sorted({s["speaker"] for s in segments}, key=_label_key)
        body["speakers"] = [{"label": label, "name": names.get(label)} for label in labels]
        first = max(0, segments_from)
        page = segments[first : first + SEGMENT_PAGE]
        body["transcript"] = {
            "total": len(segments),
            "from": first,
            "next_from": first + len(page) if first + len(page) < len(segments) else None,
            "segments": [
                {"start": iso_utc_epoch(s["start"]), "end": iso_utc_epoch(s["end"]), "speaker": s["speaker"],
                 "name": names.get(s["speaker"]), "text": s["text"]}  # fmt: skip
                for s in page
            ],
        }
    return body


def _owner_name(pipeline, row: sqlite3.Row) -> str:
    """The owner the note was rendered with (its settings snapshot), so renaming "me" later doesn't
    silently change who owned past action items."""
    try:
        snap = json.loads(row["settings_json"]) if row["settings_json"] else None
    except json.JSONDecodeError:
        snap = None
    return snap.get("owner_name", "") if isinstance(snap, dict) else pipeline.owner_name


def _label_key(label: str) -> tuple[int, str]:
    return (int(label[1:]) if label[1:].isdigit() else 10**6, label)


def worker_present(vault) -> bool:
    from .lock import worker_lock

    return worker_lock(vault).held_elsewhere()


def server_issues(db, *, read_only: str | None, worker: bool, limit: int = ISSUE_LIMIT) -> list[dict]:
    """Bounded, sanitized list of what needs attention (`GET /v1/issues`), most urgent first."""
    out: list[dict] = []
    if read_only:
        out.append({"code": "read_only", "severity": "action", "message": "The server stopped writing to the vault.",
                    "detail": read_only, "next_step": f"See _status.md in your vault; {command('doctor')} on the server explains the fix."})  # fmt: skip
    if not worker:
        out.append({"code": "worker_stopped", "severity": "action", "message": "The processing worker isn't running.",
                    "next_step": "Restart the Omi Notes service on the server."})  # fmt: skip
    chunks = db.one("SELECT COUNT(*) AS n FROM chunks WHERE status='failed'")["n"]
    if chunks:
        out.append({"code": "chunks_failed", "severity": "action", "count": chunks,
                    "message": f"{chunks} uploaded audio file{'s' if chunks != 1 else ''} couldn't be processed.",
                    "next_step": f"See _status.md in your vault, then retry on the server with {command('retry-failed')}."})  # fmt: skip

    def conv(r, code: str, severity: str, message: str, step: str) -> dict:
        return {"code": code, "severity": severity, "message": message, "next_step": step,
                "conversation_id": r["id"], "started_at": iso_utc_epoch(r["start"]),
                "title": r["title"] if r["note_path"] else None}  # fmt: skip

    for r in db.query(f"SELECT * FROM conversations WHERE status='failed' AND {LISTED} ORDER BY start DESC LIMIT ?", (limit,)):
        if r["note_path"] and r["failed_stage"] == "summarizing":
            message = "Transcript ready; summary unavailable. " + failure_message(r["error_kind"], "summarizing")
        else:
            message = failure_message(r["error_kind"], r["failed_stage"])
        out.append(conv(r, "conversation_failed", "action", message, next_step(r["error_kind"], r["failed_stage"], retrying=False)))
    for r in db.query(f"SELECT * FROM conversations WHERE edited=1 AND frozen=0 AND note_path IS NOT NULL AND {LISTED} "
                      "ORDER BY start DESC LIMIT ?", (limit,)):  # fmt: skip
        out.append(conv(r, "note_conflict", "action", "The note was changed outside My Notes; the server stopped updating it.",
                        f"On the server, run {command('note overwrite ' + r['id'])} to replace it (your version is kept "
                        f"aside), or {command('note freeze ' + r['id'])} to keep your version."))  # fmt: skip
    for r in db.query(f"SELECT * FROM conversations WHERE status IN ('closed','transcribing','summarizing') AND error IS NOT NULL "
                      f"AND next_attempt_at IS NOT NULL AND {LISTED} ORDER BY start DESC LIMIT ?", (limit,)):  # fmt: skip
        stage = _stage(r["status"])
        out.append(conv(r, "conversation_retrying", "delayed", failure_message(r["error_kind"], stage) + " Retrying.",
                        next_step(r["error_kind"], stage, retrying=True)))  # fmt: skip
    return out[:limit]


def last_note_at(db) -> str | None:
    """When the newest useful note was first written (discarded and enrollment rows excluded)."""
    r = db.one(f"SELECT MAX(done_at) AS t FROM conversations WHERE note_path IS NOT NULL "
               f"AND status IN ('done','failed') AND {LISTED}")  # fmt: skip
    return iso_utc_epoch(r["t"]) if r and r["t"] else None
