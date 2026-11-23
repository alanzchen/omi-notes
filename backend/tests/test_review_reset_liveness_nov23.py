"""Review: acknowledged history can be lost from the disposable index at mandatory rebuild.
(Astra IT3, adopted 2026-11-23 R4. Adapted: her intermediate assertions described the defect itself (the new index
stamped complete, /healthz 200); they now state the fix's contract instead (refused rebuild, previous index untouched,
/healthz 503, uploads refused retryably, a controlled retry once storage recovers). The process-exit hook is replaced
so the test process isn't signalled. The final assertion is unchanged.)"""
from omi_notes import api
import time
import uuid
from omi_notes.pipeline.worker import Worker
from .conftest import AUTH, DEVICE, put_chunk
from .test_disk_full import _envs, _free, GiB
from .test_publication_matrix import fresh, Barrier

def test_rebuild_of_acked_chunk_recovers_without_needing_retired_phone_copy(settings, monkeypatch):
    _free(monkeypatch,50*GiB)
    first=fresh(settings)
    cap=str(uuid.uuid4()); bodies=_envs(cap)
    assert put_chunk(first,cap,0,bodies[0]).status_code==201
    vault=first.app.state.vault; path=vault.chunk_path(DEVICE,cap,0)
    # 201 allows the phone to retire chunk0. Production schema11 -> schema12 forces this rebuild.
    first.app.state.db.set_meta("schema_version","11")
    first.app.state.db.close()
    barrier=Barrier(monkeypatch,path)
    restarts=[]
    monkeypatch.setattr(api,"_exit_for_restart",lambda: restarts.append(True))
    reopened=fresh(settings)  # (adapted) the rebuild is refused: not ready, previous index untouched
    assert reopened.app.state.startup["ready"] is False
    assert reopened.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=0",(cap,))  # prior index
    assert reopened.app.state.db.meta("schema_version")=="11"
    assert reopened.get("/healthz").status_code==503
    assert put_chunk(reopened,cap,1,bodies[1]).status_code==507  # ENOSPC cause: retryable, the phone keeps chunk 1
    assert not reopened.app.state.retry_now()  # still failing: still not ready
    barrier.failing=False
    assert reopened.app.state.retry_now() and restarts==[True]  # storage recovered: rebuilt, process restarts
    reopened=fresh(settings)  # launchd's KeepAlive start
    db=reopened.app.state.db
    assert reopened.get("/healthz").status_code==200
    assert put_chunk(reopened,cap,1,bodies[1]).status_code==201
    worker=Worker(settings,db)
    for n in range(3): worker.tick(time.time()+100+n*10)
    before=dict(db.one("SELECT processed_through FROM captures WHERE capture_id=?",(cap,)))
    orphan_still_unindexed=db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=0",(cap,)) is None
    assert path.read_bytes()==bodies[0]
    print("AFTER_STORAGE_RECOVERED",before,"old_ack_row_missing",orphan_still_unindexed,"next_seq_status",db.one("SELECT status FROM chunks WHERE capture_id=? AND chunk_sequence=1",(cap,))["status"])
    again=fresh(settings)
    assert again.app.state.db.one("SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=0",(cap,))
    print("NEXT_RESTART_RESTORES_OLD_ACK",True)
    assert not orphan_still_unindexed, "a previously ACKed chunk has no mandatory phone retry; storage recovery must not leave its capture silently stalled until an unbounded future restart"
