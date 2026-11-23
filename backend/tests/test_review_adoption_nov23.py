# Astra's IT1 (2026-11-23) probes, adopted. The 2026-11-23 R3 design reset removed the worker repair queue and the admission
# cap; adaptations (each marked): the pre-file probe asserts no pending entry instead of a free admission slot (no cap
# exists); the already-stored worker-resolution probe is removed (that code path is gone, IT1-05 moot); the worker
# SQLITE_FULL probe now asserts the same outcome through the one remaining path, the phone's own retry (IT1-01 B moot).
import uuid
from omi_notes import ingest, rebuild
from omi_notes.envelope import parse_envelope
from omi_notes.util import sha256_hex
from omi_notes.vault import Vault
from .conftest import DEVICE, put_chunk
from .test_disk_full import GiB, _envs, _free
from .test_publication_matrix import Barrier


def test_pre_file_sync_failure_releases_admission(client, monkeypatch):
    _free(monkeypatch,50*GiB)
    vault=client.app.state.vault
    cap=str(uuid.uuid4()); body=_envs(cap)[0]
    path=vault.chunk_path(DEVICE,cap,0)
    path.parent.mkdir(parents=True,exist_ok=True)
    barrier=Barrier(monkeypatch,path.parent.parent)
    response=put_chunk(client,cap,0,body)
    assert response.status_code==507,response.text
    assert not path.exists(), "probe must fail before final file exists"
    barrier.failing=False
    owner=client.app.state.ingest
    assert not any(k[0]==cap for k in owner._pending), "(adapted) nothing written: nothing pending for it"
    next_cap=str(uuid.uuid4()); next_body=_envs(next_cap)[0]
    response=put_chunk(client,next_cap,0,next_body)
    print("BEFORE_FINAL_FAILURE_ADMISSION",response.status_code,response.json(),"pending",len(owner._pending))
    assert response.status_code==201, "failure before file publication must not retain an unrecoverable admission slot"
    assert put_chunk(client,cap,0,body).status_code==201  # (added) the failed identity's own retry stores it


def test_tombstone_adoption_does_not_walk_following_history(client, monkeypatch):
    _free(monkeypatch,50*GiB)
    cap=str(uuid.uuid4());body=_envs(cap)[0]
    assert put_chunk(client,cap,0,body).status_code==201
    vault=client.app.state.vault;db=client.app.state.db
    path=vault.chunk_path(DEVICE,cap,0)
    env=parse_envelope(body,capture_id=cap,chunk_sequence=0);digest=sha256_hex(body)
    Vault.write_json(path.with_suffix('.gone'),{'header':env.header.model_dump(mode='json'),'sha256':digest,'size':len(body)})
    path.unlink()
    with db.tx() as conn:
        conn.execute('DELETE FROM chunks WHERE capture_id=?',(cap,))
        conn.execute('DELETE FROM chunk_ranges WHERE capture_id=?',(cap,))
        for i in range(1,1001):
            ingest.index_chunk(conn,env.header.model_copy(update={"chunk_sequence":i}),digest=digest,size=len(body),path='synthetic.gone',received_at=1234.0,raw_deleted=True)
    evidence={'deleted':{'0':{'audio_start':0.,'audio_end':1.}}}
    Vault.write_json(vault.capture_json_path(DEVICE,cap),evidence)
    state=rebuild.recovery_state(vault)
    state.receipts[(DEVICE,cap)]={(0,digest):1234.0}
    state.evidence[(DEVICE,cap)]=rebuild.partition_evidence(evidence)
    sql=[]
    db.conn().set_trace_callback(sql.append)
    try:
        status,_=client.app.state.ingest.put_chunk(cap,0,body,digest)
    finally:
        db.conn().set_trace_callback(None)
    queries=[q for q in sql if "status='processed'" in q and 'SELECT 1 FROM chunks' in q]
    through=db.one('SELECT processed_through FROM captures WHERE capture_id=?',(cap,))['processed_through']
    print("TOMBSTONE_FRONTIER_COST",status,through,"point_queries",len(queries))
    assert status==200 and through==1000
    assert len(queries)<=2, "one request must not scan following processed history under the ingest lock"


def test_worker_sqlite_full_keeps_repair_scheduled(client, settings, monkeypatch):
    """(adapted: no worker repair exists; the identity is stored by the phone's own retry once space returns)"""
    from .test_ingest_delta_independent import fail_index_once
    _free(monkeypatch,50*GiB)
    cap=str(uuid.uuid4());body=_envs(cap)[0]
    fail_index_once(monkeypatch,'index_chunk')
    assert put_chunk(client,cap,0,body).status_code==507
    fail_index_once(monkeypatch,'index_chunk')
    assert put_chunk(client,cap,0,body).status_code==507  # a second SQLITE_FULL on the retry
    assert put_chunk(client,cap,0,body).status_code==200  # space returned: the next retry stores it
    row=client.app.state.db.one('SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=0',(cap,))
    assert row, 'after a second SQLITE_FULL, the identity is stored by its own retry once space returns (no worker repair)'
    assert not any(k[0]==cap for k in client.app.state.ingest._pending)
