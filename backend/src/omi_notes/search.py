"""Search over what the app shows (docs/capture-format-v1.md, "Search").

The `search_index` table holds each conversation's title, summary, speaker names and transcript
text, made from the same generation-checked artifacts as the detail view. It is operational: the
worker fills it in small batches (after a rebuild, too), and every entry records the generation it
was made from (`source`). A query only uses entries whose source still matches the conversation,
so a stale entry is never an answer; conversations not indexed yet are counted as `pending`.
Matching is literal and case-insensitive (`str.casefold`); every word must appear.
"""

from __future__ import annotations

import sqlite3
import time

from . import views
from .util import iso_utc_epoch

BATCH = 20
# The generation an entry was made from, as SQL over the conversations row (keep in step with `source`).
SOURCE_SQL = ("COALESCE(c.transcript_sha, '') || ':' || COALESCE(c.llm_ref, '') || ':' || c.speakers_revision "
              "|| ':' || COALESCE(c.title, '')")  # fmt: skip
INDEXABLE = ("c.status IN ('done', 'failed', 'discarded') AND c.transcript_sha IS NOT NULL "
             "AND c.enrollment_id IS NULL AND COALESCE(c.waiting_for, '') <> 'voice enrollment'")


def source(row: sqlite3.Row) -> str:
    return f"{row['transcript_sha'] or ''}:{row['llm_ref'] or ''}:{row['speakers_revision']}:{row['title'] or ''}"


def _stale(db, limit: int):
    return db.query(
        f"""SELECT c.* FROM conversations c LEFT JOIN search_index s ON s.conversation_id = c.id
            WHERE {INDEXABLE} AND (s.source IS NULL OR s.source <> {SOURCE_SQL}) ORDER BY c.start DESC LIMIT ?""",
        (limit,),
    )


def pending(db) -> int:
    return db.one(
        f"""SELECT COUNT(*) AS n FROM conversations c LEFT JOIN search_index s ON s.conversation_id = c.id
            WHERE {INDEXABLE} AND (s.source IS NULL OR s.source <> {SOURCE_SQL})"""
    )["n"]


def body(pipeline, row: sqlite3.Row) -> str | None:
    """The searchable text, or None while the transcript is being replaced (try again later)."""
    conv_dir = pipeline.conv_dir(row["id"])
    segments, state = views.transcript(conv_dir, row)
    if segments is None:
        return None
    notes, _ = views.summary(conv_dir, row)
    names = views.speaker_names(pipeline.speakers, row["id"], row["transcript_sha"])
    parts = [row["title"] or ""]
    if notes is not None:
        parts.append(notes.overview)
        for section in notes.sections:
            parts += [section.heading, *section.bullets]
        parts += [a.description for a in notes.action_items]
        parts += notes.decisions + notes.open_questions
    parts += sorted(set(names.values()))
    parts += [s.get("text", "") for s in segments]
    return "\n".join(p for p in parts if p).casefold()


def index_batch(pipeline, limit: int = BATCH) -> int:
    """Index up to `limit` conversations whose entry is missing or stale. Per-row failures are
    skipped (the row stays pending) so one bad conversation never stalls the rest."""
    done = 0
    for row in _stale(pipeline.db, limit):
        try:
            text = body(pipeline, row)
        except Exception:
            continue
        if text is None:
            continue
        pipeline.db.execute(
            "INSERT INTO search_index (conversation_id, source, body) VALUES (?, ?, ?) "
            "ON CONFLICT(conversation_id) DO UPDATE SET source=excluded.source, body=excluded.body",
            (row["id"], source(row), text),
        )
        done += 1
    return done


def search(pipeline, *, q: str = "", person_id: str | None = None, start: float | None = None,
           end: float | None = None, before: tuple[float, str] | None = None, limit: int = 20) -> dict:  # fmt: skip
    where = ["c.enrollment_id IS NULL AND COALESCE(c.waiting_for, '') <> 'voice enrollment'"]
    params: list = []
    terms = q.casefold().split()
    if terms:
        where.append(f"s.source = {SOURCE_SQL}")
        for term in terms:
            where.append("instr(s.body, ?) > 0")
            params.append(term)
    if person_id:
        where.append("EXISTS (SELECT 1 FROM speaker_labels l WHERE l.conversation_id = c.id AND l.person_id = ?)")
        params.append(person_id)
    if start is not None:
        where.append("c.start >= ?")
        params.append(start)
    if end is not None:
        where.append("c.start < ?")
        params.append(end)
    if before is not None:
        where.append("(c.start < ? OR (c.start = ? AND c.id < ?))")
        params += [before[0], before[0], before[1]]
    join = "JOIN search_index s ON s.conversation_id = c.id" if terms else ""
    rows = pipeline.db.query(
        f"SELECT c.* FROM conversations c {join} WHERE {' AND '.join(where)} ORDER BY c.start DESC, c.id DESC LIMIT ?",
        (*params, limit + 1),
    )
    page = rows[:limit]
    return {
        "conversations": [views.summary_row(pipeline, r) for r in page],
        "next_cursor": views.make_cursor(page[-1]) if len(rows) > limit else None,
        "pending": pending(pipeline.db) if terms else 0,
        "searched_at": iso_utc_epoch(time.time()),
    }
