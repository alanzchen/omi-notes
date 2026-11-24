"""ASTRA-20261124-IT3-01: `/v1/status` activity and conflicts, and the `/v1/issues` lists, cost the same whatever the
queued, conflicted, failed or retrying population, with the same answers as the unbounded queries they replace."""

from __future__ import annotations

import random
import sqlite3
import uuid

from omi_notes import views
from omi_notes.db import COUNTERS_VERSION, Database

from .conftest import AUTH
from .test_read_cost_nov24 import add_conversations, endpoint, measure

ACTIVE = "status IN ('closed','transcribing','summarizing')"


def _old_activity(db, now: float) -> dict:
    """The queries `views.activity` ran before (unbounded), as the reference answer."""
    queue = f"{ACTIVE} AND {views.LISTED}"
    w = db.one(f"SELECT COUNT(*) AS n, MIN(\"end\") AS oldest FROM conversations WHERE {queue} "
               "AND (next_attempt_at IS NULL OR next_attempt_at <= ?) "
               "AND NOT (claim_token IS NOT NULL AND claim_expires > ?)", (now, now))  # fmt: skip
    b = db.one(f"SELECT COUNT(*) AS n FROM conversations WHERE {queue} AND next_attempt_at > ?", (now,))["n"]
    running = [r["id"] for r in db.query(f"SELECT id FROM conversations WHERE {queue} AND claim_token IS NOT NULL "
                                         "AND claim_expires > ? ORDER BY start LIMIT 5", (now,))]  # fmt: skip
    return {"waiting": w["n"], "oldest": views.iso_utc_epoch(w["oldest"]) if w["oldest"] else None, "backing_off": b,
            "running": running}


def _new_activity(db, settings, now: float) -> dict:
    a = views.activity(db, settings, now)
    return {"waiting": a["waiting"], "oldest": a["oldest_waiting_ended_at"], "backing_off": a["backing_off"],
            "running": [r["conversation_id"] for r in a["running"]]}


def test_activity_equals_the_unbounded_queries_through_random_states(tmp_path, settings):
    db = Database(tmp_path / "index.sqlite3")
    rng = random.Random(2411)
    statuses = ["open", "closed", "transcribing", "summarizing", "done", "failed"]
    for i in range(300):
        db.execute("INSERT INTO conversations(id,device_id,start,end,status,created_at,updated_at,next_attempt_at,"
                   "claim_token,claim_expires,enrollment_id,relevance) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                   (f"c{i}", "d", float(rng.randrange(1000)), float(rng.choice([5, 1000 + i])), rng.choice(statuses),
                    0.0, 0.0, rng.choice([None, 50.0, 150.0, 250.0]), rng.choice([None, None, "tok"]),
                    rng.choice([None, 80.0, 200.0]), rng.choice([None, None, None, "enr"]),
                    rng.choice([None, None, "too_short"])))  # fmt: skip
    for step in range(400):
        cid = f"c{rng.randrange(300)}"
        col, val = rng.choice([("status", rng.choice(statuses)), ("next_attempt_at", rng.choice([None, 50.0, 150.0, 250.0])),
                               ("claim_token", rng.choice([None, "tok"])), ("claim_expires", rng.choice([None, 80.0, 200.0])),
                               ("end", rng.choice([5.0, 900.0, 2000.0])), ("relevance", rng.choice([None, "too_short"]))])
        db.execute(f'UPDATE conversations SET "{col}"=? WHERE id=?', (val, cid))
        if step % 40 == 0:
            for now in (0.0, 100.0, 175.0, 300.0):
                assert _new_activity(db, settings, now) == _old_activity(db, now), (step, now)


def test_past_the_cap_the_split_is_unknown_not_a_guess(client, settings, monkeypatch):
    db = client.app.state.db
    monkeypatch.setattr(views, "ACTIVITY_CAP", 5)
    add_conversations(db, 0, 10, "closed")
    db.execute("UPDATE conversations SET next_attempt_at=1e12 WHERE start < 6")  # 6 backing off: over the cap of 5
    a = client.get("/v1/status", headers=AUTH).json()["activity"]
    assert a["waiting"] is None and a["backing_off"] is None and a["oldest_waiting_ended_at"] is None
    db.execute("UPDATE conversations SET next_attempt_at=NULL WHERE start = 0")  # 5: at the cap, exact again
    a = client.get("/v1/status", headers=AUTH).json()["activity"]
    assert a["waiting"] == 5 and a["backing_off"] == 5 and a["oldest_waiting_ended_at"] == "1970-01-01T00:00:01.000Z"


def _plans(db, sql: str, params: tuple) -> list[str]:
    return [r["detail"] for r in db.query("EXPLAIN QUERY PLAN " + sql, params)]


def test_the_activity_and_issue_queries_seek_their_own_index(client):
    """No SCAN of conversations and no temporary B-tree for ORDER BY: LIMIT stops early."""
    from omi_notes.db import ACTIVE_LISTED, ISSUE_CONFLICT, ISSUE_FAILED, ISSUE_RETRYING

    db = client.app.state.db
    q = ACTIVE_LISTED
    cases = {
        "issues failed": (f"SELECT * FROM conversations INDEXED BY conversations_issue_failed WHERE {ISSUE_FAILED} "
                          "ORDER BY start DESC LIMIT ?", (20,)),
        "issues conflict": (f"SELECT * FROM conversations INDEXED BY conversations_issue_conflict WHERE {ISSUE_CONFLICT} "
                            "ORDER BY start DESC LIMIT ?", (20,)),
        "issues retrying": (f"SELECT * FROM conversations INDEXED BY conversations_issue_retrying WHERE {ISSUE_RETRYING} "
                            "ORDER BY start DESC LIMIT ?", (20,)),
        "running": (f"SELECT id, status, start FROM conversations INDEXED BY conversations_claimed WHERE claim_token IS "
                    f"NOT NULL AND {q} AND claim_expires > ? ORDER BY start LIMIT 5", (0.0,)),
        "backing off": (f"SELECT COUNT(*) AS n FROM (SELECT 1 FROM conversations INDEXED BY conversations_active_retry_at "
                        f"WHERE {q} AND next_attempt_at IS NOT NULL AND next_attempt_at > ? LIMIT ?)", (0.0, 501)),
        "claimed": (f"SELECT COUNT(*) AS n FROM (SELECT 1 FROM conversations INDEXED BY conversations_claimed WHERE "
                    f"claim_token IS NOT NULL AND {q} AND (claim_expires > ? OR claim_expires IS NULL) AND NOT (next_attempt_at IS NOT NULL AND "
                    "next_attempt_at > ?) LIMIT ?)", (0.0, 0.0, 501)),
        "oldest waiting": (f'SELECT "end" FROM conversations INDEXED BY conversations_active_end WHERE {q} AND "end" IS '
                           'NOT NULL AND (next_attempt_at IS NULL OR next_attempt_at <= ?) AND NOT (claim_token IS NOT '
                           'NULL AND claim_expires > ?) ORDER BY "end" LIMIT 1', (0.0, 0.0)),
    }
    for name, (sql, params) in cases.items():
        plan = _plans(db, sql, params)
        print("PLAN", name, plan)
        assert any(p.startswith("SEARCH conversations USING INDEX") or p.startswith("SCAN conversations USING INDEX")
                   for p in plan), (name, plan)
        assert not any("TEMP B-TREE" in p for p in plan), (name, plan)
        assert not any(p == "SCAN conversations" for p in plan), (name, plan)


def _seed(db, a: int, b: int, kind: str) -> None:
    add_conversations(db, a, b, {"conflict": "done", "retrying": "closed", "backing": "closed"}[kind])
    if kind == "conflict":
        db.execute("UPDATE conversations SET edited=1, note_path='n.md' WHERE start >= ?", (float(a),))
    elif kind == "retrying":
        db.execute("UPDATE conversations SET error='boom', next_attempt_at=1.0 WHERE start >= ?", (float(a),))


def test_issue_lists_cost_the_page_not_the_population(client):
    f = endpoint(client, "/v1/issues")
    for kind in ("conflict", "retrying"):
        db = client.app.state.db
        db.execute("DELETE FROM conversations")
        _seed(db, 0, 100, kind)
        a = measure(db, lambda: f(limit=20))
        _seed(db, 100, 10_000, kind)
        b = measure(db, lambda: f(limit=20))
        print("ISSUES", kind, a[:2], b[:2])
        assert len(b[2]["issues"]) == 20
        assert b[0] <= a[0] * 2, (kind, a[:2], b[:2])


def test_status_cost_does_not_grow_with_a_due_retry_population(client):
    """Retries whose time has come are waiting work: counted by the totals, not walked."""
    db = client.app.state.db
    f = endpoint(client, "/v1/status")
    _seed(db, 0, 100, "retrying")
    a = measure(db, f)
    _seed(db, 100, 10_000, "retrying")
    b = measure(db, f)
    assert b[2]["activity"]["waiting"] == 10_000 and b[2]["queue"]["conversations_retrying"] == 10_000
    assert b[0] <= a[0] * 2, (a[:2], b[:2])


def test_an_index_with_older_counters_gets_new_triggers_and_a_recount(tmp_path):
    path = tmp_path / "index.sqlite3"
    db = Database(path)
    for i in range(4):
        db.execute("INSERT INTO conversations(id,device_id,start,end,status,created_at,updated_at,edited,note_path) "
                   "VALUES (?,?,?,?,?,?,?,1,'n.md')", (str(uuid.uuid4()), "d", float(i), float(i + 1), "done", 0.0, 0.0))
    conn = sqlite3.connect(path)  # as 405a2fe left it: version-1 triggers without the IT3-01 totals
    conn.executescript("DROP TRIGGER conversations_queue_insert; DROP TRIGGER conversations_queue_update; "
                       "DROP TRIGGER conversations_queue_delete; DELETE FROM queue_totals WHERE name IN "
                       "('conflicted','active_listed','scheduled_listed'); UPDATE meta SET value='1' WHERE key='counters';"
                       "CREATE TRIGGER conversations_queue_insert AFTER INSERT ON conversations BEGIN SELECT 1; END;")
    conn.close()
    again = Database(path)
    assert again.meta("counters") == COUNTERS_VERSION and again.queue_total("conflicted") == 4
    again.execute("INSERT INTO conversations(id,device_id,start,end,status,created_at,updated_at,edited,note_path) "
                  "VALUES ('x','d',9,10,'closed',0,0,1,'n.md')")
    assert again.queue_total("conflicted") == 5 and again.queue_total("active_listed") == 1, "the new triggers count"
