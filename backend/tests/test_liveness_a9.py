"""Acceptance A9 (ASTRA-20261122-IT1, DESIGN-05): an unconfirmed file is visible and kept out of trust, then indexed once
storage allows, by its own retry or by the worker's bounded off-request drain: no restart, no hot loop, no eviction."""

from __future__ import annotations

import uuid

from omi_notes import rebuild
from omi_notes.pipeline.worker import Worker

from .conftest import DEVICE, put_chunk
from .test_disk_full import GiB, _envs, _free
from .test_ingest_delta_independent import fail_index_once
from .test_publication_matrix import Barrier, fresh


def test_a_capture_unresolved_at_startup_is_drained_by_the_worker(settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(c, cap, 0, bodies[0]).status_code == 201
    vault = c.app.state.vault
    path = vault.chunk_path(DEVICE, cap, 1)
    path.write_bytes(bodies[1])
    b = Barrier(monkeypatch, path.parent)
    c = fresh(settings)
    assert (DEVICE, cap) in rebuild.recovery_state(vault).unresolved
    assert c.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=1", (cap,)) is None
    w = Worker(settings, c.app.state.db)
    w._drain_unresolved(1000.0)  # still failing: backs off
    hits = b.hits
    w._drain_unresolved(1001.0)  # within the backoff: not tried again (no hot loop)
    assert b.hits == hits
    b.failing = False
    w._drain_unresolved(1000.0 + 61)
    assert c.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=1", (cap,)) is not None
    assert (DEVICE, cap) not in rebuild.recovery_state(vault).unresolved
    assert path.read_bytes() == bodies[1]


def test_a_failed_publication_is_drained_and_the_retry_is_a_duplicate(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    fail_index_once(monkeypatch, "index_chunk")
    assert put_chunk(client, cap, 0, body).status_code == 507
    w = Worker(settings, client.app.state.db)
    w._drain_unresolved(2000.0)
    assert client.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=0", (cap,)) is not None
    assert put_chunk(client, cap, 0, body).status_code == 200
