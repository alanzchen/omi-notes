"""Astra IT5 probe (2026-11-24), adopted unchanged except imports/paths."""
import hashlib, uuid
import pytest
from .conftest import put_chunk
from .test_disk_full import GiB,_envs,_free
from .test_publication_matrix import fresh
from omi_notes.envelope import parse_envelope, build_envelope

@pytest.mark.parametrize("device",["11111111-2222-4333-8444-555555555555", "Watch:example"])
def test_valid_tombstone_accepts_the_api_device_id(settings,monkeypatch,device):
    _free(monkeypatch,50*GiB)
    c=fresh(settings); cap=str(uuid.uuid4()); env=parse_envelope(_envs(cap)[0])
    h=env.header.model_dump(mode="json"); h["device_id"]=device
    raw=build_envelope(h,env.payload)
    assert put_chunk(c,cap,0,raw).status_code==201
    v=c.app.state.vault
    v.write_json(v.tombstone_path(device,cap,0), {"sha256":hashlib.sha256(raw).hexdigest(),"size":len(raw),"header":h,"deleted_at":1})
    v.chunk_path(device,cap,0).unlink()
    c.app.state.db.execute("UPDATE chunks SET raw_deleted=1 WHERE capture_id=?",(cap,))
    c.app.state.db.set_meta("schema_version","11"); c.app.state.db.close()
    again=fresh(settings)
    result=again.get("/healthz")
    assert result.status_code==200,result.text
    row=again.app.state.db.one("SELECT device_id FROM chunks WHERE capture_id=?",(cap,))
    assert row["device_id"]==device
