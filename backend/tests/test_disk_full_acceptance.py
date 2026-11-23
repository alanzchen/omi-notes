"""Disk-full acceptance for the 2026-11-23 deploy candidate: below the free-space floor a chunk PUT is refused with a
retryable 507 before anything is written (the phone keeps its copy), /v1/status says full, what is already stored is
untouched, and when space returns uploads resume in the same process, with status saying so."""

from __future__ import annotations

import uuid

from omi_notes import ingest

from .conftest import AUTH, DEVICE, put_chunk
from .test_disk_full import GiB, _envs, _free


def test_disk_full_end_to_end_refuses_before_writing_and_resumes_without_restart(client, settings, monkeypatch):
    assert ingest.MIN_FREE_BYTES == 2 * GiB
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    vault = client.app.state.vault
    _free(monkeypatch, 50 * GiB)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    stored = vault.chunk_path(DEVICE, cap, 0)
    before = (stored.read_bytes(), stored.stat().st_mtime_ns)

    _free(monkeypatch, ingest.MIN_FREE_BYTES - 1)  # one byte under the floor
    r = put_chunk(client, cap, 1, bodies[1])
    assert r.status_code == 507 and r.json()["error"] == "storage_full"  # retryable: the phone keeps the part
    assert not vault.chunk_path(DEVICE, cap, 1).exists(), "refused before writing anything"
    assert client.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=1", (cap,)) is None
    disk = client.get("/v1/status", headers=AUTH).json()["disk"]
    assert disk["full"] is True and disk["since"]
    assert (stored.read_bytes(), stored.stat().st_mtime_ns) == before, "what is stored is not touched"
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 200  # an already-stored part is still acknowledged

    _free(monkeypatch, 50 * GiB)  # space returns: no restart
    assert put_chunk(client, cap, 1, bodies[1]).status_code == 201
    assert vault.chunk_path(DEVICE, cap, 1).read_bytes() == bodies[1]
    assert client.get("/v1/status", headers=AUTH).json()["disk"] == {"full": False}
