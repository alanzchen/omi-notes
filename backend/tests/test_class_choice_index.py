"""The index copy of the owner's class choice (`class_choice`, what Home's kind filter reads) never goes stale
(Astra, review of main 9b11b7c): the vault write and the index update happen under the same lock, and an update a
crash interrupted is repaired by the worker. Fakes only."""

from __future__ import annotations

import json
import threading

from omi_notes import home

from .conftest import AUTH
from .helpers import T0, convs
from .test_deferred import busy, fakes, short


def choose(client, conv_id: str, cls: str, rid: str, at: str):
    return client.put(f"/v1/conversations/{conv_id}/class", json={"class": cls, "request_id": rid, "set_at": at},
                      headers=AUTH)  # fmt: skip


def stored(settings, worker, conv_id: str) -> str:
    return json.loads((worker.pipeline.conv_dir(conv_id) / "class.json").read_text())["class"]


def deferred(client, worker, monkeypatch) -> str:
    fakes(worker)
    busy(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    return row["id"]


def test_concurrent_choices_leave_the_index_on_the_newest_one(client, worker, settings, monkeypatch):
    conv = deferred(client, worker, monkeypatch)
    paused, go = threading.Event(), threading.Event()
    real = home.set_choice
    calls = []

    def slow(db, conv_id, choice):
        calls.append(choice)
        if len(calls) == 1:  # A has read its own choice and is about to index it
            paused.set()
            go.wait(2)
        return real(db, conv_id, choice)

    monkeypatch.setattr(home, "set_choice", slow)
    a = threading.Thread(target=lambda: choose(client, conv, "monologue", "ra", "2026-11-08T20:00:00Z"))
    a.start()
    assert paused.wait(2)
    b = threading.Thread(target=lambda: choose(client, conv, "passive", "rb", "2026-11-08T21:00:00Z"))
    b.start()
    b.join(0.5)  # B either waits for A's lock (fixed) or persists and indexes its newer choice now (the race)
    go.set()
    a.join(5)
    b.join(5)
    assert stored(settings, worker, conv) == "passive"
    row = worker.db.one("SELECT class_choice, kind FROM conversations WHERE id=?", (conv,))
    assert row["class_choice"] == "passive" and row["kind"] == "passive", dict(row)


def test_an_index_update_a_crash_interrupted_is_repaired(client, worker, settings, monkeypatch):
    conv = deferred(client, worker, monkeypatch)

    def crash(db, conv_id, choice):
        raise RuntimeError("the process died after the vault write")

    monkeypatch.setattr(home, "set_choice", crash)
    try:
        choose(client, conv, "monologue", "r1", "2026-11-08T20:00:00Z")
    except RuntimeError:
        pass
    monkeypatch.undo()
    assert stored(settings, worker, conv) == "monologue"
    assert worker.db.one("SELECT class_choice FROM conversations WHERE id=?", (conv,))["class_choice"] is None
    busy(worker, monkeypatch)
    worker.tick(T0 + 500)
    row = worker.db.one("SELECT class_choice, kind FROM conversations WHERE id=?", (conv,))
    assert row["class_choice"] == "monologue" and row["kind"] == "monologue"
    assert worker.db.query("SELECT * FROM class_pending") == []


def test_a_replayed_request_never_acknowledges_an_unfinished_index_update(client, worker, settings, monkeypatch):
    """Astra (re-review of fix-50): after the file was written and indexing failed, the phone's retry of the same
    request (or an older one) answered applied while the index still had no choice and the mark stayed. A replay
    indexes the stored choice first, under the same lock."""
    conv = deferred(client, worker, monkeypatch)
    real = home.set_choice
    monkeypatch.setattr(home, "set_choice", lambda *a: (_ for _ in ()).throw(RuntimeError("index write failed")))
    try:
        choose(client, conv, "monologue", "r1", "2026-11-08T20:00:00Z")
    except RuntimeError:
        pass
    monkeypatch.setattr(home, "set_choice", real)
    for rid, at in (("r1", "2026-11-08T20:00:00Z"), ("r0", "2026-11-08T19:00:00Z")):  # the same request, an older one
        worker.db.execute("UPDATE conversations SET class_choice=NULL WHERE id=?", (conv,))
        worker.db.execute("INSERT OR IGNORE INTO class_pending (conversation_id) VALUES (?)", (conv,))
        r = choose(client, conv, "monologue" if rid == "r1" else "passive", rid, at)
        assert r.status_code == 200, r.text
        row = worker.db.one("SELECT class_choice, kind FROM conversations WHERE id=?", (conv,))
        assert row["class_choice"] == "monologue" and row["kind"] == "monologue", (rid, dict(row))
        assert worker.db.query("SELECT * FROM class_pending") == [], rid
