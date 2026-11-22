"""Acceptance A4 (ASTRA-20261122-IT1, DESIGN-03/05): request cost with teeth. Unrelated history is scaled independently
(receipt lines, orphan files, tombstone evidence in capture.json, contiguous chunks) and each request kind (new chunk,
duplicate, own-identity adoption, new seal) is instrumented: vault JSON bytes parsed, directory enumerations, SQL
statements that enumerate chunk rows, and fsynced paths. None may grow with the history."""

from __future__ import annotations

import json
import pathlib
import uuid

import pytest

from omi_notes import spool
from omi_notes.devtools import live_envelopes, synth_speech_like
from omi_notes.vault import Vault

from .conftest import AUTH, DEVICE, put_chunk
from .helpers import STARTED
from .test_api import seal_body
from .test_disk_full import GiB, _free
from .test_ingest_delta_independent import fail_index_once


class Meter:
    def __init__(self, monkeypatch, client):
        self.reset()
        real_jsonl, real_json = Vault.read_jsonl, Vault.read_json
        real_iterdir = pathlib.Path.iterdir
        real_file, real_dir = spool.fsync_file, spool.fsync_dir

        def read_jsonl(path):
            lines = real_jsonl(path)
            self.parsed += sum(len(json.dumps(x)) for x in lines)
            return lines

        def read_json(path):
            value = real_json(path)
            self.parsed += len(json.dumps(value)) if value is not None else 0
            return value

        def iterdir(path):
            self.enumerations += 1
            return real_iterdir(path)

        monkeypatch.setattr(Vault, "read_jsonl", staticmethod(read_jsonl))
        monkeypatch.setattr(Vault, "read_json", staticmethod(read_json))
        monkeypatch.setattr(pathlib.Path, "iterdir", iterdir)
        monkeypatch.setattr(spool, "fsync_file", lambda p: (self.synced.append(p), real_file(p))[1])
        monkeypatch.setattr(spool, "fsync_dir", lambda p: (self.synced.append(p), real_dir(p))[1])
        client.app.state.db.conn().set_trace_callback(lambda q: self.sql.append(q))

    def reset(self):
        self.parsed, self.enumerations, self.synced, self.sql = 0, 0, [], []

    def snapshot(self):
        scans = [q for q in self.sql if "FROM chunks WHERE capture_id=?" in q.replace("\n", " ") and "chunk_sequence=" not in q
                 and "MAX(" not in q and "COUNT(" not in q]  # fmt: skip
        return {"parsed": self.parsed, "enumerations": self.enumerations, "synced": len(self.synced), "chunk_scans": len(scans)}


def _scenario(client, settings, n_receipts, n_orphans, n_evidence, n_chunks):
    cap = str(uuid.uuid4())
    bodies = live_envelopes(synth_speech_like((n_chunks + 3) * 2.0), capture_id=cap, device_id=DEVICE, started_at=STARTED,
                            chunk_seconds=2.0)  # fmt: skip
    for seq in range(n_chunks):
        assert put_chunk(client, cap, seq, bodies[seq]).status_code == 201
    vault = client.app.state.vault
    receipts = vault.receipts_path(DEVICE, cap)
    with receipts.open("a") as fh:  # unrelated history: receipt lines for other bytes and old alternates
        for i in range(n_receipts):
            fh.write(json.dumps({"alternate_of_seq": 0, "sha256": f"{i:064x}", "received_at": 1.0 + i}) + "\n")
    folder = vault.capture_dir(DEVICE, cap) / "unrelated"
    folder.mkdir()
    for i in range(n_orphans):
        (folder / f"{i}.bin").write_bytes(b"x")
    evidence = {"deleted": {str(10_000 + i): {"audio_start": 0.0, "audio_end": 1.0} for i in range(n_evidence)}}
    Vault.write_json(vault.capture_json_path(DEVICE, cap), evidence)
    return cap, bodies


def _measure(client, settings, monkeypatch, scale):
    _free(monkeypatch, 50 * GiB)
    cap, bodies = _scenario(client, settings, *scale)
    n = scale[3]
    meter = Meter(monkeypatch, client)
    out = {}
    meter.reset()
    assert put_chunk(client, cap, n, bodies[n]).status_code == 201
    out["new"] = meter.snapshot()
    meter.reset()
    assert put_chunk(client, cap, n, bodies[n]).status_code == 200
    out["duplicate"] = meter.snapshot()
    fail_index_once(monkeypatch, "index_chunk")
    assert put_chunk(client, cap, n + 1, bodies[n + 1]).status_code == 507
    meter.reset()
    assert put_chunk(client, cap, n + 1, bodies[n + 1]).status_code == 200
    out["adoption"] = meter.snapshot()
    meter.reset()
    assert client.put(f"/v1/captures/{cap}/seal", json=seal_body(n + 1), headers=AUTH).status_code == 200
    out["seal"] = meter.snapshot()
    client.app.state.db.conn().set_trace_callback(None)
    return out


@pytest.mark.parametrize("axis", ["receipts", "orphans", "evidence", "chunks"])
def test_no_request_cost_grows_with_unrelated_history(client, settings, monkeypatch, axis):
    small = {"receipts": (1, 0, 0, 2), "orphans": (0, 1, 0, 2), "evidence": (0, 0, 1, 2), "chunks": (0, 0, 0, 2)}[axis]
    large = {"receipts": (1000, 0, 0, 2), "orphans": (0, 1000, 0, 2), "evidence": (0, 0, 1000, 2), "chunks": (0, 0, 0, 48)}[axis]
    a = _measure(client, settings, monkeypatch, small)
    monkeypatch.undo()
    b = _measure(client, settings, monkeypatch, large)
    print("A4", axis, a, b)
    assert a == b, f"request cost changed with {axis}: {a} vs {b}"
