# Astra's IT4 probes (omi-notes-reviews/nightly-2026-11-22-it4/python), adopted. One adaptation in the tombstone probe:
# prepared evidence is now stored split by sequence, so it is prepared through rebuild.partition_evidence (as the sweep
# does) instead of injecting the raw capture dict; the counters are reset after preparation and the assertion is unchanged.
import json
import uuid
import pytest
from omi_notes import ingest, rebuild
from omi_notes.envelope import parse_envelope
from omi_notes.pipeline.worker import Worker
from omi_notes.util import sha256_hex
from omi_notes.vault import Vault
from .conftest import AUTH, DEVICE, put_chunk
from .test_disk_full import GiB, _envs, _free
from .test_ingest_delta_independent import fail_index_once

class CountingDict(dict):
    visited=0
    def items(self):
        for k,v in super().items():
            self.visited += 1
            yield k,v

class CountingList(list):
    visited=0
    def __iter__(self):
        for value in super().__iter__():
            self.visited += 1
            yield value

def test_tombstone_request_does_not_scan_all_prepared_evidence(client, monkeypatch):
    _free(monkeypatch,50*GiB)
    cap=str(uuid.uuid4());body=_envs(cap)[0]
    assert put_chunk(client,cap,0,body).status_code==201
    vault=client.app.state.vault;db=client.app.state.db
    path=vault.chunk_path(DEVICE,cap,0)
    env=parse_envelope(body,capture_id=cap,chunk_sequence=0);digest=sha256_hex(body)
    Vault.write_json(path.with_suffix('.gone'),{'header':env.header.model_dump(mode='json'),'sha256':digest,'size':len(body)})
    path.unlink() # synthetic legacy tombstone only, never a live vault
    with db.tx() as conn:
        conn.execute('DELETE FROM chunks WHERE capture_id=?',(cap,))
        conn.execute('DELETE FROM chunk_ranges WHERE capture_id=?',(cap,))
    deleted=CountingDict({str(i):{'audio_start':0.0,'audio_end':1.0} for i in range(1001)})
    coverage=CountingList([[i,'live',float(i),float(i+1)] for i in range(1001)])
    evidence={'deleted':deleted,'coverage':coverage}
    Vault.write_json(vault.capture_json_path(DEVICE,cap),evidence)
    state=rebuild.recovery_state(vault)
    state.receipts[(DEVICE,cap)]={(0,digest):1234.0}
    state.evidence[(DEVICE,cap)]=rebuild.partition_evidence(evidence)
    deleted.visited=0;coverage.visited=0
    response=put_chunk(client,cap,0,body)
    assert response.status_code==200,response.text
    print('EVIDENCE_VISITED',deleted.visited,coverage.visited)
    assert deleted.visited <= 1 and coverage.visited <= 1, 'one tombstone PUT must not scan every other sequence in prepared capture evidence'

def test_worker_resolved_identity_releases_pending_admission(client, settings, monkeypatch):
    """(adapted 2026-11-23 R3: there is no admission cap or worker repair any more; the identity is resolved by its own
    retry, after which nothing is held and a new upload is taken; the final assertion is unchanged)"""
    _free(monkeypatch,50*GiB)
    cap=str(uuid.uuid4());bodies=_envs(cap)
    fail_index_once(monkeypatch,'index_chunk')
    assert put_chunk(client,cap,0,bodies[0]).status_code==507
    assert put_chunk(client,cap,0,bodies[0]).status_code==200
    assert client.app.state.db.one('SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=0',(cap,))
    assert not client.app.state.ingest._pending
    response=put_chunk(client,cap,1,bodies[1])
    print('AFTER_REPAIR_NEW_UPLOAD',response.status_code,response.json())
    assert response.status_code==201, 'resolved artifacts must not hold pending capacity forever'


def test_recovered_leading_tombstone_does_not_strand_next_raw_chunk(settings, monkeypatch):
    from .test_publication_matrix import fresh, Barrier
    _free(monkeypatch,50*GiB)
    initial=fresh(settings);vault=initial.app.state.vault
    cap=str(uuid.uuid4());bodies=_envs(cap);body=bodies[0]
    env=parse_envelope(body,capture_id=cap,chunk_sequence=0);digest=sha256_hex(body)
    tomb=vault.tombstone_path(DEVICE,cap,0)
    Vault.write_json(tomb,{'header':env.header.model_dump(mode='json'),'sha256':digest,'size':len(body)})
    Vault.append_jsonl(vault.receipts_path(DEVICE,cap),{'seq':0,'sha256':digest,'received_at':1234.0})
    Vault.write_json(vault.capture_json_path(DEVICE,cap),{'deleted':{'0':{'audio_start':0.0,'audio_end':2.0}}})
    barrier=Barrier(monkeypatch,tomb)
    client=fresh(settings) # unconfirmable at startup, prepared for its own retry
    barrier.failing=False
    assert put_chunk(client,cap,0,body).status_code==200
    assert put_chunk(client,cap,1,bodies[1]).status_code==201
    before=client.app.state.db.one('SELECT processed_through FROM captures WHERE capture_id=?',(cap,))['processed_through']
    worker=Worker(settings,client.app.state.db)
    done=worker.process_chunks(2000000000.0)
    print('TOMBSTONE_THROUGH_AND_PROCESSED',before,done)
    assert done >= 1, 'a restored processed tombstone at seq0 must let seq1 become ready'
