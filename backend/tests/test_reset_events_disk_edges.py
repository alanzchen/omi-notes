"""Independent reset controls: bounded event retry and observation ordering."""
import errno
import os
import uuid
from pathlib import Path
import pytest
from omi_notes import disk_alert, ingest
from omi_notes.vault import Vault
from .conftest import AUTH, DEVICE, put_chunk
from .test_disk_full import _envs, _free, GiB
from .test_review_events_nov23 import NOW, event, fail_one_append_sync


def test_worker_unknown_between_measurement_and_healthy_publication_is_not_erased(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    real_witness = disk_alert.witness
    real_usage = disk_alert.shutil.disk_usage
    def raced_witness(*a, **kw):
        verdict = real_witness(*a, **kw)
        assert verdict is True
        def unavailable(_):
            raise OSError(errno.EACCES, "synthetic volume became unmeasurable")
        monkeypatch.setattr(disk_alert.shutil, "disk_usage", unavailable)
        disk_alert.watch(settings.logs_dir, settings.vault_dir, floor_bytes=ingest.MIN_FREE_BYTES,
                         now=100000, other_dirs=[settings.db_path.parent])
        monkeypatch.setattr(disk_alert.shutil, "disk_usage", real_usage)
        return verdict
    monkeypatch.setattr(disk_alert, "witness", raced_witness)
    cap = str(uuid.uuid4())
    assert put_chunk(client, cap, 0, _envs(cap)[0]).status_code == 201
    result = client.get("/v1/status", headers=AUTH).json()["disk"]
    print("RACED_DISK_STATUS", result, "unknown",disk_alert.last_unknown,"healthy",client.app.state.ingest.healthy_seq)
    assert result is None, "an observation after the healthy measurement must not be overwritten by its late publication"


@pytest.mark.parametrize("torn_prefix", [False, True])
def test_own_line_retry_handles_optional_separator_and_many_later_lines(client, monkeypatch, torn_prefix):
    v=client.app.state.vault; client.app.state.ingest.clock=lambda:NOW
    p=v.events_path(NOW);p.parent.mkdir(parents=True,exist_ok=True)
    p.write_bytes(b'{"torn":' if torn_prefix else b'')
    fail_one_append_sync(monkeypatch,p)
    eid=str(uuid.uuid4());body=event()
    with pytest.raises(OSError):client.put(f"/v1/events/{eid}",json=body,headers=AUTH)
    for _ in range(16):
        assert client.put(f"/v1/events/{uuid.uuid4()}",json=body,headers=AUTH).status_code==201
    before=p.read_bytes()
    response=client.put(f"/v1/events/{eid}",json=body,headers=AUTH)
    assert response.status_code==200 and response.json()["duplicate"] is True
    assert p.read_bytes()==before
    assert len([x for x in Vault.read_jsonl(p) if x["event_id"]==eid])==1


def test_own_line_retry_republishes_after_partial_append_exception(client, monkeypatch):
    v=client.app.state.vault;client.app.state.ingest.clock=lambda:NOW
    p=v.events_path(NOW);p.parent.mkdir(parents=True,exist_ok=True);p.touch()
    real_append=Vault.append_jsonl
    once=[True]
    def partial(path, value):
        if path==p and once[0]:
            once[0]=False
            with path.open("ab") as f:
                f.write(b'{"event_id":"torn')
            raise OSError(errno.ENOSPC, "synthetic partial append")
        return real_append(path,value)
    monkeypatch.setattr(Vault,"append_jsonl",staticmethod(partial))
    eid=str(uuid.uuid4());body=event()
    with pytest.raises(OSError):client.put(f"/v1/events/{eid}",json=body,headers=AUTH)
    assert client.app.state.db.one("SELECT 1 FROM events WHERE event_id=?",(eid,)) is None
    assert client.put(f"/v1/events/{eid}",json=body,headers=AUTH).status_code==201
    assert client.put(f"/v1/events/{eid}",json=body,headers=AUTH).status_code==200
    assert len([x for x in Vault.read_jsonl(p) if x["event_id"]==eid])==1


def test_worker_low_space_with_unwritable_alert_does_not_leave_healthy(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    assert put_chunk(client, cap, 0, _envs(cap)[0]).status_code == 201
    assert client.get("/v1/status", headers=AUTH).json()["disk"] == {"full":False}
    _free(monkeypatch, 1 * GiB)
    real = Vault.write_json
    def full_alert(path, *a, **kw):
        if path == settings.logs_dir / "alerts" / "disk.json":
            raise OSError(errno.ENOSPC, "synthetic alert filesystem full")
        return real(path, *a, **kw)
    monkeypatch.setattr(Vault,"write_json",staticmethod(full_alert))
    disk_alert.watch(settings.logs_dir, settings.vault_dir, floor_bytes=ingest.MIN_FREE_BYTES,
                     now=100000, other_dirs=[settings.db_path.parent])
    result=client.get("/v1/status",headers=AUTH).json()["disk"]
    print("WORKER_FULL_ALERT_UNWRITABLE",result)
    assert result != {"full":False}, "known low space cannot be masked by inability to persist its alarm"
