"""Independent artifact variants; synthetic temporary vault only."""
import hashlib,json,uuid
import pytest
from .conftest import AUTH, DEVICE, put_chunk
from .test_disk_full import GiB, _envs, _free
from .test_publication_matrix import fresh, _seal
from omi_notes.vault import index_dir

@pytest.mark.parametrize("artifact,fault", [("seal","deleted"),("seal","corrupt"),("seal","invalid_body"),("seal","wrong_shape"),("event","deleted"),("event","corrupt")])
def test_every_acked_artifact_stays_in_bounded_not_ready(settings, monkeypatch, artifact, fault):
    _free(monkeypatch,50*GiB)
    c=fresh(settings); cap=str(uuid.uuid4()); raw=_envs(cap)[0]
    assert put_chunk(c,cap,0,raw).status_code==201
    v=c.app.state.vault
    if artifact=='seal':
        assert c.put(f"/v1/captures/{cap}/seal",json=_seal(cap),headers=AUTH).status_code==200
        path=v.seal_path(DEVICE,cap)
    else:
        event=str(uuid.uuid4())
        body={"device_id":DEVICE,"type":"button","at":"2026-09-26T19:33:05.123Z","data":{"code":1}}
        r=c.put(f"/v1/events/{event}",json=body,headers=AUTH)
        assert r.status_code==201, r.text
        path=next(v.events_dir.glob('*.jsonl'))
    c.app.state.db.set_meta('schema_version','11');c.app.state.db.close()
    index=index_dir(settings,v)/'index.sqlite3'; before=index.read_bytes()
    if fault=='deleted':path.unlink()
    elif fault=='corrupt':path.write_bytes(b'{torn')
    elif fault=='wrong_shape':path.write_text('[]')
    else:path.write_text(json.dumps({'body':{},'received_at':1}))
    try:r=fresh(settings).get('/healthz')
    except Exception as exc:pytest.fail(f"{artifact}/{fault} escaped refusal: {type(exc).__name__}: {exc}")
    print('VARIANT',artifact,fault,r.status_code,r.json())
    assert r.status_code==503
    assert index.read_bytes()==before
    assert v.chunk_path(DEVICE,cap,0).read_bytes()==raw


def test_legitimate_tombstone_is_not_falsely_missing(settings,monkeypatch):
    from omi_notes.envelope import parse_envelope
    _free(monkeypatch,50*GiB)
    c=fresh(settings); cap=str(uuid.uuid4()); raw=_envs(cap)[0]
    assert put_chunk(c,cap,0,raw).status_code==201
    v=c.app.state.vault; path=v.chunk_path(DEVICE,cap,0)
    tomb={"sha256":hashlib.sha256(raw).hexdigest(),"size":len(raw),"header":parse_envelope(raw).header.model_dump(mode="json"),"deleted_at":1}
    v.write_json(v.tombstone_path(DEVICE,cap,0),tomb)
    path.unlink()
    c.app.state.db.execute("UPDATE chunks SET raw_deleted=1 WHERE capture_id=?",(cap,))
    c.app.state.db.set_meta('schema_version','11');c.app.state.db.close()
    again=fresh(settings)
    assert again.get('/healthz').status_code==200
    row=again.app.state.db.one("SELECT raw_deleted,sha256 FROM chunks WHERE capture_id=?",(cap,))
    assert row['raw_deleted']==1 and row['sha256']==tomb['sha256']


def test_erroneous_previous_identity_refuses_until_operator_repairs_index(settings,monkeypatch):
    _free(monkeypatch,50*GiB)
    c=fresh(settings); cap=str(uuid.uuid4()); raw=_envs(cap)[0]
    assert put_chunk(c,cap,0,raw).status_code==201
    c.app.state.db.execute("UPDATE chunks SET chunk_sequence=99 WHERE capture_id=?",(cap,))
    c.app.state.db.set_meta('schema_version','11');c.app.state.db.close()
    result=fresh(settings).get('/healthz')
    assert result.status_code==503 and f'{cap}/99' in result.json()['reason']
