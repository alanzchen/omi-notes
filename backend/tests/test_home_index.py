"""Home's request paths do work proportional to the page, never to the number of conversations (`home.py`): the
list, a day's short sessions, a kind and the per-day totals read indexed columns (`day`, `kind`, `speech_seconds`)
precomputed at processing time. Fakes only."""

from __future__ import annotations

import json
import re
import shutil
import time
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from omi_notes import home, views
from omi_notes.api import create_app
from omi_notes.db import Database

from .conftest import AUTH
from .helpers import STARTED, T0, convs
from .test_deferred import busy, fakes, short

CHICAGO = ZoneInfo("America/Chicago")
DEFERRED = {"policy": "short_speech", "threshold_s": 60.0, "speech_s": 9.0, "decided_at": 0,
            "provisional": {"class": "undetermined", "confidence": None, "rule_id": "none-v1", "model": None}}  # fmt: skip


def populate(db, days: int, per_day: int) -> None:
    """`days` days of `per_day` conversations: a third long with a note and a kind, a third short and deferred, a
    third short with a note; one failure per day."""
    now = time.time()
    rows = []
    for d in range(days):
        for k in range(per_day):
            start = T0 - d * 86400 + k * 300
            kind = ("dialogue", "monologue", "passive")[k % 3]
            cid = f"c{d:03d}-{k:03d}"
            if k % 3 == 0:
                status, speech, note, deferral = "done", 600.0, f"Conversations/{cid}.md", None
            elif k % 3 == 1:
                status, speech, note, deferral = "closed", 20.0, None, json.dumps(DEFERRED)
            else:
                status, speech, note, deferral = ("failed" if k == 2 else "done"), 30.0, f"Conversations/{cid}.md", None
            index = json.dumps({"recording_class": {"class": kind, "revision": 0}}) if note else None
            rows.append((cid, "d", start, start + 60, status, speech, note, deferral, index,
                         home.day_of(start, CHICAGO), now, now))  # fmt: skip
    db.conn().executemany(
        "INSERT INTO conversations (id, device_id, start, end, status, speech_seconds, note_path, deferral, index_json, "
        "day, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", rows)  # fmt: skip


class Recorder:
    """Every SQL statement the API runs, with its parameters."""

    def __init__(self, monkeypatch):
        self.statements: list[tuple[str, tuple]] = []
        for name in ("query", "one", "execute"):
            real = getattr(Database, name)

            def wrap(db, sql, params=(), _real=real):
                self.statements.append((sql, tuple(params) if not isinstance(params, dict) else params))
                return _real(db, sql, params)

            monkeypatch.setattr(Database, name, wrap)

    def on_conversations(self) -> list[tuple[str, tuple]]:
        return [(s, p) for s, p in self.statements if re.search(r"\bFROM conversations\b", s)]


def full_scans(db, statements) -> list[str]:
    """Statements whose plan may read the whole conversations table: any scan, except walking the start index
    newest first up to a LIMIT with no filter beyond the listing's own (a page of the unfiltered list). A filter
    (a day, a kind, a JSON field) must be an index search."""
    out = []
    for sql, params in statements:
        plan = db.query("EXPLAIN QUERY PLAN " + sql, params)
        details = [r["detail"] for r in plan]
        for d in details:
            if not d.startswith("SCAN conversations"):
                continue
            paged = re.search(r"USING INDEX conversations_(start|listed)$", d) is not None and "LIMIT" in sql
            filtered = re.search(r"\b(kind|day)\s*(=|IN)|json_extract\(index_json|speech_seconds", sql)
            if not paged or filtered:
                out.append(f"{sql}\n  -> {details}")
    return out


PATHS = [
    "/v1/conversations/recent?limit=20",
    "/v1/conversations/recent?limit=20&class=monologue",
    "/v1/conversations/recent?limit=20&class=undetermined",
    "/v1/conversations/recent?limit=200&day={day}&short=true",
    "/v1/conversations/recent?limit=20&day={day}&short=false",
]


def run_paths(client, day: str) -> None:
    for path in PATHS:
        r = client.get(path.format(day=day), headers=AUTH)
        assert r.status_code == 200, (path, r.text)


@pytest.mark.parametrize("days", [3, 40])
def test_home_list_queries_use_indexes_and_a_fixed_number_of_statements(client, worker, monkeypatch, days):
    populate(worker.db, days, 12)
    day = home.day_of(T0, CHICAGO)
    rows_built = []
    real = views.summary_row
    monkeypatch.setattr(views, "summary_row", lambda pipeline, row: rows_built.append(row["id"]) or real(pipeline, row))
    rec = Recorder(monkeypatch)
    run_paths(client, day)
    statements = rec.on_conversations()
    assert len(rows_built) <= 20 * 4 + 12, "a summary is built only for the rows of each page"
    assert not full_scans(worker.db, statements), full_scans(worker.db, statements)
    # the same paths run the same statements whatever the number of conversations
    counts = {}
    for path in PATHS:
        rec.statements.clear()
        client.get(path.format(day=day), headers=AUTH)
        counts[path] = len(rec.on_conversations())
    if days == 3:
        test_home_list_queries_use_indexes_and_a_fixed_number_of_statements.small = counts
    else:
        assert counts == test_home_list_queries_use_indexes_and_a_fixed_number_of_statements.small


def test_day_totals_count_the_whole_day_in_one_query_without_a_python_loop(client, worker, monkeypatch):
    populate(worker.db, 2, 30)
    from omi_notes import deferral

    calls = []
    real = deferral.waiting
    monkeypatch.setattr(deferral, "waiting", lambda row: calls.append(row["id"]) or real(row))
    rec = Recorder(monkeypatch)
    body = client.get("/v1/conversations/recent?limit=1", headers=AUTH).json()
    day = home.day_of(T0, CHICAGO)
    # 20 short per day (k % 3 in (1, 2)): 10 deferred waiting, one failure (k == 2)
    assert body["days"] == {day: {"short": 20, "deferred": 10, "requested": 0, "issues": 1}}
    assert len(calls) <= 1, "per-row predicates run only for the page's own rows"
    totals = [s for s, _ in rec.on_conversations() if "GROUP BY day" in s]
    assert len(totals) == 1


def test_the_kind_filter_lists_undetermined_and_owner_choices_and_survives_a_rebuild(client, worker, settings, monkeypatch):
    fakes(worker)
    busy(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["day"] == "2026-09-26" and row["kind"] == "undetermined"

    def ids(cls):
        return [c["id"] for c in client.get(f"/v1/conversations/recent?class={cls}", headers=AUTH).json()["conversations"]]

    assert ids("undetermined") == [row["id"]] and ids("monologue") == []
    r = client.put(f"/v1/conversations/{row['id']}/class",
                   json={"class": "monologue", "request_id": "r1", "set_at": "2026-11-08T20:00:00Z"}, headers=AUTH)  # fmt: skip
    assert r.status_code == 200, r.text
    assert ids("monologue") == [row["id"]] and ids("undetermined") == []
    shutil.rmtree(settings.index_dir)
    again = TestClient(create_app(settings, start_worker=False))
    assert [c["id"] for c in again.get("/v1/conversations/recent?class=monologue", headers=AUTH).json()["conversations"]] == [row["id"]]
    assert again.get("/v1/conversations/recent?class=bogus", headers=AUTH).status_code == 422


def test_days_are_written_with_the_row_and_redone_when_the_timezone_changes(client, worker, settings, monkeypatch):
    fakes(worker)
    busy(worker, monkeypatch)
    late = STARTED.replace(hour=4)  # 23:00 the day before in Chicago, 06:00 in Paris
    short(client, at=late)
    worker.tick(late.timestamp() + 400)
    (row,) = convs(worker)
    assert row["day"] == "2026-09-25"
    home.ensure_days(worker.db, "Europe/Paris")
    assert convs(worker)[0]["day"] == "2026-09-26"
    worker.db.execute("UPDATE conversations SET day=NULL")
    assert home.fill_days(worker.db, CHICAGO) == 1 and convs(worker)[0]["day"] == "2026-09-25"
