"""Astra's IT7 delta checks (omi-notes-reviews/nightly-2026-11-21-it7/python), adopted unchanged: acceptance A3/A4."""
import sqlite3
import uuid
import pytest
from fastapi.testclient import TestClient
from omi_notes import ingest
from omi_notes.vault import Vault
from omi_notes.devtools import live_envelopes, synth_speech_like
from .conftest import AUTH, DEVICE, put_chunk
from .helpers import STARTED
from .test_disk_full import _free, GiB
from .test_api import seal_body


def fail_index_once(monkeypatch, name):
    original = getattr(ingest, name)
    pending = [True]
    def replacement(*args, **kwargs):
        if pending[0]:
            pending[0] = False
            exc = sqlite3.OperationalError('database or disk is full')
            exc.sqlite_errorcode = sqlite3.SQLITE_FULL
            raise exc
        return original(*args, **kwargs)
    monkeypatch.setattr(ingest, name, replacement)


@pytest.mark.parametrize('prior_chunks', [1, 8])
def test_orphan_adoption_does_not_read_other_chunk_receipts(client, monkeypatch, prior_chunks):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = live_envelopes(synth_speech_like((prior_chunks + 2) * 2), capture_id=cap,
                           device_id=DEVICE, started_at=STARTED, chunk_seconds=2.0)
    for seq in range(prior_chunks):
        assert put_chunk(client, cap, seq, bodies[seq]).status_code == 201
    fail_index_once(monkeypatch, 'index_chunk')
    assert put_chunk(client, cap, prior_chunks, bodies[prior_chunks]).status_code == 507
    entries = []
    real = Vault.read_jsonl
    receipt_path = client.app.state.vault.receipts_path(DEVICE, cap)
    def traced(path):
        lines = real(path)
        if path == receipt_path:
            entries.append(len(lines))
        return lines
    monkeypatch.setattr(Vault, 'read_jsonl', staticmethod(traced))
    assert put_chunk(client, cap, prior_chunks, bodies[prior_chunks]).status_code == 200
    print('ADOPTION_RECEIPTS', prior_chunks, entries)
    assert sum(entries) <= 1, 'one identity adoption must not parse every earlier receipt under the ingest lock'


def test_chunk_after_durable_unindexed_seal_still_obeys_seal(client, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = live_envelopes(synth_speech_like(6), capture_id=cap,
                           device_id=DEVICE, started_at=STARTED, chunk_seconds=2.0)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    fail_index_once(monkeypatch, 'index_seal')
    lenient = TestClient(client.app, raise_server_exceptions=False)
    assert lenient.put(f'/v1/captures/{cap}/seal', json=seal_body(0), headers=AUTH).status_code == 500
    assert client.app.state.vault.seal_path(DEVICE, cap).exists()
    result = put_chunk(client, cap, 1, bodies[1])
    print('ORPHAN_SEAL_THEN_CHUNK', result.status_code, result.json())
    assert result.status_code == 409 and result.json()['error'] == 'beyond_seal'
    assert client.app.state.db.one('SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=1', (cap,)) is None
