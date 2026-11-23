"""Independent publication-design review probes; no live services. (Astra IT4, adopted; marked xfail while IT4-05 is open.)"""
import errno
import uuid

import pytest
from omi_notes import rebuild
from omi_notes.vault import Vault
from .conftest import DEVICE, put_chunk
from .test_disk_full import _envs, _free, GiB
from .test_publication_matrix import fresh


@pytest.mark.xfail(strict=True, reason="ASTRA-20261122-IT4-05 open: the FULL rebuild still trusts a raw chunk whose receipt line is missing (stand-in time); fixing it needs the rebuild to persist receipts or withdraw rows (see REPORT 2026-11-23)")
def test_full_rebuild_must_record_missing_receipt_before_trusting_chunk(client, settings, monkeypatch):
    _free(monkeypatch, 50*GiB)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    vault = client.app.state.vault
    receipts = vault.receipts_path(DEVICE, cap)
    original = Vault.append_confirmed
    def failed_append(self, path, value):
        if path == receipts:
            raise OSError(errno.ENOSPC, 'synthetic failure before receipt append')
        return original(self, path, value)
    monkeypatch.setattr(Vault, 'append_confirmed', failed_append)
    assert put_chunk(client, cap, 0, body).status_code == 507
    assert not receipts.exists()
    assert client.app.state.db.one('SELECT 1 FROM chunks WHERE capture_id=?',(cap,)) is None
    monkeypatch.setattr(Vault, 'append_confirmed', original)
    client.app.state.db.set_meta('complete', '0')
    restarted = fresh(settings)
    row = restarted.app.state.db.one('SELECT received_at,sha256 FROM chunks WHERE capture_id=?',(cap,))
    assert row is not None
    assert put_chunk(restarted, cap, 0, body).status_code == 200
    lines = Vault.read_jsonl(receipts)
    print('FULL_REBUILD_WITHOUT_RECEIPT', dict(row), 'lines', lines)
    assert any(x.get('seq')==0 and x.get('sha256')==row['sha256'] and x.get('received_at')==row['received_at'] for x in lines), 'a rebuilt trusted row needs a durable matching receipt; header-end fallback alone is not authoritative evidence'
