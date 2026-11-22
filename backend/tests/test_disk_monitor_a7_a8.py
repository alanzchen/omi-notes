"""Acceptance A7/A8 (ASTRA-20261122-IT1, DESIGN-06/07/08): the disk alert's transitions are serialized across processes,
only a real publication + outer COMMIT can witness recovery, and unknown stays unknown (never a healthy status, never a
500, never a changed upload answer). The thread race is test_disk_alert_round5_edges.py."""

from __future__ import annotations

import errno
import json
import subprocess
import sys
import time
import uuid

from fastapi.testclient import TestClient

from omi_notes import disk_alert, ingest
from omi_notes.api import create_app

from .conftest import AUTH, put_chunk
from .test_disk_full import GiB, Usage, _envs, _free


def _down(settings, now=100.0, kind="write"):
    return disk_alert.note_down(settings.logs_dir, free_bytes=None, floor_bytes=ingest.MIN_FREE_BYTES, reason="t", now=now, kind=kind)


def test_another_process_waits_for_the_alert_lock_and_its_failure_wins(client, settings):
    _down(settings)
    began = disk_alert.revision(settings.logs_dir)
    code = (f"from pathlib import Path; from omi_notes import disk_alert; "
            f"print(disk_alert.note_down(Path({str(settings.logs_dir)!r}), free_bytes=None, floor_bytes=1, reason='other process', now=200.0))")  # fmt: skip
    with disk_alert._locked(settings.logs_dir):
        proc = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True)
        time.sleep(0.5)
        assert proc.poll() is None, "the other process waits for the lock"
        assert disk_alert.revision(settings.logs_dir) == began
    out, _ = proc.communicate(timeout=10)
    assert int(out.strip()) == began + 1
    assert disk_alert.witness(settings.logs_dir, [settings.vault_dir], floor_bytes=ingest.MIN_FREE_BYTES, now=300,
                              since_revision=began) is False  # fmt: skip
    assert disk_alert.read(settings.logs_dir)["state"] == "down"


def test_a_duplicate_200_is_not_a_witness(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    cap = str(uuid.uuid4())
    body = _envs(cap)[0]
    assert put_chunk(client, cap, 0, body).status_code == 201
    _down(settings)
    assert put_chunk(client, cap, 0, body).status_code == 200  # the indexed duplicate: no publication
    assert disk_alert.read(settings.logs_dir)["state"] == "down"


def test_a_rolled_back_commit_is_not_a_witness(client, settings, monkeypatch):
    import sqlite3

    from .test_ingest_delta_independent import fail_index_once

    _free(monkeypatch, 50 * GiB)
    _down(settings)
    fail_index_once(monkeypatch, "index_chunk")
    cap = str(uuid.uuid4())
    assert put_chunk(client, cap, 0, _envs(cap)[0]).status_code == 507
    assert disk_alert.read(settings.logs_dir)["state"] == "down"
    assert isinstance(sqlite3, object)


def test_a_failure_during_a_publication_keeps_it_down(client, settings, monkeypatch):
    """The publication began before a newer failure (another request's ENOSPC) and commits after it: not a witness."""
    _free(monkeypatch, 50 * GiB)
    _down(settings)
    real = ingest.index_chunk

    def failure_meanwhile(*a, **kw):
        _down(settings, now=150.0)
        return real(*a, **kw)

    monkeypatch.setattr(ingest, "index_chunk", failure_meanwhile)
    cap = str(uuid.uuid4())
    assert put_chunk(client, cap, 0, _envs(cap)[0]).status_code == 201
    assert disk_alert.read(settings.logs_dir)["state"] == "down"


def test_the_split_index_volume_and_an_unwritable_alert_still_say_full(client, settings, monkeypatch):
    """IT7-03: the index's volume is full while the vault's has room, and the alert file itself can't be written: status
    still says full (the API's latch), never null-then-healthy, and the next upload is still 507."""
    from omi_notes.vault import Vault

    def free(path):
        return Usage(100 * GiB, 99 * GiB, GiB) if str(path).startswith(str(settings.db_path.parent)) else Usage(100 * GiB, 50 * GiB, 50 * GiB)

    monkeypatch.setattr(ingest.shutil, "disk_usage", free)
    monkeypatch.setattr(disk_alert.shutil, "disk_usage", free)
    real = Vault.write_json

    def no_alert(path, value, **kw):
        if path == settings.logs_dir / "alerts" / "disk.json":
            raise OSError(errno.ENOSPC, "synthetic")
        return real(path, value, **kw)

    monkeypatch.setattr(Vault, "write_json", staticmethod(no_alert))
    import sqlite3

    def full(*a, **kw):
        exc = sqlite3.OperationalError("database or disk is full")
        exc.sqlite_errorcode = sqlite3.SQLITE_FULL
        raise exc

    monkeypatch.setattr(ingest, "index_chunk", full)
    cap = str(uuid.uuid4())
    assert put_chunk(client, cap, 0, _envs(cap)[0]).status_code == 507
    disk = client.get("/v1/status", headers=AUTH).json()["disk"]
    assert disk is not None and disk["full"] is True


def test_monitoring_eacces_is_unknown_not_a_500(client, settings, monkeypatch):
    """IT7-04: the alert directory can't be read: /v1/status still answers 200, with disk null."""
    path = settings.logs_dir / "alerts" / "disk.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"state": "down", "down_since": "2026-11-20T18:05:00Z"}))
    path.parent.chmod(0)
    try:
        r = client.get("/v1/status", headers=AUTH)
        assert r.status_code == 200
        assert r.json()["disk"] is None
    finally:
        path.parent.chmod(0o755)


def test_either_volume_unmeasurable_is_no_healthy_evidence(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)

    def half(path):
        if path == settings.db_path.parent:
            raise OSError(errno.EACCES, "synthetic")
        return Usage(100 * GiB, 50 * GiB, 50 * GiB)

    monkeypatch.setattr(disk_alert.shutil, "disk_usage", half)
    cap = str(uuid.uuid4())
    assert put_chunk(client, cap, 0, _envs(cap)[0]).status_code == 201
    assert client.get("/v1/status", headers=AUTH).json()["disk"] is None


def test_a_recovered_record_from_an_earlier_run_is_history(client, settings, monkeypatch):
    path = settings.logs_dir / "alerts" / "disk.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"state": "recovered", "down_since": "2026-11-20T18:05:00Z", "recovered_at": "2026-11-20T19:00:00Z"}))
    c = TestClient(create_app(settings, start_worker=False))
    assert c.get("/v1/status", headers=AUTH).json()["disk"] is None


def test_a_locked_monitor_never_changes_the_upload_answer(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    _down(settings)
    monkeypatch.setattr(disk_alert, "LOCK_WAIT_SECONDS", 0.05)
    with disk_alert._locked(settings.logs_dir):
        import threading

        result = {}
        cap = str(uuid.uuid4())
        t = threading.Thread(target=lambda: result.setdefault("code", put_chunk(client, cap, 0, _envs(cap)[0]).status_code))
        t.start()
        t.join(10)
    assert result["code"] == 201
    assert disk_alert.read(settings.logs_dir)["state"] == "down", "an unavailable monitor is no recovery"
