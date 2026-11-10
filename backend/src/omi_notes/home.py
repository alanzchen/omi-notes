"""What Home's request paths read, precomputed into indexed columns (docs/capture-format-v1.md, "Home").

Every endpoint the phone's Home uses (the list, a day's short sessions, a kind, the per-day totals, a detail, a
transcription request, a class change) does work bounded by its page, never by the number of conversations:

- `day` and `short`: the local day of a conversation's start in the vault's timezone, and whether its speech is
  under the short-session threshold. Written with the row (segmentation), filled on opening the index (a rebuild
  leaves them NULL) and refilled for every row when the timezone or the threshold changes (`ensure_home`); the
  worker fills any row a write path left without them, in small batches.
- `class_choice`: the owner's recording-class choice from `class.json` (NULL for auto).
- `kind` (a generated column): the class a row is listed under.
- Partial indexes over the listed rows in list order, (start, id) alone and after kind, day, day + short and
  short: every filter is a seek and the LIMIT ends the walk.
- `day_totals`: per day, its listed short sessions and how many wait, were asked for or need a look; kept by
  triggers in the same transaction as every conversation row change (`db.py`), recomputable (`rebuild_totals`).
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

KINDS = ("monologue", "dialogue", "passive", "undetermined")
FILL_BATCH = 500
TOTALS = ("short", "deferred", "requested", "issues")


def timezone_name(settings, vault) -> str:
    """TIMEZONE when set explicitly, else the vault's (`ConversationPipeline.timezone`)."""
    if "timezone" in settings.model_fields_set or not vault.timezone:
        return settings.timezone
    return vault.timezone


def short_threshold(settings) -> float:
    """Detected speech below which a session is short: deferred on the server, folded on the phone."""
    return float(settings.defer_speech_seconds or 60.0)


def day_of(epoch: float, tz: ZoneInfo) -> str:
    return datetime.fromtimestamp(epoch, tz).date().isoformat()


def is_short(speech_seconds: float | None, threshold: float) -> int:
    return int((speech_seconds or 0.0) < threshold)


def fill_home(db, tz: ZoneInfo, threshold: float, *, limit: int | None = FILL_BATCH) -> int:
    """Set `day` and `short` on rows without a day (a bounded batch; None: all of them)."""
    sql = "SELECT id, start, speech_seconds FROM conversations WHERE day IS NULL" + (
        "" if limit is None else f" LIMIT {int(limit)}")  # fmt: skip
    rows = db.query(sql)
    if rows:
        with db.tx() as conn:
            conn.executemany("UPDATE conversations SET day=?, short=? WHERE id=? AND day IS NULL",
                             [(day_of(r["start"], tz), is_short(r["speech_seconds"], threshold), r["id"])
                              for r in rows])  # fmt: skip
    return len(rows)


def ensure_home(db, tz_name: str, threshold: float) -> None:
    """On opening the index: every row's day and short flag for this timezone and threshold (all of them again
    when either changed), and the per-day totals (recomputed once for an index that has none recorded)."""
    key = f"{tz_name}|{threshold!r}"
    if db.meta("home_key") != key:
        db.execute("UPDATE conversations SET day=NULL, short=NULL")
        db.set_meta("home_key", key)
    fill_home(db, ZoneInfo(tz_name), threshold, limit=None)
    if db.meta("day_totals") != "1":
        rebuild_totals(db)


def rebuild_totals(db) -> None:
    """`day_totals` from the rows (the triggers keep it after that)."""
    with db.tx() as conn:
        conn.execute("DELETE FROM day_totals")
        conn.execute("""INSERT INTO day_totals (day, short, deferred, requested, issues)
                        SELECT day, SUM(t_short), SUM(t_deferred), SUM(t_requested), SUM(t_issue)
                        FROM conversations WHERE t_short = 1 GROUP BY day""")
        conn.execute("INSERT INTO meta (key, value) VALUES ('day_totals', '1') "
                     "ON CONFLICT(key) DO UPDATE SET value=excluded.value")


def day_totals(db, days: set[str] | list[str]) -> dict:
    """Per local day, over every listed conversation of that day (not one page, not one filter): its short sessions,
    how many wait deferred, how many the owner asked to transcribe and aren't done, and how many need a look. One
    primary-key lookup per day in `day_totals`."""
    days = sorted(set(days))
    if not days:
        return {}
    out = {d: dict.fromkeys(TOTALS, 0) for d in days}
    marks = ",".join("?" * len(days))
    for r in db.query(f"SELECT * FROM day_totals WHERE day IN ({marks})", tuple(days)):
        out[r["day"]] = {k: int(r[k]) for k in TOTALS}
    return out


def set_choice(db, conv_id: str, choice: str | None) -> None:
    """The index copy of `class.json` (already written): NULL for auto."""
    db.execute("UPDATE conversations SET class_choice=? WHERE id=?", (choice if choice in KINDS[:3] else None, conv_id))
