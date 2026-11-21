"""A full (or nearly full) server disk must never cost audio (nightly 2026-11-21: the worker hit "database or disk
is full" on 2026-11-20 18:05 CST while the phone happened to be offline; next time it could hit an upload).

- Below the free-space floor the server refuses new chunks with 507 before writing anything, so SQLite keeps room for
  status, notes and the worker (the phone treats any 5xx as retryable and keeps the part).
- A full disk after the chunk file was written (receipt line, index commit) is also 507, not a 500; the durable file
  is an orphan that a retry with the same bytes adopts once, and different bytes still get 409.
- `logs/alerts/disk.json` says when the disk is down and when it recovered, for the brief / an external notifier.
"""

from __future__ import annotations

import errno
import json
import sqlite3
import uuid
from collections import namedtuple

import pytest

from omi_notes import ingest
from omi_notes.db import Database
from omi_notes.devtools import live_envelopes, synth_speech_like
from omi_notes.vault import Vault

from .conftest import DEVICE, put_chunk
from .helpers import STARTED

GiB = 1024**3
Usage = namedtuple("Usage", "total used free")


def _envs(capture: str, n: int = 2) -> list[bytes]:
    envs = live_envelopes(synth_speech_like(5.0), capture_id=capture, device_id=DEVICE, started_at=STARTED, chunk_seconds=2.0)
    assert len(envs) >= n
    return envs


def _free(monkeypatch, free: int) -> None:
    monkeypatch.setattr(ingest.shutil, "disk_usage", lambda _p: Usage(500 * GiB, 500 * GiB - free, free))


def _rows(settings, capture: str) -> int:
    return Database(settings.db_path).one("SELECT COUNT(*) AS n FROM chunks WHERE capture_id=?", (capture,))["n"]


def _chunk_files(settings) -> list:
    return [p for p in settings.vault_dir.rglob("*") if p.is_file() and "/raw/" in str(p) and p.suffix not in {".jsonl", ".json"}]


def test_below_the_floor_a_chunk_is_refused_with_507_and_nothing_is_written(client, settings, monkeypatch):
    capture = str(uuid.uuid4())
    env = _envs(capture)[0]
    _free(monkeypatch, 1 * GiB)  # above the old 256 MiB floor, below the new one
    r = put_chunk(client, capture, 0, env)
    assert r.status_code == 507, r.text
    assert r.json()["error"] == "storage_full"
    assert _rows(settings, capture) == 0
    assert not _chunk_files(settings)
    # with room again the same bytes are stored once
    _free(monkeypatch, 50 * GiB)
    assert put_chunk(client, capture, 0, env).status_code == 201
    assert _rows(settings, capture) == 1


def test_disk_full_at_the_index_commit_is_507_and_a_retry_stores_it_once(client, settings, monkeypatch):
    capture = str(uuid.uuid4())
    env, other = _envs(capture)[:2]
    _free(monkeypatch, 50 * GiB)
    real = ingest.index_chunk
    calls = {"n": 0}

    def full_once(*a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            full = sqlite3.OperationalError("database or disk is full")
            full.sqlite_errorcode = sqlite3.SQLITE_FULL  # as SQLite raises it (classified by code, not message)
            raise full
        return real(*a, **k)

    monkeypatch.setattr(ingest, "index_chunk", full_once)
    r = put_chunk(client, capture, 0, env)
    assert r.status_code == 507, r.text
    assert _rows(settings, capture) == 0
    r = put_chunk(client, capture, 0, env)  # the durable orphan file is adopted, not written again
    assert r.status_code in (200, 201), r.text
    assert _rows(settings, capture) == 1
    # other bytes under that identity are still a conflict, never "already stored"
    assert put_chunk(client, capture, 0, other).status_code == 409


def test_disk_full_at_the_receipt_line_is_507_and_a_retry_stores_it_once(client, settings, monkeypatch):
    capture = str(uuid.uuid4())
    env = _envs(capture)[0]
    _free(monkeypatch, 50 * GiB)
    real = Vault.append_jsonl
    calls = {"n": 0}

    def full_once(path, value):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError(errno.ENOSPC, "No space left on device")
        return real(path, value)

    monkeypatch.setattr(Vault, "append_jsonl", staticmethod(full_once))
    r = put_chunk(client, capture, 0, env)
    assert r.status_code == 507, r.text
    assert put_chunk(client, capture, 0, env).status_code in (200, 201)
    assert _rows(settings, capture) == 1


def test_the_disk_alert_is_written_on_a_refusal_and_resolved_when_space_returns(client, settings, worker, monkeypatch):
    alert = settings.logs_dir / "alerts" / "disk.json"
    capture = str(uuid.uuid4())
    _free(monkeypatch, 1 * GiB)
    assert put_chunk(client, capture, 0, _envs(capture)[0]).status_code == 507
    down = json.loads(alert.read_text())
    assert down["state"] == "down" and down["down_since"] and down["floor_bytes"] == ingest.MIN_FREE_BYTES
    assert down["free_bytes"] == 1 * GiB
    # the worker keeps watching the free space: still low, still down (same since)
    worker.tick()
    assert json.loads(alert.read_text())["down_since"] == down["down_since"]
    _free(monkeypatch, 50 * GiB)
    worker.tick()
    up = json.loads(alert.read_text())
    assert up["state"] == "recovered" and up["down_since"] == down["down_since"] and up["recovered_at"]


def test_no_alert_file_while_the_disk_has_room(client, settings, worker, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    worker.tick()
    assert not (settings.logs_dir / "alerts" / "disk.json").exists()


def test_status_says_the_disk_is_full_only_while_it_is(client, settings, monkeypatch):
    from .conftest import AUTH
    assert client.get("/v1/status", headers=AUTH).json().get("disk") is None
    capture = str(uuid.uuid4())
    _free(monkeypatch, 1 * GiB)
    assert put_chunk(client, capture, 0, _envs(capture)[0]).status_code == 507
    disk = client.get("/v1/status", headers=AUTH).json()["disk"]
    assert disk["full"] is True and disk["since"]
