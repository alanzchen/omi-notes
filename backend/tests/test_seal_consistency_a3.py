"""Acceptance A3 (ASTRA-20261122-IT1, DESIGN-04): the saved seal bounds every way a chunk becomes stored, and a new seal
can't end before a chunk already on disk. No premature finalization, no skip (processing still waits for
processed_through + 1). Astra's original IT7 case is in test_ingest_delta_independent.py."""

from __future__ import annotations

import sqlite3
import uuid

from fastapi.testclient import TestClient

from omi_notes import ingest
from omi_notes.api import create_app
from omi_notes.devtools import live_envelopes, synth_speech_like
from omi_notes.vault import Vault

from .conftest import AUTH, DEVICE, put_chunk
from .helpers import STARTED
from .test_api import seal_body
from .test_disk_full import GiB, _free
from .test_ingest_delta_independent import fail_index_once


def _bodies(cap, n=4):
    return live_envelopes(synth_speech_like(n * 2), capture_id=cap, device_id=DEVICE, started_at=STARTED, chunk_seconds=2.0)


def test_an_orphan_above_a_saved_seal_is_kept_but_not_adopted(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _bodies(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    vault = client.app.state.vault
    Vault.write_json(vault.seal_path(DEVICE, cap), {"body": seal_body(0), "received_at": 1_790_000_000.0}, pretty=False)
    vault.chunk_path(DEVICE, cap, 1).write_bytes(bodies[1])  # a file above the seal, left by a crash
    c = TestClient(create_app(settings, start_worker=False))
    r = put_chunk(c, cap, 1, bodies[1])
    assert r.status_code == 409 and r.json()["error"] == "beyond_seal"
    assert vault.chunk_path(DEVICE, cap, 1).read_bytes() == bodies[1], "kept, never deleted"
    assert c.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=1", (cap,)) is None


def test_a_missing_sequence_below_the_seal_is_still_taken(client, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _bodies(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    assert put_chunk(client, cap, 2, bodies[2]).status_code == 201
    assert client.put(f"/v1/captures/{cap}/seal", json=seal_body(2), headers=AUTH).status_code == 200
    assert put_chunk(client, cap, 1, bodies[1]).status_code == 201
    cap_row = client.app.state.db.one("SELECT processed_through FROM captures WHERE capture_id=?", (cap,))
    assert cap_row["processed_through"] == -1, "nothing processed ahead of the worker"


def test_a_malformed_saved_seal_is_unresolved_not_absent(client, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _bodies(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    client.app.state.vault.seal_path(DEVICE, cap).write_text("{not json")
    r = put_chunk(client, cap, 1, bodies[1])
    assert r.status_code == 503 and r.json()["error"] == "seal_unresolved"
    assert client.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=1", (cap,)) is None


def test_a_new_seal_cant_end_before_a_chunk_already_on_disk(client, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _bodies(cap)
    for seq in (0, 1):
        assert put_chunk(client, cap, seq, bodies[seq]).status_code == 201
    fail_index_once(monkeypatch, "index_chunk")
    assert put_chunk(client, cap, 2, bodies[2]).status_code == 507  # on disk, no row
    r = client.put(f"/v1/captures/{cap}/seal", json=seal_body(1), headers=AUTH)
    assert r.status_code == 409 and r.json()["error"] == "chunks_beyond_seal"
    assert client.app.state.db.one("SELECT seal_json FROM captures WHERE capture_id=?", (cap,))["seal_json"] is None
    assert put_chunk(client, cap, 2, bodies[2]).status_code == 200  # its own retry adopts it


def test_the_high_water_mark_survives_a_restart(client, settings, monkeypatch):
    """A chunk left on disk without its row by an earlier process (and unconfirmable at startup) still bounds a seal."""
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _bodies(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    client.app.state.vault.chunk_path(DEVICE, cap, 3).write_bytes(bodies[3])
    c = TestClient(create_app(settings, start_worker=False))  # the sweep indexes it (provable) or records its sequence
    r = c.put(f"/v1/captures/{cap}/seal", json=seal_body(1), headers=AUTH)
    assert r.status_code == 409 and r.json()["error"] == "chunks_beyond_seal"
