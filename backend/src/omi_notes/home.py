"""What Home's request paths read, precomputed into indexed columns (docs/capture-format-v1.md, "Home").

Every endpoint the phone's Home uses (the list, a day's short sessions, a kind, the per-day totals, a detail, a
transcription request, a class change) does work proportional to its page, never to the number of conversations:

- `day`: the local day of a conversation's start, in the vault's timezone, written with the row (segmentation, the
  rebuild) and refilled for every row when the timezone changes (`ensure_days`). A NULL day (a write path that
  didn't set it) is filled by the worker in small batches.
- `class_choice`: the owner's recording-class choice from `class.json` (NULL for auto), written after the file.
- `kind` (a generated column): the class a row is listed under. `speech_seconds` is already a column.
- The per-day short-session totals are one aggregate query over the `(day, speech_seconds)` index (`day_totals`).
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from .views import LISTED, NOT_DISMISSED

KINDS = ("monologue", "dialogue", "passive", "undetermined")
FILL_BATCH = 500

# the same predicates as `deferral.waiting`, `views.deferred_view` ("requested") and `views.issues` (+ a failure
# not dismissed), as SQL over one row
_WAITING = ("(deferral IS NOT NULL AND status IN ('closed','transcribing','summarizing') AND note_path IS NULL "
            "AND retry_op IS NULL AND transcribe_op IS NULL AND json_extract(deferral, '$.requested') IS NULL)")
_REQUESTED = (f"(deferral IS NOT NULL AND status IN ('closed','transcribing','summarizing') AND note_path IS NULL "
              f"AND NOT {_WAITING})")
_ISSUE = (f"((status = 'failed' AND {NOT_DISMISSED})"
          " OR (status = 'failed' AND note_path IS NOT NULL AND COALESCE(failed_stage, '') <> 'summarizing')"
          " OR (edited AND NOT frozen AND note_path IS NOT NULL)"
          " OR (status IN ('done','discarded') AND needs_render AND error IS NOT NULL AND next_attempt_at IS NOT NULL))")


def timezone_name(settings, vault) -> str:
    """TIMEZONE when set explicitly, else the vault's (`ConversationPipeline.timezone`)."""
    if "timezone" in settings.model_fields_set or not vault.timezone:
        return settings.timezone
    return vault.timezone


def day_of(epoch: float, tz: ZoneInfo) -> str:
    return datetime.fromtimestamp(epoch, tz).date().isoformat()


def fill_days(db, tz: ZoneInfo, *, limit: int | None = FILL_BATCH) -> int:
    """Set `day` on rows without one (a bounded batch; None: all of them)."""
    sql = "SELECT id, start FROM conversations WHERE day IS NULL" + ("" if limit is None else f" LIMIT {int(limit)}")
    rows = db.query(sql)
    if rows:
        with db.tx() as conn:
            conn.executemany("UPDATE conversations SET day=? WHERE id=? AND day IS NULL",
                             [(day_of(r["start"], tz), r["id"]) for r in rows])  # fmt: skip
    return len(rows)


def ensure_days(db, tz_name: str) -> None:
    """On opening the index: every row's day in this timezone (all of them again when it changed)."""
    tz = ZoneInfo(tz_name)
    if db.meta("day_tz") != tz_name:
        db.execute("UPDATE conversations SET day=NULL")
        db.set_meta("day_tz", tz_name)
    fill_days(db, tz, limit=None)


def day_totals(db, days: set[str] | list[str], threshold: float) -> dict:
    """Per local day, over every listed conversation of that day (not one page, not one filter): its short sessions,
    how many wait deferred, how many the owner asked to transcribe and aren't done, and how many need a look. One
    aggregate query on the (day, speech_seconds) index."""
    days = sorted(set(days))
    if not days:
        return {}
    marks = ",".join("?" * len(days))
    rows = db.query(
        f"""SELECT day, COUNT(*) AS short, SUM({_WAITING}) AS deferred, SUM({_REQUESTED}) AS requested,
                   SUM({_ISSUE}) AS issues
            FROM conversations
            WHERE day IN ({marks}) AND speech_seconds < ? AND status <> 'open' AND {LISTED}
            GROUP BY day""",
        (*days, threshold),
    )
    out = {d: {"short": 0, "deferred": 0, "requested": 0, "issues": 0} for d in days}
    for r in rows:
        out[r["day"]] = {k: int(r[k] or 0) for k in ("short", "deferred", "requested", "issues")}
    return out


def set_choice(db, conv_id: str, choice: str | None) -> None:
    """The index copy of `class.json` (already written): NULL for auto."""
    db.execute("UPDATE conversations SET class_choice=? WHERE id=?", (choice if choice in KINDS[:3] else None, conv_id))
