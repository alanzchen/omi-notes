"""Home's and the status card's request paths do work bounded by the page, not by history (Astra, review of main
9b11b7c). Work is measured in SQLite VM steps (`set_progress_handler`) at two data sizes whose answers are
identical: the bigger index only adds older history. Fakes only."""

from __future__ import annotations

import json
import time
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from omi_notes import home
from omi_notes.db import Database

from .conftest import AUTH
from .helpers import T0

CHICAGO = ZoneInfo("America/Chicago")
DEFERRED = json.dumps({"policy": "short_speech", "threshold_s": 60.0, "speech_s": 20.0, "decided_at": 0,
                       "provisional": {"class": "undetermined", "confidence": None, "rule_id": "none-v1", "model": None}})
STEP = 10  # the progress handler runs every STEP VM instructions


class Steps:
    """VM instructions run on every index connection while active (all threads)."""

    def __init__(self, monkeypatch):
        self.n = 0
        self.on = False
        real = Database.conn

        def conn(db):
            c = real(db)
            c.set_progress_handler(self._tick, STEP)  # every time: a closed connection's id can be reused
            return c

        monkeypatch.setattr(Database, "conn", conn)

    def _tick(self) -> int:
        if self.on:
            self.n += STEP
        return 0

    def measure(self, fn):
        self.n, self.on = 0, True
        try:
            out = fn()
        finally:
            self.on = False
        return out, self.n


def rows_for(day_offset: int, per_day: int, prefix: str, *, base: float) -> list[dict]:
    out = []
    for k in range(per_day):
        start = base - day_offset * 86400 + k * 300
        kind = ("dialogue", "monologue", "passive")[k % 3]
        long = k % 3 == 0
        deferred = k % 3 == 1
        note = None if deferred else f"Conversations/{prefix}{day_offset}-{k}.md"
        out.append({
            "id": f"{prefix}{day_offset:06d}-{k:03d}", "device_id": "d", "start": start, "end": start + 60,
            "status": "closed" if deferred else ("failed" if k == 2 else "done"),
            "speech_seconds": 600.0 if long else 20.0, "note_path": note, "deferral": DEFERRED if deferred else None,
            "index_json": json.dumps({"recording_class": {"class": kind, "revision": 0}}) if note else None,
            "edited": 1 if k == 5 else 0, "done_at": start + 500 if note else None,
            "relevance": "too_short" if k == 7 else None,
        })  # fmt: skip
    return out


def populate(db, *, older: int = 0, newer: int = 0, crowd: int = 0, others: int = 0, per_day: int = 12) -> None:
    """The same 5 days of answers in every size, plus history: `older` days before them, `newer` days after them
    (a deep page then has many newer rows above it), and `crowd` more done notes earlier on DAY (a day's page
    then has many more rows of that day below it), and `others` newer monologue notes, short and long (a kind's page
    then has many newer rows of other kinds above it)."""
    now = time.time()
    rows = [r for d in range(5) for r in rows_for(d, per_day, "r", base=T0)]
    rows += [r for d in range(older) for r in rows_for(d, per_day, "o", base=T0 - 400 * 86400)]
    rows += [r for d in range(newer) for r in rows_for(-d, per_day, "n", base=T0 + 400 * 86400)]
    day_start = datetime.fromisoformat(DAY).replace(tzinfo=CHICAGO).timestamp()
    for k in range(crowd):
        start = day_start + k * (T0 - 86400 - day_start - 10) / max(crowd, 1)
        rows.append(rows_for(0, 1, "x", base=start)[0] | {
            "id": f"c{k:06d}", "speech_seconds": 20.0 if k % 2 else 600.0, "status": "done", "deferral": None,
            "note_path": f"Conversations/c{k}.md", "edited": 0, "relevance": None,
            "index_json": json.dumps({"recording_class": {"class": "dialogue", "revision": 0}})})  # fmt: skip
    for k in range(others):
        start = T0 + 400 * 86400 + k * 600
        rows.append(rows_for(0, 1, "w", base=start)[0] | {
            "id": f"w{k:06d}", "speech_seconds": 20.0 if k % 2 else 600.0, "status": "done", "deferral": None,
            "note_path": f"Conversations/w{k}.md", "edited": 0, "relevance": None,
            "index_json": json.dumps({"recording_class": {"class": "monologue", "revision": 0}})})  # fmt: skip
    cols = list(rows[0]) + ["created_at", "updated_at"]
    with db.tx() as conn:
        conn.executemany(f"INSERT INTO conversations ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
                         [(*(r[c] for c in cols[:-2]), now, now) for r in rows])  # fmt: skip
    home.ensure_home(db, "America/Chicago", 60.0)


DAY = home.day_of(T0 - 86400, CHICAGO)
CURSOR_ROW = ("r000001-004", T0 - 86400 + 4 * 300)
CURSOR = f"{CURSOR_ROW[1]}:{CURSOR_ROW[0]}"
# path, the history that grows, whether the page's day totals are the same in both sizes
PATHS = {
    "first page": ("/v1/conversations/recent?limit=20", "older", True),
    "cursor page": (f"/v1/conversations/recent?limit=20&before={CURSOR}", "newer", True),
    "class page": (f"/v1/conversations/recent?limit=5&class=dialogue&before={CURSOR}", "newer", True),
    "day short page": (f"/v1/conversations/recent?limit=3&day={DAY}&short=true", "crowd", False),
    "day long page": (f"/v1/conversations/recent?limit=2&day={DAY}&short=false", "crowd", False),
    "day page": (f"/v1/conversations/recent?limit=3&day={DAY}", "crowd", False),
    # combined filters: fewer matches than the limit, so a wrong index walks every nonmatching row
    "class day page": (f"/v1/conversations/recent?limit=10&class=passive&day={DAY}", "crowd", False),
    "class short page": ("/v1/conversations/recent?limit=50&class=passive&short=true", "others", True),
    "class long page": ("/v1/conversations/recent?limit=50&class=dialogue&short=false", "others", True),
    "class day short page": (f"/v1/conversations/recent?limit=10&class=passive&day={DAY}&short=true", "crowd", False),
}


def run(client, steps, path):
    r, n = steps.measure(lambda: client.get(path, headers=AUTH))
    assert r.status_code == 200, r.text
    body = r.json()
    return [c["id"] for c in body["conversations"]], body.get("days"), n


@pytest.fixture
def sized(tmp_path, monkeypatch):
    """A client over an index with this much history (`populate`)."""
    from fastapi.testclient import TestClient

    from omi_notes.api import create_app

    from .conftest import make_settings

    def make(**history):
        settings = make_settings(tmp_path / "-".join(f"{k}{v}" for k, v in history.items()))
        client = TestClient(create_app(settings, start_worker=False))
        populate(client.app.state.speakers.pipeline.db, **history)
        return client

    return make


@pytest.mark.parametrize("name", list(PATHS))
def test_a_page_costs_the_same_whatever_the_history(sized, monkeypatch, name):
    path, kind, same_totals = PATHS[name]
    steps = Steps(monkeypatch)
    small, big = sized(**{kind: 20}), sized(**{kind: 2000})  # about 300 vs 24,000 conversations
    run(small, steps, path)
    run(big, steps, path)  # warm both
    ids_small, days_small, n_small = run(small, steps, path)
    ids_big, days_big, n_big = run(big, steps, path)
    assert ids_small and ids_small == ids_big
    if same_totals:
        assert days_small == days_big
    assert n_big <= n_small * 1.3 + 2000, f"{name}: {n_small} VM steps with the small history, {n_big} with the big one"
