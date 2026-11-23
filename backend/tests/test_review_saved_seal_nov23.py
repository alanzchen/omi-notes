"""Review: worker repair must respect a saved seal before indexing an orphan.
(Adopted; adapted 2026-11-23 R3: the worker repair path is gone. The orphan can now only be indexed by the phone's
retry or a startup sweep, so the probe drives the retry; the final assertion is unchanged.)"""
import uuid
from omi_notes.vault import Vault
from .conftest import DEVICE, put_chunk
from .test_disk_full import _free, _envs, GiB
from .test_publication_matrix import fresh, Barrier, rows, _seal

def test_worker_repair_does_not_adopt_above_saved_seal(settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    c = fresh(settings)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(c, cap, 0, bodies[0]).status_code == 201
    vault = c.app.state.vault
    path = vault.chunk_path(DEVICE, cap, 1)
    path.write_bytes(bodies[1])
    Vault.write_json(vault.seal_path(DEVICE, cap), {"body": _seal(cap, 0), "received_at": 1790000000.0}, pretty=False)
    barrier = Barrier(monkeypatch, path)
    restarted = fresh(settings)
    assert rows(restarted, cap, 1) == 0
    assert restarted.app.state.db.one("SELECT last_chunk_sequence FROM captures WHERE capture_id=?", (cap,))["last_chunk_sequence"] is None
    barrier.failing = False
    retry = put_chunk(restarted, cap, 1, bodies[1])  # (adapted) the one remaining path: the phone's own retry
    assert retry.status_code == 409 and retry.json()["error"] == "beyond_seal"
    again = fresh(settings)  # and the next startup sweep applies the same bound
    assert rows(again, cap, 1) == 0
    assert rows(restarted, cap, 1) == 0, "a saved last=0 seal must exclude orphan seq=1 even when startup confirmation failed"
