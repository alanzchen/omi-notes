"""Independent event acceptance probes: no real network/services.
(Adopted from omi-notes-reviews/nightly-2026-11-22-it4/python. One adaptation: the reopened app gets the same fixed clock,
so its retry targets the same day file whose fault is still active, as the scenario intends; without it the retry lands
in today's (healthy) file and is correctly stored. Assertions unchanged.)"""
import errno
import os
import uuid
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from omi_notes import rebuild
from omi_notes.vault import Vault
from .conftest import AUTH, DEVICE
from .helpers import iso
from .test_publication_matrix import Barrier, fresh

NOW=1795320000.0

def event():
    return {"device_id":DEVICE,"type":"heartbeat","at":iso(NOW),"data":{}}

@pytest.mark.parametrize("mode",["incremental","full"])
def test_unconfirmed_event_cannot_be_adopted_after_restart(settings,monkeypatch,mode):
    c=fresh(settings);v=c.app.state.vault
    # Fixed timestamp selects the one synthetic day file.
    c.app.state.ingest.clock=lambda:NOW
    p=v.events_path(NOW);p.parent.mkdir(parents=True,exist_ok=True);p.touch()
    barrier=Barrier(monkeypatch,p)
    eid=str(uuid.uuid4());body=event()
    with pytest.raises(OSError):c.put(f"/v1/events/{eid}",json=body,headers=AUTH)
    assert barrier.hits and Vault.read_jsonl(p)
    assert c.app.state.db.one("SELECT 1 FROM events WHERE event_id=?",(eid,)) is None
    if mode=="full":rebuild.rebuild(settings,v)
    reopened=fresh(settings)
    reopened.app.state.ingest.clock=lambda:NOW
    row=reopened.app.state.db.one("SELECT 1 FROM events WHERE event_id=?",(eid,))
    duplicate=TestClient(reopened.app,raise_server_exceptions=False).put(f"/v1/events/{eid}",json=body,headers=AUTH)  # (adapted: the server error as a status)
    print("EVENT_RESTART",mode,"row",row is not None,"retry",duplicate.status_code,"barrier_hits",barrier.hits)
    assert row is None,"Event must remain untrusted while its file fsync still fails"
    assert duplicate.status_code>=500


def test_event_append_fsync_failure_does_not_append_a_second_line(client,monkeypatch):
    v=client.app.state.vault;client.app.state.ingest.clock=lambda:NOW
    p=v.events_path(NOW);p.parent.mkdir(parents=True,exist_ok=True);p.touch()
    real_open=os.open;real_fsync=os.fsync;target_fds=set();fail=[True]
    def traced_open(path,flags,*args,**kwargs):
        fd=real_open(path,flags,*args,**kwargs)
        if Path(path)==p:target_fds.add(fd)
        return fd
    def fail_sync(fd):
        if fd in target_fds and fail[0]:
            fail[0]=False
            raise OSError(errno.ENOSPC,"synthetic event append fsync full")
        return real_fsync(fd)
    monkeypatch.setattr(os,"open",traced_open);monkeypatch.setattr(os,"fsync",fail_sync)
    eid=str(uuid.uuid4());body=event()
    with pytest.raises(OSError):client.put(f"/v1/events/{eid}",json=body,headers=AUTH)
    before=Vault.read_jsonl(p);assert len(before)==1
    response=client.put(f"/v1/events/{eid}",json=body,headers=AUTH)
    lines=Vault.read_jsonl(p)
    print("EVENT_APPEND_RETRY",response.status_code,"lines",len(lines),"same_time",len({x['received_at'] for x in lines}))
    assert len(lines)==1,"A successful append followed by fsync failure is not a never-appended event"
    assert response.status_code==200 and response.json()["duplicate"] is True
