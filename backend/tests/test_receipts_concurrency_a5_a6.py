"""Acceptance A5/A6 (ASTRA-20261122-IT1, DESIGN-03): one stable receipt time per identity across retry, restart and rebuild
(never another bytes' line, never an mtime), and concurrent uploads of one identity end with one canonical row."""

from __future__ import annotations

import threading
import uuid

from omi_notes import rebuild
from omi_notes.vault import Vault

from .conftest import DEVICE, put_chunk
from .test_disk_full import GiB, _envs, _free
from .test_ingest_delta_independent import fail_index_once
from .test_publication_matrix import fresh


def _received(client, cap, seq):
    return client.app.state.db.one("SELECT received_at FROM chunks WHERE capture_id=? AND chunk_sequence=?", (cap, seq))["received_at"]


def _rebuilt_received(settings, cap, seq):
    c = fresh(settings)
    rebuild.rebuild(settings, c.app.state.vault)
    return _received(fresh(settings), cap, seq)


def test_the_receipt_time_survives_a_failed_commit_its_retry_a_restart_and_a_rebuild(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    fail_index_once(monkeypatch, "index_chunk")
    assert put_chunk(client, cap, 0, body).status_code == 507
    line = Vault.read_jsonl(client.app.state.vault.receipts_path(DEVICE, cap))[-1]
    assert put_chunk(client, cap, 0, body).status_code == 200
    assert _received(client, cap, 0) == line["received_at"]
    assert _rebuilt_received(settings, cap, 0) == line["received_at"]


def test_a_receipt_whose_sync_failed_keeps_its_time_on_the_retry(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    receipts = client.app.state.vault.receipts_path(DEVICE, cap)
    from .test_publication_matrix import Barrier

    failing = Barrier(monkeypatch, receipts)  # the line is written, its sync can't be confirmed
    assert put_chunk(client, cap, 0, body).status_code == 507
    failing.failing = False
    assert put_chunk(client, cap, 0, body).status_code == 200
    times = {r["received_at"] for r in Vault.read_jsonl(receipts) if r.get("seq") == 0}
    assert len(times) == 1, "the retry wrote the same time, not a new one"
    assert _received(client, cap, 0) == times.pop()


def test_a_torn_receipt_tail_never_supplies_or_shifts_a_time(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    receipts = client.app.state.vault.receipts_path(DEVICE, cap)
    with receipts.open("ab") as fh:
        fh.write(b'{"seq": 1, "sha256": "')  # a crash mid-append
    assert put_chunk(client, cap, 1, bodies[1]).status_code == 201
    t1 = _received(client, cap, 1)
    assert _rebuilt_received(settings, cap, 1) == t1
    assert _rebuilt_received(settings, cap, 0) == _received(client, cap, 0)


def test_another_bytes_receipt_line_never_supplies_the_time(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    bodies = _envs(cap)
    assert put_chunk(client, cap, 0, bodies[0]).status_code == 201
    vault = client.app.state.vault
    Vault.append_jsonl(vault.receipts_path(DEVICE, cap), {"seq": 1, "sha256": "0" * 64, "received_at": 12345.0})
    vault.chunk_path(DEVICE, cap, 1).write_bytes(bodies[1])  # an orphan of other bytes than that line
    c = fresh(settings)  # the sweep adopts it with a time of its own
    assert _received(c, cap, 1) != 12345.0
    stat = vault.chunk_path(DEVICE, cap, 1).stat()
    assert _received(c, cap, 1) != stat.st_mtime, "never an mtime"
    assert _rebuilt_received(settings, cap, 1) == _received(c, cap, 1)


def test_two_uploads_of_one_identity_at_once_end_with_one_row(client, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    codes = []
    threads = [threading.Thread(target=lambda: codes.append(put_chunk(client, cap, 0, body).status_code)) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    assert sorted(codes) == [200, 200, 200, 201]
    assert client.app.state.db.one("SELECT COUNT(*) AS n FROM chunks WHERE capture_id=?", (cap,))["n"] == 1
    assert client.app.state.vault.chunk_path(DEVICE, cap, 0).read_bytes() == body


def test_different_bytes_at_once_keep_the_first_and_refuse_or_keep_the_other(client, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    a, b = str(uuid.uuid4()), None
    first = _envs(a)[0]
    other = bytearray(first)
    other[-1] ^= 0xFF  # same identity, other bytes (not a re-encoding of the same audio)
    codes = []
    threads = [threading.Thread(target=lambda body=body: codes.append(put_chunk(client, a, 0, bytes(body)).status_code))
               for body in (first, other)]  # fmt: skip
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    assert 201 in codes and (409 in codes or codes.count(201) == 1)
    assert client.app.state.db.one("SELECT COUNT(*) AS n FROM chunks WHERE capture_id=?", (a,))["n"] == 1
    stored = client.app.state.vault.chunk_path(DEVICE, a, 0).read_bytes()
    assert stored in (first, bytes(other)), "one canonical copy, never a mix"
    assert b is None
