"""Independent November23 event retry bounds and fail-closed controls."""
import builtins
import errno
import os
import uuid
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from omi_notes.vault import Vault
from .conftest import AUTH, DEVICE
from .helpers import iso
from .test_publication_matrix import Barrier, fresh

NOW=1795320000.0

def event():
    return {"device_id":DEVICE,"type":"heartbeat","at":iso(NOW),"data":{}}

def fail_one_append_sync(monkeypatch,p):
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

@pytest.mark.parametrize("later_events",[0,128])
def test_uncertain_event_retry_reads_only_its_record(client,monkeypatch,later_events):
    v=client.app.state.vault;client.app.state.ingest.clock=lambda:NOW
    p=v.events_path(NOW);p.parent.mkdir(parents=True,exist_ok=True);p.touch()
    fail_one_append_sync(monkeypatch,p)
    eid=str(uuid.uuid4());body=event()
    with pytest.raises(OSError):client.put(f"/v1/events/{eid}",json=body,headers=AUTH)
    own_size=p.stat().st_size
    for _ in range(later_events):
        assert client.put(f"/v1/events/{uuid.uuid4()}",json=body,headers=AUTH).status_code==201
    counts=[];real_builtin_open=builtins.open
    class ReadCounter:
        def __init__(self,f):self.f=f
        def __enter__(self):self.f.__enter__();return self
        def __exit__(self,*args):return self.f.__exit__(*args)
        def __getattr__(self,key):return getattr(self.f,key)
        def read(self,*args):
            result=self.f.read(*args);counts.append(len(result));return result
    def counted_open(path,*args,**kwargs):
        f=real_builtin_open(path,*args,**kwargs)
        return ReadCounter(f) if Path(path)==p and args and args[0]=="rb" else f
    monkeypatch.setattr(builtins,"open",counted_open)
    response=client.put(f"/v1/events/{eid}",json=body,headers=AUTH)
    monkeypatch.setattr(builtins,"open",real_builtin_open)
    assert response.status_code==200 and response.json()["duplicate"] is True
    assert len([x for x in Vault.read_jsonl(p) if x["event_id"]==eid])==1
    print("EVENT_RETRY_BYTES",later_events,"own",own_size,"read",sum(counts),"file",p.stat().st_size)
    assert sum(counts)<=own_size+1024,"Retry must not read later unrelated event history under the global ingest lock"

@pytest.mark.parametrize("mode",["incremental","full"])
def test_restart_keeps_the_same_failed_day_file_untrusted(settings,monkeypatch,mode):
    from omi_notes import rebuild
    c=fresh(settings);v=c.app.state.vault;c.app.state.ingest.clock=lambda:NOW
    p=v.events_path(NOW);p.parent.mkdir(parents=True,exist_ok=True);p.touch()
    barrier=Barrier(monkeypatch,p);eid=str(uuid.uuid4());body=event()
    with pytest.raises(OSError):c.put(f"/v1/events/{eid}",json=body,headers=AUTH)
    if mode=="full":rebuild.rebuild(settings,v)
    reopened=fresh(settings);reopened.app.state.ingest.clock=lambda:NOW
    assert reopened.app.state.db.one("SELECT 1 FROM events WHERE event_id=?",(eid,)) is None
    response=TestClient(reopened.app,raise_server_exceptions=False).put(f"/v1/events/{eid}",json=body,headers=AUTH)
    assert response.status_code>=500
    assert reopened.app.state.db.one("SELECT 1 FROM events WHERE event_id=?",(eid,)) is None
