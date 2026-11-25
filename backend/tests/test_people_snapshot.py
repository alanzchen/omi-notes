"""IT1-01 (2026-11-25): GET /v1/people serves a snapshot the worker or a mutation built. A GET never globs, scans or
rebuilds (design: build/deployment/nightly/2026-11-24/r2/IT1-01-DESIGN.md)."""

from __future__ import annotations

import json
import threading
import uuid
from pathlib import Path

import pytest

from omi_notes.api import create_app
from fastapi.testclient import TestClient

from .conftest import AUTH


def _people(client) -> dict:
    r = client.get("/v1/people", headers=AUTH)
    assert r.status_code == 200
    return r.json()


def _note(client, name: str, pid: str) -> Path:
    notes = client.app.state.vault.root / "People"
    notes.mkdir(exist_ok=True)
    path = notes / f"{name}.md"
    path.write_text(f"---\nomi_person_id: {pid}\n---\n")
    return path


def _count_scans(monkeypatch) -> list:
    """Every glob/rglob/iterdir under the vault while a GET runs."""
    seen = []
    for name in ("glob", "rglob", "iterdir"):
        real = getattr(Path, name)

        def tracked(self, *a, _real=real, _name=name, **kw):
            seen.append((_name, str(self)))
            return _real(self, *a, **kw)

        monkeypatch.setattr(Path, name, tracked)
    return seen


def test_a_correction_shows_at_once(client):
    """A mutation rebuilds the snapshot before it answers: the phone's own change is in its next GET."""
    pid = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid}", json={"name": "Dana"}, headers=AUTH).status_code == 201
    got = _people(client)
    assert [p["name"] for p in got["people"]] == ["Dana"] and got["ready"] is True
    assert client.put(f"/v1/people/{pid}", json={"name": "Dana Lee"}, headers=AUTH).status_code == 200
    again = _people(client)
    assert [p["name"] for p in again["people"]] == ["Dana Lee"]
    assert again["generation"] > got["generation"]


def test_an_external_rename_shows_after_one_worker_reconcile_not_before(client):
    speakers = client.app.state.speakers
    pid = str(uuid.uuid4())
    note = _note(client, "Erin", pid)
    speakers.warm()
    before = _people(client)
    assert [p["name"] for p in before["people"]] == ["Erin"]
    note.rename(note.with_name("Erin Park.md"))  # edited in Obsidian
    assert [p["name"] for p in _people(client)["people"]] == ["Erin"], "a GET doesn't look at the vault"
    speakers.warm()  # the worker's next tick: the People folder changed
    after = _people(client)
    assert [p["name"] for p in after["people"]] == ["Erin Park"] and after["as_of"] >= before["as_of"]


def test_a_note_content_edit_shows_at_the_five_minute_reconcile(client):
    speakers = client.app.state.speakers
    pid = str(uuid.uuid4())
    note = _note(client, "Finn", pid)
    speakers.warm(now=1_000.0)
    note.write_text(f"---\nomi_person_id: {pid}\nomi_me: true\n---\n")  # the folder's mtime doesn't change
    speakers.warm(now=1_060.0)
    assert _people(client)["people"][0]["me"] is False, "not yet: inside the reconcile interval"
    speakers.warm(now=1_000.0 + 301)
    assert _people(client)["people"][0]["me"] is True


def test_a_cold_start_serves_the_stored_copy_not_ready_without_a_scan(settings, monkeypatch):
    first = TestClient(create_app(settings, start_worker=False))
    pid = str(uuid.uuid4())
    assert first.put(f"/v1/people/{pid}", json={"name": "Gale"}, headers=AUTH).status_code == 201
    cache = first.app.state.db.path.parent / "people.json"
    assert json.loads(cache.read_text())["people"][0]["name"] == "Gale"
    assert not str(cache).startswith(str(first.app.state.vault.root)), "operational cache, never vault data"
    first.app.state.db.close()
    again = TestClient(create_app(settings, start_worker=False))
    seen = _count_scans(monkeypatch)
    got = _people(again)
    assert [p["name"] for p in got["people"]] == ["Gale"] and got["ready"] is False
    assert not [s for s in seen if "People" in s[1] or "people" in s[1]], seen


def test_no_snapshot_at_all_is_empty_and_not_ready(client):
    got = _people(client)
    assert got["people"] == [] and got["ready"] is False and got["as_of"] is None


def test_an_older_build_never_overwrites_a_newer_snapshot(client, monkeypatch):
    """Generations are taken when a build starts; a slower build that started earlier is dropped when it finishes."""
    speakers = client.app.state.speakers
    pid = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid}", json={"name": "Hal"}, headers=AUTH).status_code == 201
    started, release = threading.Event(), threading.Event()
    real = speakers._compute_people

    def slow():
        out = real()  # reads "Hal"
        started.set()
        assert release.wait(5)
        return out

    monkeypatch.setattr(speakers, "_compute_people", slow)
    old = threading.Thread(target=speakers.refresh_people)
    old.start()
    assert started.wait(5)
    monkeypatch.setattr(speakers, "_compute_people", real)
    assert client.put(f"/v1/people/{pid}", json={"name": "Hal Ito"}, headers=AUTH).status_code == 200
    newer = _people(client)
    release.set()
    old.join()
    after = _people(client)
    assert [p["name"] for p in after["people"]] == ["Hal Ito"] and after["generation"] == newer["generation"]


def test_a_failed_rebuild_after_a_committed_mutation_is_not_ready_until_the_worker_rebuilds(client, monkeypatch):
    speakers = client.app.state.speakers
    pid = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid}", json={"name": "Ivy"}, headers=AUTH).status_code == 201

    def broken(*a, **k):
        raise OSError("synthetic: index unreadable")

    real = speakers._compute_suggestions  # a step only the snapshot build runs: the mutation itself succeeds
    monkeypatch.setattr(speakers, "_compute_suggestions", broken)
    assert client.put(f"/v1/people/{pid}", json={"name": "Ivy Ng"}, headers=AUTH).status_code == 200, "the change is durable"
    stale = _people(client)
    assert stale["ready"] is False and stale["stale"] is True, "the old list is marked, never silently current"
    monkeypatch.setattr(speakers, "_compute_suggestions", real)
    speakers.warm()  # the worker retries a stale snapshot on its next tick
    fresh = _people(client)
    assert fresh["ready"] is True and not fresh.get("stale") and [p["name"] for p in fresh["people"]] == ["Ivy Ng"]


def test_the_cache_file_is_replaced_atomically(client, monkeypatch):
    import os

    renames = []
    real = os.replace
    monkeypatch.setattr(os, "replace", lambda a, b: (renames.append((str(a), str(b))), real(a, b))[1])
    pid = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid}", json={"name": "Jo"}, headers=AUTH).status_code == 201
    target = str(client.app.state.db.path.parent / "people.json")
    assert any(b == target and a != target for a, b in renames)
    assert not [p for p in Path(target).parent.iterdir() if p.name.startswith("people.json.")]


def test_suggestions_are_sliced_from_the_snapshot(client, monkeypatch):
    speakers = client.app.state.speakers
    speakers.warm()
    seen = _count_scans(monkeypatch)
    calls = []
    monkeypatch.setattr(speakers, "_suggestions", lambda *a, **k: calls.append(1) or ([], {}))
    r = client.get("/v1/speakers/suggestions?limit=3", headers=AUTH)
    assert r.status_code == 200 and r.json() == {"suggestions": []}
    assert not calls and not seen, "a GET only slices the worker's list"
