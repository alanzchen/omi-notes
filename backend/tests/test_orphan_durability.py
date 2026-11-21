"""ASTRA-20261121-IT3-01 (blocker): a file found on disk was trusted as stored (hash matched -> receipt, row, 200)
without any successful sync of its directory: a matching hash proves content, not durable publication. Astra's repro
(omi-notes-reviews/nightly-2026-11-21-it3/python/test_round3_checks.py), adapted to the required outcome, plus
controls: seq 0, an orphan that already has its receipt (the recovery/reindex path), and an existing alternate."""

from __future__ import annotations

import errno
import uuid

from omi_notes import ingest, spool
from omi_notes import vault as vault_module
from omi_notes.db import Database
from omi_notes.envelope import build_envelope, parse_envelope
from omi_notes.vault import Vault

from .conftest import DEVICE, put_chunk
from .test_disk_full import GiB, _envs, _free, _rows


class _Dir:
    """fsync of one directory fails (ENOSPC) while `failing` is set."""

    def __init__(self, monkeypatch, folder):
        self.folder, self.failing, self.calls = folder, True, 0
        real = spool.fsync_dir

        def fsync_dir(path):
            if self.failing and path == self.folder:
                self.calls += 1
                raise OSError(errno.ENOSPC, "synthetic persistent directory sync failure")
            return real(path)

        monkeypatch.setattr(spool, "fsync_dir", fsync_dir)
        monkeypatch.setattr(vault_module, "fsync_dir", fsync_dir, raising=False)


def _folder(settings, cap, seq=0):
    row = Database(settings.db_path).one("SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=?", (cap, seq))
    return (settings.vault_dir / row["path"]).parent


def _row(settings, cap, seq):
    return Database(settings.db_path).one("SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=?", (cap, seq))


def test_orphan_retry_requires_a_successful_directory_sync(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    d = _Dir(monkeypatch, _folder(settings, cap))
    assert put_chunk(client, cap, 1, bodies[1]).status_code == 507  # renamed into place, directory never synced
    assert put_chunk(client, cap, 1, bodies[1]).status_code == 507, "no successful directory sync: not stored"
    assert _row(settings, cap, 1) is None
    d.failing = False
    assert put_chunk(client, cap, 1, bodies[1]).status_code in (200, 201)
    row = _row(settings, cap, 1)
    assert row is not None and (settings.vault_dir / row["path"]).read_bytes() == bodies[1]
    assert put_chunk(client, cap, 1, bodies[0]).status_code == 409
    assert (settings.vault_dir / row["path"]).read_bytes() == bodies[1], "existing bytes never rewritten"


def test_a_first_chunk_orphan_needs_the_sync_too(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    folder = Vault.open(settings).chunk_path(DEVICE, cap, 0).parent
    d = _Dir(monkeypatch, folder)
    assert put_chunk(client, cap, 0, body).status_code == 507
    assert put_chunk(client, cap, 0, body).status_code == 507
    assert _rows(settings, cap) == 0
    d.failing = False
    assert put_chunk(client, cap, 0, body).status_code in (200, 201)
    assert _rows(settings, cap) == 1


def test_an_orphan_with_its_receipt_goes_through_recovery_and_still_needs_the_sync(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    real = ingest.index_chunk
    calls = {"n": 0}

    def full_once(*a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            exc = __import__("sqlite3").OperationalError("database or disk is full")
            exc.sqlite_errorcode = __import__("sqlite3").SQLITE_FULL
            raise exc
        return real(*a, **k)

    monkeypatch.setattr(ingest, "index_chunk", full_once)
    assert put_chunk(client, cap, 1, bodies[1]).status_code == 507  # file synced + receipt written, row failed
    d = _Dir(monkeypatch, _folder(settings, cap))
    assert put_chunk(client, cap, 1, bodies[1]).status_code == 507, "recovery re-indexes only after a sync now"
    assert _row(settings, cap, 1) is None
    d.failing = False
    assert put_chunk(client, cap, 1, bodies[1]).status_code in (200, 201)
    assert _row(settings, cap, 1) is not None


def test_an_existing_alternate_is_trusted_only_after_a_sync(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    assert put_chunk(client, cap, 0, body).status_code == 201
    env = parse_envelope(body, capture_id=cap, chunk_sequence=0)
    header = env.header.model_dump(mode="json", exclude_none=True)
    header["app_version"] = "omi-notes-other-build"
    other = build_envelope(header, env.payload)
    assert other != body
    # the synthetic payload can't be decoded for an audio comparison: say "same audio", as a real re-encoding would be
    monkeypatch.setattr(ingest, "same_audio", lambda a, b: True)
    first = put_chunk(client, cap, 0, other)
    assert first.status_code == 200, first.text  # same audio, kept as an alternate
    alternates = _folder(settings, cap) / "alternates"
    assert any(alternates.iterdir())
    d = _Dir(monkeypatch, alternates)
    assert put_chunk(client, cap, 0, other).status_code == 507, "an alternate found on disk needs its directory synced"
    d.failing = False
    assert put_chunk(client, cap, 0, other).status_code == 200


def test_the_startup_sweep_skips_a_capture_it_cannot_sync_and_goes_on(client, settings, monkeypatch):
    from omi_notes import rebuild

    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    d = _Dir(monkeypatch, _folder(settings, cap))
    assert put_chunk(client, cap, 1, bodies[1]).status_code == 507  # an orphan without its row
    db = Database(settings.db_path)
    rebuild.sweep(db, Vault.open(settings, create=False))  # must not raise
    assert _row(settings, cap, 1) is None
    d.failing = False
    rebuild.sweep(db, Vault.open(settings, create=False))
    assert _row(settings, cap, 1) is not None
