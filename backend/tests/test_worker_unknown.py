from __future__ import annotations
import errno
import uuid
from omi_notes import disk_alert, ingest
from .conftest import AUTH, put_chunk
from .test_disk_full import GiB, Usage, _envs, _free

def test_worker_unmeasurable_observation_does_not_leave_status_healthy(client,settings,monkeypatch):
    _free(monkeypatch,50*GiB)
    cap=str(uuid.uuid4())
    assert put_chunk(client,cap,0,_envs(cap)[0]).status_code==201
    assert client.get('/v1/status',headers=AUTH).json()['disk']=={'full':False}
    def unmeasurable(path):
        raise OSError(errno.EACCES,'synthetic measurement failure')
    monkeypatch.setattr(disk_alert.shutil,'disk_usage',unmeasurable)
    disk_alert.watch(settings.logs_dir,settings.vault_dir,floor_bytes=ingest.MIN_FREE_BYTES,
                     now=100000,other_dirs=[settings.db_path.parent])
    actual=client.get('/v1/status',headers=AUTH).json()['disk']
    print('AFTER_WORKER_UNMEASURABLE',actual)
    assert actual is None, 'newer unknown measurements cannot leave a current-looking healthy disk field'
