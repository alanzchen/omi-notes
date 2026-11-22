"""Astra's IT5 variant (omi-notes-reviews/nightly-2026-11-21-it5/python), adopted as acceptance A1 (DURABILITY-DESIGN,
ASTRA-20261122-IT1). The two publication cases are unchanged; the cost case asserts the intended bound."""
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


def test_rebuild_cannot_turn_an_unsynced_orphan_into_a_stored_duplicate(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    db = client.app.state.db
    row = db.one('SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=0', (cap,))
    folder = (settings.vault_dir / row['path']).parent
    real = spool.fsync_dir
    failed = []

    def cannot_sync(path):
        if path == folder:
            failed.append(str(path))
            raise OSError(errno.ENOSPC, 'synthetic persistent directory sync failure')
        return real(path)

    monkeypatch.setattr(spool, 'fsync_dir', cannot_sync)
    monkeypatch.setattr(vault_module, 'fsync_dir', cannot_sync)
    assert put_chunk(client, cap, 1, bodies[1]).status_code == 507
    assert db.one('SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=1', (cap,)) is None
    before = len(failed)
    # Normal startup sees an index marked incomplete and takes the complete rebuild branch.
    db.set_meta('complete', '0')
    restarted = TestClient(create_app(settings, start_worker=False))
    answer = put_chunk(restarted, cap, 1, bodies[1])
    after = len(failed)
    row1 = restarted.app.state.db.one('SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=1', (cap,))
    assert (folder / '1.omnc').read_bytes() == bodies[1]
    print('REBUILD_ORPHAN', answer.status_code, 'sync_failures_before_after', before, after, 'row', row1 is not None)
    assert answer.status_code == 507, 'a full rebuild must not turn unconfirmed directory publication into a stored 200'
    assert row1 is None


def test_retry_cannot_trust_an_unsynced_new_capture_directory(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    first_cap = str(uuid.uuid4())
    assert put_chunk(client, first_cap, 0, _envs(first_cap)[0]).status_code == 201
    device_dir = client.app.state.vault.capture_dir(DEVICE, first_cap).parent
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    failures = []
    real = spool.fsync_dir

    def cannot_sync(path):
        if path == device_dir:
            failures.append(str(path))
            raise OSError(errno.ENOSPC, 'synthetic device-directory publication failure')
        return real(path)

    monkeypatch.setattr(spool, 'fsync_dir', cannot_sync)
    monkeypatch.setattr(vault_module, 'fsync_dir', cannot_sync)
    first = put_chunk(client, cap, 0, body)
    assert first.status_code == 507
    cap_dir = client.app.state.vault.capture_dir(DEVICE, cap)
    assert cap_dir.exists() and not (cap_dir / '0.omnc').exists()
    second = put_chunk(client, cap, 0, body)
    print('PARENT_DIR_RETRY', first.status_code, second.status_code, 'failed_parent_syncs', len(failures))
    assert second.status_code == 507, 'directory existence is not evidence its entry was synced in its parent'
    assert client.app.state.db.one('SELECT 1 FROM chunks WHERE capture_id=?', (cap,)) is None


@pytest.mark.parametrize('orphan_count', [1, 8])
def test_recovery_fsync_cost_scales_with_prior_orphans(client, settings, monkeypatch, orphan_count):
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
    # adapted (Astra IT1 §6): the intended bound, not the N+1 characterization: this identity's chunk and its receipt
    # file, the same for 1 or 8 other orphans
    assert [p.name for p in checked] == [f'{seq}.omnc', 'receipts.jsonl']


def test_a_legacy_complete_index_is_audited_before_its_duplicate_fast_path(client, settings, monkeypatch):
    """A1 (legacy trust): an index built under the old rule (no `publication_contract`) holds a row whose file never
    reached its directory durably. A restart must not answer that identity 200 from the old row: the index is rebuilt
    once, confirming every file, and the unconfirmable capture stays unindexed until its own retry can prove it."""
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    db = client.app.state.db
    folder = client.app.state.vault.capture_dir(DEVICE, cap)
    db.set_meta('publication_contract', None)  # as an index from before this rule
    real = spool.fsync_dir

    def cannot_sync(path):
        if path == folder:
            raise OSError(errno.ENOSPC, 'synthetic persistent directory sync failure')
        return real(path)

    monkeypatch.setattr(spool, 'fsync_dir', cannot_sync)
    monkeypatch.setattr(vault_module, 'fsync_dir', cannot_sync)
    restarted = TestClient(create_app(settings, start_worker=False))
    assert restarted.app.state.db.meta('publication_contract') is not None, 'the legacy index was audited (rebuilt)'
    assert restarted.app.state.db.one('SELECT 1 FROM chunks WHERE capture_id=?', (cap,)) is None
    assert put_chunk(restarted, cap, 0, bodies[0]).status_code == 507, 'no 200 from an unaudited legacy row'
    monkeypatch.setattr(spool, 'fsync_dir', real)
    monkeypatch.setattr(vault_module, 'fsync_dir', real)
    assert put_chunk(restarted, cap, 0, bodies[0]).status_code == 200  # provable now: adopted, original bytes kept
    assert (folder / '0.omnc').read_bytes() == bodies[0]
