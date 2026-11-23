# Astra's IT4 monitor probes (omi-notes-reviews/nightly-2026-11-22-it4/python), adopted (import depth adjusted). The nested
# rollback probe follows her first suggested fix (publication requires its own transaction): the call is refused inside the
# outer transaction instead of answering 201; her final assertions are unchanged.
from __future__ import annotations
import errno
import uuid
import pytest
from omi_notes import disk_alert, ingest
from .conftest import AUTH, put_chunk
from .test_disk_full import GiB, Usage, _envs, _free

@pytest.mark.parametrize("condition",["low", "unmeasurable"])
def test_later_failed_volume_observation_invalidates_prior_healthy(client,settings,monkeypatch,condition):
    _free(monkeypatch,50*GiB)
    first=str(uuid.uuid4())
    assert put_chunk(client,first,0,_envs(first)[0]).status_code==201
    assert client.get('/v1/status',headers=AUTH).json()['disk']=={'full':False}
    def free(path):
        if path==settings.db_path.parent:
            if condition=='unmeasurable': raise OSError(errno.EACCES,'synthetic index stat unavailable')
            return Usage(100*GiB,99*GiB,GiB)
        return Usage(100*GiB,50*GiB,50*GiB)
    monkeypatch.setattr(disk_alert.shutil,'disk_usage',free)
    second=str(uuid.uuid4())
    assert put_chunk(client,second,0,_envs(second)[0]).status_code==201
    actual=client.get('/v1/status',headers=AUTH).json()['disk']
    assert actual != {'full':False}, (condition,actual)

def test_corrupt_monitor_during_first_publication_is_not_a_healthy_observation(client,settings,monkeypatch):
    _free(monkeypatch,50*GiB)
    path=settings.logs_dir/'alerts'/'disk.json';path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text('not json')
    cap=str(uuid.uuid4())
    assert put_chunk(client,cap,0,_envs(cap)[0]).status_code==201
    assert client.get('/v1/status',headers=AUTH).json()['disk'] is None

def test_unreadable_revision_cannot_reuse_a_failure_identity(client,settings,monkeypatch):
    _free(monkeypatch,50*GiB)
    first=disk_alert.note_down(settings.logs_dir,free_bytes=None,floor_bytes=ingest.MIN_FREE_BYTES,reason='first',now=100)
    snapshot=disk_alert.revision(settings.logs_dir)
    path=settings.logs_dir/'alerts'/'disk.json'
    path.write_text('corrupt during outage')
    second=disk_alert.note_down(settings.logs_dir,free_bytes=None,floor_bytes=ingest.MIN_FREE_BYTES,reason='newer',now=200)
    assert first is not None and second is not None
    result=disk_alert.witness(settings.logs_dir,[settings.vault_dir,settings.db_path.parent],floor_bytes=ingest.MIN_FREE_BYTES,now=300,since_revision=snapshot)
    assert result is not True, (first,second,result)
    assert disk_alert.read(settings.logs_dir)['state']=='down'


def test_outer_rollback_is_not_publication_recovery_evidence(client,settings,monkeypatch):
    import hashlib
    from omi_notes.db import Database
    from omi_notes.vault import Vault
    _free(monkeypatch,50*GiB)
    disk_alert.note_down(settings.logs_dir,free_bytes=None,floor_bytes=ingest.MIN_FREE_BYTES,reason='before tx',now=100)
    db=Database(settings.db_path)
    writer=ingest.Ingest(db,Vault.open(settings),settings)
    cap=str(uuid.uuid4());body=_envs(cap)[0]
    class Rollback(Exception): pass
    with pytest.raises(Rollback):
        with db.tx():
            with pytest.raises(RuntimeError):  # (adapted) refused: it would answer before the outer COMMIT
                writer.put_chunk(cap,0,body,hashlib.sha256(body).hexdigest())
            raise Rollback()
    assert db.one('SELECT COUNT(*) AS n FROM chunks WHERE capture_id=?',(cap,))['n']==0
    assert disk_alert.read(settings.logs_dir)['state']=='down', 'An inner joined tx returned before outer rollback; no commit witness exists'
