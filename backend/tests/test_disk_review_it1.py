"""Astra's IT1 repro checks (omi-notes-reviews/nightly-2026-11-21-it1/python/test_disk_delta.py), adopted as regressions.
One documented the defect and is inverted to assert the fix: the threshold check (no down/recovered churn at the floor).
The index-full recovery check now also asserts recovery once the index has written again."""
from __future__ import annotations
import errno, json, sqlite3, uuid
import pytest
from fastapi.testclient import TestClient
from omi_notes import disk_alert, ingest
from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.vault import Vault
from .conftest import put_chunk
from .test_disk_full import _envs, _free, _rows, GiB


def test_alert_enospc_does_not_replace_507(client, settings, monkeypatch):
    _free(monkeypatch, GiB)
    real = Vault.write_json
    def failing_alert(path, value, **kwargs):
        if path.name == 'disk.json': raise OSError(errno.ENOSPC, 'synthetic alert ENOSPC')
        return real(path, value, **kwargs)
    monkeypatch.setattr(Vault, 'write_json', staticmethod(failing_alert))
    cap=str(uuid.uuid4()); body=_envs(cap)[0]
    response=put_chunk(client, cap, 0, body)
    assert response.status_code == 507
    assert _rows(settings,cap)==0


def test_truthy_nonobject_alert_does_not_turn_507_or_worker_into_exception(settings, worker, monkeypatch):
    alert=settings.logs_dir/'alerts'/'disk.json'; alert.parent.mkdir(parents=True,exist_ok=True)
    alert.write_text('[1]')
    _free(monkeypatch, GiB)
    cap=str(uuid.uuid4())
    with TestClient(create_app(settings,start_worker=False), raise_server_exceptions=False) as client:
        response=put_chunk(client,cap,0,_envs(cap)[0])
    worker_error=None
    try: worker.tick()
    except Exception as e: worker_error=repr(e)
    print('MALFORMED_ALERT',response.status_code,worker_error)
    assert response.status_code == 507 and worker_error is None


def test_persistent_receipt_full_retry_remains_507_and_audio_survives(settings, monkeypatch):
    _free(monkeypatch,50*GiB)
    cap=str(uuid.uuid4()); body=_envs(cap)[0]; real=Vault.append_jsonl
    def full(path,value): raise OSError(errno.ENOSPC,'synthetic receipt ENOSPC')
    with TestClient(create_app(settings,start_worker=False),raise_server_exceptions=False) as client:
        monkeypatch.setattr(Vault,'append_jsonl',staticmethod(full))
        statuses=[put_chunk(client,cap,0,body).status_code for _ in range(2)]
        monkeypatch.setattr(Vault,'append_jsonl',staticmethod(real))
        recovered=put_chunk(client,cap,0,body)
        paths=list((settings.vault_dir/'raw').rglob('*.omi'))
        print('PERSISTENT_RECEIPT',statuses,'recovered',recovered.status_code)
        assert recovered.status_code in (200,201)
        assert _rows(settings,cap)==1
        row=Database(settings.db_path).one('SELECT path FROM chunks WHERE capture_id=?',(cap,))
        assert (settings.vault_dir/row['path']).read_bytes()==body
        assert statuses==[507,507]


def test_real_sqlite_full_is_not_masked_by_rollback(tmp_path):
    db=Database(tmp_path/'db.sqlite3'); c=db.conn()
    c.execute('CREATE TABLE astra_filler(value BLOB)')
    pages=c.execute('PRAGMA page_count').fetchone()[0]
    c.execute(f'PRAGMA max_page_count={pages}')
    failure=None
    try:
        with db.tx() as conn: conn.execute('INSERT INTO astra_filler VALUES(zeroblob(2000000))')
    except sqlite3.OperationalError as e: failure=e
    assert failure is not None
    print('REAL_SQLITE_FULL',str(failure),'cause',repr(failure.__context__))
    assert c.execute('SELECT count(*) FROM astra_filler').fetchone()[0]==0
    assert ingest._disk_full_error(failure)


def test_threshold_has_hysteresis_and_file_is_bounded(settings,monkeypatch):
    alert=settings.logs_dir/'alerts'/'disk.json'; sizes=[]; states=[]
    for i,free in enumerate([ingest.MIN_FREE_BYTES-1,ingest.MIN_FREE_BYTES,ingest.MIN_FREE_BYTES-1,ingest.MIN_FREE_BYTES]):
        _free(monkeypatch,free)
        disk_alert.watch(settings.logs_dir,settings.vault_dir,floor_bytes=ingest.MIN_FREE_BYTES,now=100000+i)
        value=json.loads(alert.read_text());states.append(value['state']);sizes.append(alert.stat().st_size)
    assert states==['down','down','down','down'], states  # (inverted) one byte over the floor is not recovery
    assert max(sizes)<2048


def test_recovery_does_not_claim_an_index_full_error_is_resolved_from_vault_space_alone(settings, monkeypatch):
    _free(monkeypatch, 50*GiB)
    disk_alert.note_down(settings.logs_dir,free_bytes=50*GiB,floor_bytes=ingest.MIN_FREE_BYTES,
                         reason="storing a chunk's receipt/index failed: database or disk is full",now=100000)
    disk_alert.watch(settings.logs_dir,settings.vault_dir,floor_bytes=ingest.MIN_FREE_BYTES,now=100001)
    state=json.loads((settings.logs_dir/'alerts'/'disk.json').read_text())
    assert state['state']=='down'
    # once a publication begun after the alert has committed (the API's witness, DESIGN-07), it is recovered
    rev = disk_alert.revision(settings.logs_dir)
    disk_alert.witness(settings.logs_dir,[settings.vault_dir],floor_bytes=ingest.MIN_FREE_BYTES,now=100003,since_revision=rev)
    assert json.loads((settings.logs_dir/'alerts'/'disk.json').read_text())['state']=='recovered'
