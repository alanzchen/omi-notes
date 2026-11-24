"""Astra's IT3-02 tombstone shape edges (2026-11-24), copied unchanged except the import header."""
import hashlib,uuid,json
import pytest
from .conftest import DEVICE,put_chunk
from .test_disk_full import GiB,_envs,_free
from .test_publication_matrix import fresh
from omi_notes.envelope import parse_envelope
from omi_notes.vault import index_dir

@pytest.mark.parametrize("damage",["digest_object","other_capture"])
def test_acknowledged_tombstone_cannot_disappear_or_crash(settings,monkeypatch,damage):
    _free(monkeypatch,50*GiB)
    c=fresh(settings); cap=str(uuid.uuid4()); raw=_envs(cap)[0]
    assert put_chunk(c,cap,0,raw).status_code==201
    v=c.app.state.vault
    header=parse_envelope(raw).header.model_dump(mode="json")
    tomb={"sha256":hashlib.sha256(raw).hexdigest(),"size":len(raw),"header":header,"deleted_at":1}
    if damage=="digest_object":tomb["sha256"]={}
    else:tomb["header"]["capture_id"]=str(uuid.uuid4())
    v.write_json(v.tombstone_path(DEVICE,cap,0),tomb)
    v.chunk_path(DEVICE,cap,0).unlink()
    c.app.state.db.execute("UPDATE chunks SET raw_deleted=1 WHERE capture_id=?",(cap,))
    c.app.state.db.set_meta("schema_version","11");c.app.state.db.close()
    index=index_dir(settings,v)/"index.sqlite3";before=index.read_bytes()
    try:again=fresh(settings)
    except Exception as exc:pytest.fail(f"damage escaped not-ready: {type(exc).__name__}: {exc}")
    result=again.get("/healthz")
    if result.status_code==200:
        row=again.app.state.db.one("SELECT * FROM chunks WHERE capture_id=?",(cap,))
        print("READY_OLD_ROW",row)
    assert result.status_code==503
    assert index.read_bytes()==before
