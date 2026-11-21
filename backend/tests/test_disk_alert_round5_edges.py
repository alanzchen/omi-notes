"""Astra's IT5 monitoring checks (omi-notes-reviews/nightly-2026-11-21-it5/python/test_disk_alert_round5_edges.py), adopted.
The concurrent-recovery check (IT5-03 a) is marked xfail: it needs a versioned compare-and-write, left for
DURABILITY-DESIGN.md."""
from __future__ import annotations

import errno
import threading
import time
import uuid

import pytest

from omi_notes import disk_alert, ingest
from omi_notes.vault import Vault

from .conftest import AUTH, put_chunk
from .test_disk_full import GiB, _envs, _free


@pytest.mark.xfail(strict=True, reason="IT5-03 (a): needs a versioned compare-and-write; see DURABILITY-DESIGN.md")
def test_newer_failure_between_recovery_read_and_write_is_not_lost(client, settings, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    disk_alert.note_down(settings.logs_dir, free_bytes=None, floor_bytes=ingest.MIN_FREE_BYTES,
                         reason="first write failed", now=100, kind="write")
    real_write = disk_alert._write
    injected = []

    def another_put_fails_before_publication(path, value):
        if value.get("state") == "recovered" and not injected:
            injected.append(True)
            disk_alert.note_down(settings.logs_dir, free_bytes=None, floor_bytes=ingest.MIN_FREE_BYTES,
                                 reason="concurrent newer write failed", now=120, kind="write")
        return real_write(path, value)

    monkeypatch.setattr(disk_alert, "_write", another_put_fails_before_publication)
    disk_alert.watch(settings.logs_dir, settings.vault_dir, other_dirs=[settings.db_path.parent],
                     floor_bytes=ingest.MIN_FREE_BYTES, now=121, last_index_write=110)
    result = disk_alert.read(settings.logs_dir)
    print("CONCURRENT_ALERT", result)
    assert injected
    assert result["state"] == "down", "recovery based on failure@100 cannot overwrite new failure@120"


def test_successful_read_only_tick_is_not_index_write_evidence(client, settings, worker, monkeypatch):
    _free(monkeypatch, 50 * GiB)
    worker.db.set_meta("read_only", "synthetic read-only vault")
    worker.pipeline._status_written = (time.time(), "already rendered")
    monkeypatch.setattr(worker, "_watch_local_stt", lambda stop: None)
    real_tick = worker.tick
    stop = threading.Event()
    observed = []

    def one_real_tick():
        failure = time.time()
        disk_alert.note_down(settings.logs_dir, free_bytes=None, floor_bytes=ingest.MIN_FREE_BYTES,
                             reason="index write failure after worker startup", now=failure, kind="write")
        before = worker.db.conn().total_changes
        result = real_tick()
        observed.append((failure, worker.db.conn().total_changes - before, result))
        stop.set()
        return result

    monkeypatch.setattr(worker, "tick", one_real_tick)
    worker.run_forever(stop)
    assert len(observed) == 1
    failure, changes, result = observed[0]
    assert changes == 0 and result.get("read_only"), observed
    # adapted from Astra's characterization (which asserted the defect, a witness newer than the failure): a tick that
    # wrote nothing leaves no witness
    assert worker._last_ok_tick is None or worker._last_ok_tick <= failure
    disk_alert.watch(settings.logs_dir, settings.vault_dir, other_dirs=[settings.db_path.parent],
                     floor_bytes=ingest.MIN_FREE_BYTES, now=time.time(), last_index_write=worker._last_ok_tick)
    alert = disk_alert.read(settings.logs_dir)
    print("READ_ONLY_TICK_EVIDENCE", changes, result, worker._last_ok_tick, alert)
    assert alert["state"] == "down", "a tick with no DB write cannot prove recovery of writes"


def test_failed_alert_write_is_unknown_not_explicit_disk_recovery(client, settings, monkeypatch):
    _free(monkeypatch, GiB)
    real = Vault.write_json

    def alert_cannot_write(path, value):
        if path == settings.logs_dir / "alerts" / "disk.json":
            raise OSError(errno.ENOSPC, "synthetic monitoring storage full")
        return real(path, value)

    monkeypatch.setattr(Vault, "write_json", staticmethod(alert_cannot_write))
    cap = str(uuid.uuid4())
    response = put_chunk(client, cap, 0, _envs(cap)[0])
    assert response.status_code == 507
    assert disk_alert.read(settings.logs_dir) is None
    status = client.get("/v1/status", headers=AUTH)
    assert status.status_code == 200
    print("FAILED_ALERT_WRITE_STATUS", status.json().get("disk"))
    assert status.json().get("disk") != {"full": False}, "unknown monitor state must not clear a real recent 507"
