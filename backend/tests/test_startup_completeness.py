"""ASTRA-20261123-IT3-01 (2026-11-23 R4): a FULL rebuild that can't confirm an artifact the previous index held (an
acknowledged upload, possibly gone from the phone) is refused. The server stays up not ready instead of crash-looping
under launchd's KeepAlive: /healthz 503 with the reason, /v1 refused retryably, the previous index untouched, no
half-built index left on disk, and a bounded retry. A never-acknowledged file doesn't block startup."""

from __future__ import annotations

import errno
import hashlib
import time
import uuid

from fastapi.testclient import TestClient

from omi_notes import api
from omi_notes.api import create_app
from omi_notes.vault import index_dir

from .conftest import AUTH, DEVICE, put_chunk
from .helpers import iso
from .test_disk_full import GiB, _envs, _free
from .test_publication_matrix import Barrier, fresh


def _force_rebuild(client):
    client.app.state.db.set_meta("schema_version", "11")  # as the running release's index: the deploy must rebuild
    client.app.state.db.close()


def test_a_refused_rebuild_stays_up_not_ready_without_a_crash_loop(settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    first = fresh(settings)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    assert put_chunk(first, cap, 0, body).status_code == 201
    vault = first.app.state.vault
    target = index_dir(settings, vault) / "index.sqlite3"
    _force_rebuild(first)
    before = hashlib.sha256(target.read_bytes()).hexdigest()
    b = Barrier(monkeypatch, vault.chunk_path(DEVICE, cap, 0).parent)
    restarts = []
    monkeypatch.setattr(api, "_exit_for_restart", lambda: restarts.append(True))
    app = create_app(settings, start_worker=False)  # no exception: launchd sees a running process, not a crash
    c = TestClient(app)
    h = c.get("/healthz")
    assert h.status_code == 503 and h.json()["startup"] == "incomplete" and cap in h.json()["reason"]
    assert c.get("/v1/status").status_code == 401  # still authenticated
    r = c.get("/v1/status", headers=AUTH)
    assert r.status_code == 507 and r.json()["error"] == "storage_full"  # ENOSPC cause: the phone keeps its audio
    assert not (target.parent / "index.tmp").exists(), "a refused rebuild leaves nothing half-built"
    assert hashlib.sha256(target.read_bytes()).hexdigest() == before, "the previous index is untouched"
    assert api.RETRY_FIRST_SECONDS == 60 and api.RETRY_MAX_SECONDS == 1800  # bounded, no hot loop
    assert not app.state.retry_now() and not restarts
    b.failing = False
    assert app.state.retry_now() and restarts == [True]
    ready = fresh(settings)
    assert ready.get("/healthz").status_code == 200
    assert ready.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=?", (cap,))


def test_an_acknowledged_event_file_blocks_too(settings, monkeypatch):
    first = fresh(settings)
    now = time.time()
    first.app.state.ingest.clock = lambda: now
    body = {"device_id": DEVICE, "type": "heartbeat", "at": iso(now), "data": {}}
    assert first.put(f"/v1/events/{uuid.uuid4()}", json=body, headers=AUTH).status_code == 201
    path = first.app.state.vault.events_path(now)
    _force_rebuild(first)
    Barrier(monkeypatch, path)
    monkeypatch.setattr(api, "_exit_for_restart", lambda: None)
    c = fresh(settings)
    r = c.get("/v1/status", headers=AUTH)
    assert r.status_code == 507 and c.get("/healthz").status_code == 503


def test_a_never_acknowledged_file_does_not_block_startup(settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    first = fresh(settings)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    vault = first.app.state.vault
    path = vault.chunk_path(DEVICE, cap, 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bodies[0])  # an orphan of a failed publication: no row anywhere, the phone still has it
    _force_rebuild(first)
    Barrier(monkeypatch, path)
    c = fresh(settings)
    assert c.get("/healthz").status_code == 200, "its own retry or the next startup indexes it"
    assert c.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=?", (cap,)) is None
