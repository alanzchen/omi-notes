"""ASTRA-20261121-IT5-02: a PUT to a dirty capture synced every orphan of the capture under the global ingest lock.
Astra's cost repro (omi-notes-reviews/nightly-2026-11-21-it5/python/test_durability_build_variant.py), adapted: the
request does durable work only for its own identity; bulk recovery stays with the startup sweep."""
import errno
import sqlite3
import uuid

import pytest

from fastapi.testclient import TestClient
from omi_notes import ingest, spool, vault as vault_module
from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.devtools import live_envelopes, synth_speech_like
from .conftest import put_chunk
from .conftest import DEVICE
from .helpers import STARTED
from .test_disk_full import _envs, _free, GiB


@pytest.mark.parametrize('orphan_count', [1, 8])
def test_one_put_syncs_only_its_own_identity(client, settings, monkeypatch, orphan_count):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = live_envelopes(synth_speech_like((orphan_count + 3) * 2.0), capture_id=cap,
        device_id=DEVICE, started_at=STARTED, chunk_seconds=2.0)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    folder = client.app.state.vault.capture_dir(DEVICE, cap)
    real = spool.fsync_dir
    fail_sync = {'yes': True}

    def sync(path):
        if fail_sync['yes'] and path == folder:
            raise OSError(errno.ENOSPC, 'synthetic orphan-producing failure')
        return real(path)

    monkeypatch.setattr(spool, 'fsync_dir', sync)
    monkeypatch.setattr(vault_module, 'fsync_dir', sync)
    for seq in range(1, orphan_count + 1):
        assert put_chunk(client, cap, seq, bodies[seq]).status_code == 507
    fail_sync['yes'] = False
    real_index = ingest.index_chunk
    fail_index = {'yes': True}

    def index_once(*args, **kwargs):
        if fail_index['yes']:
            fail_index['yes'] = False
            exc = sqlite3.OperationalError('database or disk is full')
            exc.sqlite_errorcode = sqlite3.SQLITE_FULL
            raise exc
        return real_index(*args, **kwargs)

    monkeypatch.setattr(ingest, 'index_chunk', index_once)
    seq = orphan_count + 1
    assert put_chunk(client, cap, seq, bodies[seq]).status_code == 507  # file durable, marks capture dirty
    checked = []
    real_check = ingest.durable_existing

    def check(path, *rest):
        checked.append(path)
        return real_check(path, *rest)

    monkeypatch.setattr(ingest, 'durable_existing', check)
    assert put_chunk(client, cap, seq, bodies[seq]).status_code == 200
    print('REQUEST_RECOVERY_COST', orphan_count, 'prior_orphans', len(checked), 'file_dir_sync_pairs')
    # (adapted to the fix: the request syncs only its own identity, whatever the number of other orphans)
    # this identity only (its chunk and its receipt file, both confirmed to the vault root), whatever the orphan count
    assert [p.name for p in checked] == [f'{seq}.omnc', 'receipts.jsonl'], (orphan_count, checked)
