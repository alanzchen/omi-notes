"""ASTRA-20261124-IT1-02: `/v1/status` and `/v1/issues` read chunk and conversation counts from counters kept by triggers in the same
transaction as every chunk row change, and the counters always equal a COUNT over the rows."""

from __future__ import annotations

import sqlite3

import pytest

from omi_notes.db import Database


def _add(db: Database, a: int, b: int, status: str = "pending") -> None:
    with db.tx() as c:
        c.executemany(
            "INSERT INTO chunks(capture_id,chunk_sequence,device_id,source,sha256,size,path,received_at,start_epoch,"
            "end_epoch,start_offset_us,end_offset_us,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [("capture", i, "device", "pendant_pcm", str(i), 1, "x", float(i), float(i), float(i + 1), 0, 1, status)
             for i in range(a, b)],
        )


def _truth(db: Database) -> dict[str, int]:
    return {r["status"]: r["n"] for r in db.query("SELECT status, COUNT(*) AS n FROM chunks GROUP BY status")}


def _counted(db: Database) -> dict[str, int]:
    return {s: db.chunk_count(s) for s in ("pending", "processed", "failed") if db.chunk_count(s)}


def test_counters_follow_every_row_change(tmp_path):
    db = Database(tmp_path / "index.sqlite3")
    _add(db, 0, 10)
    assert _counted(db) == _truth(db) == {"pending": 10}
    db.execute("UPDATE chunks SET status='processed' WHERE chunk_sequence < 6")
    db.execute("UPDATE chunks SET status='failed' WHERE chunk_sequence = 9")
    db.execute("UPDATE chunks SET attempts=3 WHERE chunk_sequence = 8")  # no status change: no count change
    db.execute("UPDATE chunks SET status='pending' WHERE chunk_sequence = 7")  # same status
    assert _counted(db) == _truth(db) == {"pending": 3, "processed": 6, "failed": 1}
    db.execute("UPDATE chunks SET status='pending', attempts=0 WHERE status='failed'")  # retry-failed
    db.execute("DELETE FROM chunks WHERE chunk_sequence = 0")
    assert _counted(db) == _truth(db) == {"pending": 4, "processed": 5}


def test_a_rolled_back_change_leaves_the_counters_as_they_were(tmp_path):
    db = Database(tmp_path / "index.sqlite3")
    _add(db, 0, 5)
    with pytest.raises(RuntimeError):
        with db.tx() as c:
            c.execute("UPDATE chunks SET status='processed'")
            raise RuntimeError
    assert _counted(db) == _truth(db) == {"pending": 5}


def test_an_index_without_recorded_counters_counts_its_rows_once_on_open(tmp_path):
    """An index written before the counters existed (the live schema-12 index) gets them on open, without a rebuild."""
    path = tmp_path / "index.sqlite3"
    db = Database(path)
    _add(db, 0, 7)
    db.execute("UPDATE chunks SET status='processed' WHERE chunk_sequence < 2")
    conn = sqlite3.connect(path)  # as an older release left it: no counter tables, triggers or marker
    conn.executescript("DROP TRIGGER chunks_count_insert; DROP TRIGGER chunks_count_update; "
                       "DROP TRIGGER chunks_count_delete; DROP TABLE chunk_counts; "
                       "DROP TRIGGER conversations_queue_insert; DROP TRIGGER conversations_queue_update; "
                       "DROP TRIGGER conversations_queue_delete; DROP TABLE queue_totals; "
                       "DELETE FROM meta WHERE key='counters';")
    conn.close()
    again = Database(path)
    assert _counted(again) == _truth(again) == {"pending": 5, "processed": 2}
    _add(again, 7, 9, "failed")
    assert _counted(again) == _truth(again) == {"pending": 5, "processed": 2, "failed": 2}


def test_issues_report_failed_chunks_from_the_counter(client):
    db = client.app.state.db
    _add(db, 0, 3, "failed")
    from .conftest import AUTH

    issues = client.get("/v1/issues", headers=AUTH).json()["issues"]
    assert any(i["code"] == "chunks_failed" and i["count"] == 3 for i in issues)
    status = client.get("/v1/status", headers=AUTH).json()["queue"]
    assert status["chunks_failed"] == 3 and status["chunks_pending"] == 0


def test_queue_totals_equal_the_canonical_counts_through_random_changes(tmp_path):
    """The conversation counters, after every kind of change, equal COUNTs with the predicates `queue_counts` used
    before (`deferral.WAITING_SQL`, `views.NOT_DISMISSED`)."""
    import json
    import random

    from omi_notes import deferral, views

    canonical = {
        "open": "status='open'",
        "pending": f"status IN ('closed','transcribing','summarizing') AND NOT {deferral.WAITING_SQL}",
        "deferred": deferral.WAITING_SQL,
        "failed": f"status='failed' AND {views.NOT_DISMISSED}",
        "retrying": "status IN ('closed','transcribing','summarizing') AND error IS NOT NULL AND next_attempt_at IS NOT NULL",
    }
    db = Database(tmp_path / "index.sqlite3")
    rng = random.Random(1124)
    statuses = ["open", "closed", "transcribing", "summarizing", "done", "failed", "discarded"]
    deferrals = [None, json.dumps({"at": 1}), json.dumps({"at": 1, "requested": 2})]

    def resolution(fid):
        return rng.choice([None, json.dumps({"kind": "dismissed", "failure": {"id": fid}}),
                           json.dumps({"kind": "dismissed", "failure": {"id": "other"}}), json.dumps({"kind": "kept"})])

    def check():
        truth = {k: db.one(f"SELECT COUNT(*) AS n FROM conversations WHERE {p}")["n"] for k, p in canonical.items()}
        assert {k: db.queue_total(k) for k in canonical} == truth

    for i in range(200):
        fid = rng.choice([None, f"f{i}"])
        db.execute("INSERT INTO conversations(id,device_id,start,end,status,created_at,updated_at,deferral,note_path,"
                   "retry_op,transcribe_op,error,next_attempt_at,failure_id,resolution) "
                   "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                   (f"c{i}", "d", float(i), float(i + 1), rng.choice(statuses), 0.0, 0.0, rng.choice(deferrals),
                    rng.choice([None, "n.md"]), rng.choice([None, "op"]), rng.choice([None, "op"]),
                    rng.choice([None, "boom"]), rng.choice([None, 5.0]), fid, resolution(fid)))  # fmt: skip
    check()
    for step in range(600):
        cid = f"c{rng.randrange(200)}"
        column, value = rng.choice([
            ("status", rng.choice(statuses)), ("deferral", rng.choice(deferrals)), ("note_path", rng.choice([None, "n.md"])),
            ("retry_op", rng.choice([None, "op"])), ("transcribe_op", rng.choice([None, "op"])),
            ("error", rng.choice([None, "boom"])), ("next_attempt_at", rng.choice([None, 9.0])),
            ("failure_id", rng.choice([None, cid, "other"])), ("resolution", resolution(cid)), ("title", "t"),
        ])
        db.execute(f"UPDATE conversations SET {column}=? WHERE id=?", (value, cid))
        if step % 50 == 0:
            check()
    db.execute("DELETE FROM conversations WHERE start < 40")
    check()
    # and seeded from the rows for an index written before the counters existed
    db.execute("DELETE FROM meta WHERE key='counters'")
    db.execute("UPDATE queue_totals SET n = 999")
    check_db = Database(db.path)
    assert {k: check_db.queue_total(k) for k in canonical} == {
        k: db.one(f"SELECT COUNT(*) AS n FROM conversations WHERE {p}")["n"] for k, p in canonical.items()}


def test_status_cost_does_not_grow_with_failed_or_queued_conversations(client):
    from omi_notes.pipeline.conversations import queue_counts

    from .test_read_cost_nov24 import add_conversations, measure

    db = client.app.state.db
    add_conversations(db, 0, 100, "failed")
    a = measure(db, lambda: queue_counts(db))
    add_conversations(db, 100, 10_000, "failed")
    db.execute("UPDATE conversations SET status='closed' WHERE start >= 5000")
    b = measure(db, lambda: queue_counts(db))
    assert b[2]["conversations_failed"] == 5_000 and b[2]["conversations_pending"] == 5_000
    assert b[0] <= a[0] * 2, (a[:2], b[:2])
