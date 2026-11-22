"""Acceptance A4, response part (ASTRA-20261122-IT1, DESIGN-05): a seal's `received_ranges` comes from runs kept as chunks
are indexed. The answer is the same as before; building it reads the capture's ranges, never its chunk rows."""

from __future__ import annotations

import random
import uuid

from omi_notes.ingest import capture_status

from .conftest import AUTH, DEVICE, put_chunk
from .test_api import seal_body
from .test_disk_full import GiB, _free
from omi_notes.devtools import live_envelopes, synth_speech_like
from .helpers import STARTED


def _ranges(seqs):
    out = []
    for s in sorted(seqs):
        if out and s == out[-1][1] + 1:
            out[-1][1] = s
        else:
            out.append([s, s])
    return out


def test_ranges_match_any_arrival_order(client, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = live_envelopes(synth_speech_like(24), capture_id=cap, device_id=DEVICE, started_at=STARTED, chunk_seconds=2.0)
    order = [s for s in range(len(bodies)) if s not in (3, 7, 8)]
    random.Random(7).shuffle(order)
    for i, seq in enumerate(order):
        assert put_chunk(client, cap, seq, bodies[seq]).status_code == 201
        assert capture_status(client.app.state.db, cap)["received_ranges"] == _ranges(order[: i + 1])


def test_the_seal_answer_reads_ranges_not_chunk_rows(client, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = live_envelopes(synth_speech_like(40), capture_id=cap, device_id=DEVICE, started_at=STARTED, chunk_seconds=2.0)
    for seq in range(len(bodies)):
        assert put_chunk(client, cap, seq, bodies[seq]).status_code == 201
    statements = []
    client.app.state.db.conn().set_trace_callback(statements.append)
    try:
        r = client.put(f"/v1/captures/{cap}/seal", json=seal_body(len(bodies) - 1), headers=AUTH)
    finally:
        client.app.state.db.conn().set_trace_callback(None)
    assert r.status_code == 200 and r.json()["received_ranges"] == [[0, len(bodies) - 1]]
    enumerating = [q for q in statements if "chunk_sequence FROM chunks" in q and "MAX(" not in q]
    assert not enumerating, enumerating
