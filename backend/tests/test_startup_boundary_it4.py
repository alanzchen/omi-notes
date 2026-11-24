"""ASTRA-20261123-IT4-01/02 (2026-11-24 R1). IT4-01: storage errors while listing the vault (a capture or device
directory that can't be read) and an unreadable previous index must stay inside the not-ready lifecycle (503 with a
bounded retry), never escape as a crash that launchd restarts at its throttle. IT4-02: a FULL rebuild must not promote an
index that lacks a chunk, seal or event the previous index held (deleted without a tombstone, or unreadable)."""

from __future__ import annotations

import os
import uuid

import pytest

from omi_notes import api
from omi_notes.api import create_app
from omi_notes.vault import index_dir

from .conftest import DEVICE, put_chunk
from .test_disk_full import GiB, _envs, _free
from .test_publication_matrix import fresh

from fastapi.testclient import TestClient


@pytest.fixture
def stored(settings, monkeypatch):
    """One acknowledged two-chunk capture, the index then marked as the running release's (a rebuild is due)."""
    _free(monkeypatch, 50 * GiB)
    monkeypatch.setattr(api, "_exit_for_restart", lambda: None)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    for seq in (0, 1):
        assert put_chunk(c, cap, seq, bodies[seq]).status_code == 201
    vault = c.app.state.vault
    c.app.state.db.set_meta("schema_version", "11")
    c.app.state.db.close()
    return vault, cap


def _not_ready(settings):
    c = TestClient(create_app(settings, start_worker=False))  # must not raise
    h = c.get("/healthz")
    assert h.status_code == 503 and h.json()["startup"] == "incomplete", h.text
    return c, h.json()["reason"]


@pytest.mark.parametrize("level", ["capture", "device"])
def test_a_directory_that_cant_be_listed_is_not_ready_not_a_crash(settings, stored, level):
    vault, cap = stored
    folder = vault.capture_dir(DEVICE, cap)
    target = folder if level == "capture" else folder.parent
    os.chmod(target, 0)
    try:
        _not_ready(settings)
    finally:
        os.chmod(target, 0o755)
    assert fresh(settings).get("/healthz").status_code == 200  # readable again: a normal start


def test_an_unreadable_previous_index_does_not_escape_the_not_ready_mode(settings, stored):
    vault, cap = stored
    old = index_dir(settings, vault) / "index.sqlite3"
    folder = vault.capture_dir(DEVICE, cap)
    os.chmod(old, 0)
    os.chmod(folder, 0)
    try:
        c, _ = _not_ready(settings)
        assert c.app.state.db is None
    finally:
        os.chmod(folder, 0o755)
        os.chmod(old, 0o644)


def test_an_acknowledged_chunk_deleted_without_a_tombstone_blocks_promotion(settings, stored):
    vault, cap = stored
    path = vault.chunk_path(DEVICE, cap, 1)
    kept = path.read_bytes()
    path.unlink()  # synthetic damage in a temp vault: never a live one
    try:
        _, reason = _not_ready(settings)
        assert "missing" in reason and f"{cap}/1" in reason
    finally:
        path.write_bytes(kept)


def test_an_acknowledged_chunk_that_no_longer_parses_blocks_promotion(settings, stored):
    vault, cap = stored
    path = vault.chunk_path(DEVICE, cap, 0)
    kept = path.read_bytes()
    path.write_bytes(b"not an envelope")
    try:
        _, reason = _not_ready(settings)
        assert "missing" in reason and f"{cap}/0" in reason
    finally:
        path.write_bytes(kept)


@pytest.mark.parametrize("damage", [b"{torn", b"[]", b'{"sha256": "x"}'])
def test_a_damaged_acknowledged_tombstone_stays_not_ready(settings, monkeypatch, damage):
    """ASTRA-20261124-IT2-02: a torn or misshapen tombstone of an acknowledged chunk refuses the rebuild like a
    torn seal (503 with the bounded retry, previous index untouched), never a crash at startup."""
    import hashlib

    from omi_notes.envelope import parse_envelope

    _free(monkeypatch, 50 * GiB)
    monkeypatch.setattr(api, "_exit_for_restart", lambda: None)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    raw = _envs(cap)[0]
    assert put_chunk(c, cap, 0, raw).status_code == 201
    v = c.app.state.vault
    tomb = {"sha256": hashlib.sha256(raw).hexdigest(), "size": len(raw),
            "header": parse_envelope(raw).header.model_dump(mode="json"), "deleted_at": 1}  # fmt: skip
    v.write_json(v.tombstone_path(DEVICE, cap, 0), tomb)  # a synthetic vault's pre-rule tombstone
    v.chunk_path(DEVICE, cap, 0).unlink()
    c.app.state.db.execute("UPDATE chunks SET raw_deleted=1 WHERE capture_id=?", (cap,))
    c.app.state.db.set_meta("schema_version", "11")
    c.app.state.db.close()
    index = index_dir(settings, v) / "index.sqlite3"
    before = index.read_bytes()
    v.tombstone_path(DEVICE, cap, 0).write_bytes(damage)
    r = fresh(settings).get("/healthz")
    assert r.status_code == 503 and r.json()["startup"] == "incomplete", r.text
    assert index.read_bytes() == before
