"""C1-02 (Carbon IT1, 2026-11-25): `Database.close` and `conn()` registration. A connection is registered and stamped
with the close generation in one step, so a close() between them can't leave a live connection with an old stamp; and
close() refuses (an error, nothing closed) while another connection is inside a transaction, instead of rolling it back
under the writer. Deterministic: the opener is paused by a wrapped lock, never by sleeping."""

from __future__ import annotations

import threading

import pytest

from omi_notes.db import Database


class _PausingLock:
    """Wraps the registration lock: the first acquisition from `thread_name` signals and waits before acquiring."""

    def __init__(self, real, thread_name: str) -> None:
        self.real, self.thread_name = real, thread_name
        self.arrived, self.resume = threading.Event(), threading.Event()

    def __enter__(self):
        if threading.current_thread().name == self.thread_name and not self.arrived.is_set():
            self.arrived.set()
            assert self.resume.wait(5)
        return self.real.__enter__()

    def __exit__(self, *exc):
        return self.real.__exit__(*exc)


def test_a_close_between_open_and_registration_leaves_no_stale_connection(tmp_path):
    db = Database(tmp_path / "index.sqlite3")
    db.close()  # the constructing thread's connection: the opener below starts from none
    lock = _PausingLock(db._opened_lock, "opener")
    db._opened_lock = lock
    got: list = []

    def opener():
        got.append(db.conn())  # pauses inside, before its registration
        got.append(db.conn())  # the same thread again: must get the same, live connection

    t = threading.Thread(target=opener, name="opener")
    t.start()
    assert lock.arrived.wait(5)
    db.close()  # lands between the open and its registration
    lock.resume.set()
    t.join(5)
    assert got[0] is got[1], "the thread's own connection was dropped as if a close had closed it"
    assert got[0].execute("SELECT 1").fetchone()[0] == 1
    db.close()  # registered: closed now


def test_close_refuses_while_another_thread_is_inside_a_transaction(tmp_path):
    db = Database(tmp_path / "index.sqlite3")
    db.execute("CREATE TABLE t(x INT)")
    in_tx, attempted = threading.Event(), threading.Event()
    errors: list = []

    def writer():
        try:
            with db.tx() as conn:
                conn.execute("INSERT INTO t VALUES (1)")
                in_tx.set()
                assert attempted.wait(5)
                conn.execute("INSERT INTO t VALUES (2)")
        except Exception as exc:  # pragma: no cover - the failure being tested
            errors.append(exc)

    t = threading.Thread(target=writer)
    t.start()
    assert in_tx.wait(5)
    with pytest.raises(RuntimeError, match="transaction"):
        db.close()
    attempted.set()
    t.join(5)
    assert errors == [] and [r["x"] for r in db.query("SELECT x FROM t ORDER BY x")] == [1, 2]
    db.close()


def test_snapshot_rolls_back_rather_than_commits_after_an_error(tmp_path):
    """C1-05: a snapshot whose body raised ends with ROLLBACK, so a future caller that wrote inside one can't commit
    half its work."""
    db = Database(tmp_path / "index.sqlite3")
    db.execute("CREATE TABLE t(x INT)")
    with pytest.raises(ValueError):
        with db.snapshot() as conn:
            conn.execute("INSERT INTO t VALUES (1)")
            raise ValueError("boom")
    assert db.query("SELECT x FROM t") == []
