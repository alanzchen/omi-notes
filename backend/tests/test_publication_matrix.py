"""Acceptance A2 (ASTRA-20261122-IT1, DURABILITY-DESIGN): producer × barrier. Every way a chunk or seal becomes
"stored" (new file, orphan retry, new alternate, new seal, saved-but-unindexed seal, startup sweep) fails while any link
of its chain can't be synced: the file itself, capture, device, raw, _omi, the vault root, or the root's entry in its
parent. No 2xx and no new row until the barrier succeeds; original bytes and rows are kept; the retry then succeeds."""

from __future__ import annotations

import errno
import uuid

import pytest
from fastapi.testclient import TestClient

from omi_notes import ingest, spool
from omi_notes import vault as vault_module
from omi_notes.api import create_app
from omi_notes.envelope import build_envelope, parse_envelope

from .conftest import AUTH, DEVICE, put_chunk
from .test_disk_full import GiB, _envs, _free

LEVELS = ["file", "capture", "device", "raw", "_omi", "vault", "anchor"]


class Barrier:
    """fsync of one path fails with ENOSPC while `failing` is set (directories and files alike)."""

    def __init__(self, monkeypatch, target):
        self.target, self.failing, self.hits = target, True, 0
        real_dir, real_file = spool.fsync_dir, spool.fsync_file

        def fsync_dir(path):
            if self.failing and path == self.target:
                self.hits += 1
                raise OSError(errno.ENOSPC, "synthetic sync failure")
            return real_dir(path)

        def fsync_file(path):
            if self.failing and path == self.target:
                self.hits += 1
                raise OSError(errno.ENOSPC, "synthetic sync failure")
            return real_file(path)

        monkeypatch.setattr(spool, "fsync_dir", fsync_dir)
        monkeypatch.setattr(spool, "fsync_file", fsync_file)
        monkeypatch.setattr(vault_module, "fsync_dir", fsync_dir)


def target(vault, level, file_path):
    cap_dir = file_path.parent if file_path.parent.name != "alternates" else file_path.parent.parent
    return {"file": file_path, "capture": cap_dir, "device": cap_dir.parent, "raw": vault.raw, "_omi": vault.omi,
            "vault": vault.root, "anchor": vault.root.parent}[level]  # fmt: skip


def fresh(settings):
    """A new process (so the vault root's anchor is proven again by its first publication)."""
    return TestClient(create_app(settings, start_worker=False))


def rows(client, cap, seq=None):
    q = "SELECT COUNT(*) AS n FROM chunks WHERE capture_id=?" + (" AND chunk_sequence=?" if seq is not None else "")
    return client.app.state.db.one(q, (cap,) if seq is None else (cap, seq))["n"]


@pytest.mark.parametrize("level", LEVELS)
def test_a_new_chunk_is_stored_only_once_its_whole_chain_is(settings, monkeypatch, level):
    _free(monkeypatch, 50 * GiB)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    vault = c.app.state.vault
    path = vault.chunk_path(DEVICE, cap, 0)
    path.parent.mkdir(parents=True, exist_ok=True)  # the directories exist (an earlier attempt): existence proves nothing
    b = Barrier(monkeypatch, target(vault, level, path))
    assert put_chunk(c, cap, 0, body).status_code == 507
    assert b.hits and rows(c, cap) == 0
    assert put_chunk(c, cap, 0, body).status_code == 507, "the same fault on the retry: still not stored"
    b.failing = False
    assert put_chunk(c, cap, 0, body).status_code in (200, 201)
    assert rows(c, cap, 0) == 1 and path.read_bytes() == body


@pytest.mark.parametrize("level", LEVELS)
def test_an_orphan_retry_is_adopted_only_once_its_whole_chain_is(settings, monkeypatch, level):
    _free(monkeypatch, 50 * GiB)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(c, cap, 0, bodies[0]).status_code == 201
    vault = c.app.state.vault
    path = vault.chunk_path(DEVICE, cap, 1)
    path.write_bytes(bodies[1])  # a file without its row: a crash before its index commit ...
    b = Barrier(monkeypatch, target(vault, level, path))
    c = fresh(settings)  # ... then a restart, whose sweep can't prove it either and prepares its facts
    assert rows(c, cap, 1) == 0
    assert put_chunk(c, cap, 1, bodies[1]).status_code == 507
    assert b.hits and rows(c, cap, 1) == 0
    b.failing = False
    assert put_chunk(c, cap, 1, bodies[1]).status_code == 200
    assert rows(c, cap, 1) == 1 and path.read_bytes() == bodies[1]


@pytest.mark.parametrize("level", ["file", "capture", "device", "raw", "_omi", "vault"])
def test_a_new_alternate_keeps_the_original_row_and_is_acknowledged_only_once_published(settings, monkeypatch, level):
    _free(monkeypatch, 50 * GiB)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    assert put_chunk(c, cap, 0, body).status_code == 201
    env = parse_envelope(body, capture_id=cap, chunk_sequence=0)
    header = env.header.model_dump(mode="json", exclude_none=True)
    header["app_version"] = "omi-notes-other-build"
    other = build_envelope(header, env.payload)
    monkeypatch.setattr(ingest, "same_audio", lambda a, b: True)
    vault = c.app.state.vault
    alt = vault.capture_dir(DEVICE, cap) / "alternates" / f"0-{ingest.sha256_hex(other)[:16]}.omnc"
    alt.parent.mkdir(parents=True, exist_ok=True)
    lvl = {"capture": alt.parent}.get(level)  # the alternate's own directory stands where "capture" does for raw files
    b = Barrier(monkeypatch, lvl or target(vault, level, alt))
    assert put_chunk(c, cap, 0, other).status_code == 507
    assert b.hits
    original = c.app.state.db.one("SELECT sha256 FROM chunks WHERE capture_id=? AND chunk_sequence=0", (cap,))
    assert original["sha256"] == ingest.sha256_hex(body), "an alternate failure never touches the original row"
    assert vault.chunk_path(DEVICE, cap, 0).read_bytes() == body
    b.failing = False
    assert put_chunk(c, cap, 0, other).status_code == 200
    assert alt.read_bytes() == other


def _seal(cap, last=0):
    return {"last_chunk_sequence": last, "reason": "ble_disconnected", "ended_at": "2026-09-26T19:33:05.123Z",
            "end_offset_us": 1_000_000, "device_id": DEVICE, "source": "live_ble"}  # fmt: skip


@pytest.mark.parametrize("level", LEVELS)
def test_a_new_seal_is_acknowledged_only_once_published(settings, monkeypatch, level):
    _free(monkeypatch, 50 * GiB)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    assert put_chunk(c, cap, 0, _envs(cap)[0]).status_code == 201
    c = fresh(settings) if level == "anchor" else c
    vault = c.app.state.vault
    path = vault.seal_path(DEVICE, cap)
    b = Barrier(monkeypatch, target(vault, level, path))
    with pytest.raises(OSError):  # an unhandled sync failure is a 500 from the app: never a 200
        c.put(f"/v1/captures/{cap}/seal", json=_seal(cap), headers=AUTH)
    assert b.hits
    assert c.app.state.db.one("SELECT seal_json FROM captures WHERE capture_id=?", (cap,))["seal_json"] is None
    b.failing = False
    assert c.put(f"/v1/captures/{cap}/seal", json=_seal(cap), headers=AUTH).status_code == 200


@pytest.mark.parametrize("level", ["file", "capture", "device"])
def test_a_saved_but_unindexed_seal_is_trusted_only_once_confirmed(settings, monkeypatch, level):
    _free(monkeypatch, 50 * GiB)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    assert put_chunk(c, cap, 0, _envs(cap)[0]).status_code == 201
    vault = c.app.state.vault
    path = vault.seal_path(DEVICE, cap)
    vault_module.Vault.write_json(path, {"body": _seal(cap), "received_at": 1_790_000_000.0}, pretty=False)
    b = Barrier(monkeypatch, target(vault, level, path))
    with pytest.raises(OSError):
        c.put(f"/v1/captures/{cap}/seal", json=_seal(cap), headers=AUTH)
    assert c.app.state.db.one("SELECT seal_json FROM captures WHERE capture_id=?", (cap,))["seal_json"] is None
    b.failing = False
    assert c.put(f"/v1/captures/{cap}/seal", json=_seal(cap), headers=AUTH).status_code == 200


@pytest.mark.parametrize("level", ["file", "capture", "device"])
def test_the_startup_sweep_indexes_an_orphan_only_once_confirmed(settings, monkeypatch, level):
    _free(monkeypatch, 50 * GiB)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(c, cap, 0, bodies[0]).status_code == 201
    vault = c.app.state.vault
    path = vault.chunk_path(DEVICE, cap, 1)
    path.write_bytes(bodies[1])
    b = Barrier(monkeypatch, target(vault, level, path))
    restarted = fresh(settings)  # incremental sweep at startup
    assert rows(restarted, cap, 1) == 0, "an unconfirmed orphan stays unindexed"
    b.failing = False
    again = fresh(settings)
    assert rows(again, cap, 1) == 1 and path.read_bytes() == bodies[1]
