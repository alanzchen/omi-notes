"""Acceptance A9 under the 2026-11-23 R3 design reset: an unconfirmed file is kept on disk and out of trust, then indexed
once storage allows by the phone's own retry of that identity (the phone keeps every part until a 2xx) or by the next
startup sweep. There is no background repair queue: nothing is evicted, nothing waits on an internal slot."""

from __future__ import annotations

import uuid

from omi_notes import rebuild

from .conftest import DEVICE, put_chunk
from .test_disk_full import GiB, _envs, _free
from .test_ingest_delta_independent import fail_index_once
from .test_publication_matrix import Barrier, fresh


def test_a_capture_unresolved_at_startup_is_stored_by_its_retry_or_the_next_startup(settings, monkeypatch):
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
    assert put_chunk(c, cap, 1, bodies[1]).status_code == 507  # the fault is still there: not stored
    b.failing = False
    assert put_chunk(c, cap, 1, bodies[1]).status_code == 200  # its own retry, once the sync works
    assert c.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=1", (cap,)) is not None
    assert path.read_bytes() == bodies[1]
    assert not c.app.state.ingest._pending


def test_without_a_retry_the_next_startup_indexes_it(settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(c, cap, 0, bodies[0]).status_code == 201
    path = c.app.state.vault.chunk_path(DEVICE, cap, 1)
    path.write_bytes(bodies[1])
    b = Barrier(monkeypatch, path.parent)
    fresh(settings)
    b.failing = False
    again = fresh(settings)
    assert again.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=1", (cap,)) is not None


def test_a_failed_publication_is_stored_by_its_retry_and_holds_nothing(client, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    fail_index_once(monkeypatch, "index_chunk")
    assert put_chunk(client, cap, 0, body).status_code == 507
    assert put_chunk(client, cap, 0, body).status_code == 200
    assert client.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=0", (cap,)) is not None
    assert not client.app.state.ingest._pending
