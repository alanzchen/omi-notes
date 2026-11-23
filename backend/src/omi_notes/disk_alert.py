"""`logs/alerts/disk.json`: the server's disk is below the upload floor (or a write hit ENOSPC / SQLITE_FULL), and when it
recovered.

Same conventions as `alerts/local-transcription.json` (`state`, `down_since`, `alerted_at`/`recovered_at`, `check`),
for the brief / an external notifier. The state lives in the file itself, never in SQLite: a full disk may be exactly
what stops the index from writing. Nothing is ever deleted to make room (raw audio is kept permanently).

Evidence protocol (ASTRA-20261122-IT1 DESIGN-06/07/08):
- Every failure (`note_down`) raises an opaque `revision`. Each read-modify-write of the file holds one lock shared by
  threads and by the API and worker processes (`disk.lock`, bounded wait); measurements and publication happen outside it.
- The worker reports low space only (`watch`, down-only). Recovery belongs to the API: `witness` after a real durable
  publication and its outer COMMIT, begun under an unchanged revision, with every watched volume (the vault's raw storage
  and the index) measured with the floor plus `HYSTERESIS` free. A newer failure always wins, whatever the clocks say.
  A duplicate 200, a read-only or idle tick, a rollback: none is a witness.
- Monitoring never fails the caller: an unwritable, malformed or locked alert file is logged and means unknown."""

from __future__ import annotations

import errno
import fcntl
import itertools
import json
import logging
import os
import shutil
import threading
import time
import uuid
from collections.abc import Iterable
from contextlib import contextmanager
from pathlib import Path

from .util import iso_utc_epoch
from .vault import Vault

log = logging.getLogger(__name__)

CHECK = "df -h ~/OmiNotes; the phone keeps its audio and retries (507) until there is room"
HYSTERESIS = 256 * 1024 * 1024
LOCK_WAIT_SECONDS = 2.0
_thread_lock = threading.Lock()
# Order of observations in this process (no clock involved): a volume found unmeasurable after the last healthy
# observation outranks it, so status can't keep saying "not full" from older evidence (ASTRA-20261123-IT1-06).
_observations = itertools.count(1)
last_unknown = 0


def observed() -> int:
    """The next observation number (a healthy one is recorded with it)."""
    return next(_observations)


def note_unknown() -> None:
    global last_unknown
    last_unknown = next(_observations)


last_low = 0


def note_low() -> None:
    """A measured volume below the floor, kept in this process even when disk.json can't be written (IT3-03)."""
    global last_low
    last_low = next(_observations)


class MonitorUnavailable(Exception):
    """The alert lock couldn't be taken in time: nothing was read or written."""


def _path(logs_dir: Path) -> Path:
    return logs_dir / "alerts" / "disk.json"


@contextmanager
def _locked(logs_dir: Path, wait: float | None = None):
    """One writer of the alert at a time, across threads and processes. Never held during measurement or I/O of audio."""
    wait = LOCK_WAIT_SECONDS if wait is None else wait
    if not _thread_lock.acquire(timeout=wait):
        raise MonitorUnavailable("disk alert lock (thread) not available")
    fd = None
    try:
        directory = _path(logs_dir).parent
        directory.mkdir(parents=True, exist_ok=True)
        fd = os.open(directory / "disk.lock", os.O_RDWR | os.O_CREAT, 0o644)
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as exc:
                if exc.errno not in (errno.EWOULDBLOCK, errno.EAGAIN) or time.monotonic() >= deadline:
                    raise MonitorUnavailable(f"disk alert lock not available: {exc}") from exc
                time.sleep(0.01)
        yield
    finally:
        if fd is not None:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)
        _thread_lock.release()


def read(logs_dir: Path) -> dict | None:
    """The alert as written, or None when absent, unreadable or not an alert-shaped object (unknown). Never raises."""
    try:
        value = json.loads(_path(logs_dir).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(value, dict) or value.get("state") not in ("down", "recovered"):
        return None
    return value


UNREADABLE = "unreadable"  # a snapshot of a record that exists but can't be read: matches no failure ever


def revision(logs_dir: Path) -> str:
    """The current failure token, sampled before a publication: "" when there is no alert file, UNREADABLE when one
    exists but can't be read, else the token of the latest failure (a fresh random one per failure, never reused,
    so a corrupt record can't make a newer failure look like an older one; ASTRA-20261122-IT4-08)."""
    path = _path(logs_dir)
    current = read(logs_dir)
    if current is None:
        try:
            return UNREADABLE if path.exists() else ""
        except OSError:
            return UNREADABLE
    rev = current.get("revision")
    if isinstance(rev, str) and rev:
        return rev
    # a readable record from an earlier release (no token, or an integer revision): a stable token from its own facts;
    # the next failure writes a fresh random one
    return f"legacy:{rev}:{current.get('last_failure_epoch')}:{current.get('down_since')}:{current.get('state')}"


def _write(path: Path, value: dict) -> bool:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        Vault.write_json(path, value)
        return True
    except OSError as exc:  # the disk may be too full even for this small file: the log line still says it
        log.error("couldn't write %s: %s", path, exc)
        return False


def note_down(logs_dir: Path, *, free_bytes: int | None, floor_bytes: int, reason: str, now: float, kind: str = "write") -> str | None:
    """The disk is too full to take audio: say so (the first `down_since` stays until it recovers) and raise the
    revision. A write failure during a space alert upgrades it to `write`. Returns the new revision (None: not
    recorded; the caller's own latch still knows)."""
    try:
        path = _path(logs_dir)
        with _locked(logs_dir):
            current = read(logs_dir)
            rev = uuid.uuid4().hex
            if current and current.get("state") == "down":
                upgraded = "write" if kind == "write" or current.get("kind") == "write" else current.get("kind", kind)
                ok = _write(path, {**current, "kind": upgraded, "reason": reason, "last_failure_epoch": now, "revision": rev})
                return rev if ok else None
            log.error("server disk too full to take audio (%s; free %s, floor %d)", reason, free_bytes, floor_bytes)
            ok = _write(path, {"state": "down", "kind": kind, "down_since": iso_utc_epoch(now), "down_since_epoch": now,
                               "alerted_at": iso_utc_epoch(now), "last_failure_epoch": now, "reason": reason,
                               "free_bytes": free_bytes, "floor_bytes": floor_bytes, "check": CHECK, "revision": rev})  # fmt: skip
            return rev if ok else None
    except Exception:
        log.exception("disk alert: couldn't note down")
        return None


def measure(dirs: Iterable[Path]) -> int | None:
    """The smallest free space over every required volume; None when any one can't be measured (no evidence)."""
    frees = []
    for d in dirs:
        try:
            frees.append(shutil.disk_usage(d).free)
        except OSError:
            return None
    return min(frees) if frees else None


def watch(logs_dir: Path, data_dir: Path, *, floor_bytes: int, now: float, other_dirs: Iterable[Path] = ()) -> None:
    """From the worker, down only: a measured volume below the floor is noted. It never clears an alert."""
    try:
        frees = []
        for d in [data_dir, *other_dirs]:
            try:
                frees.append(shutil.disk_usage(d).free)
            except OSError:
                note_unknown()  # never recovery evidence, and it outranks an older healthy observation
                continue
        if frees and min(frees) < floor_bytes:
            note_low()
            note_down(logs_dir, free_bytes=min(frees), floor_bytes=floor_bytes, reason="free space below the upload floor",
                      now=now, kind="space")  # fmt: skip
    except Exception:
        log.exception("disk alert: watch failed")


def witness(logs_dir: Path, dirs: Iterable[Path], *, floor_bytes: int, now: float, since_revision: str) -> bool | None:
    """From the API, after a durable publication and its outer COMMIT that began at `since_revision`: True when every
    required volume has room (and a down alert of that same revision is now recovered); False when a volume is low or
    unmeasured, or a newer failure was noted meanwhile; None when the monitor couldn't be read or written."""
    free = measure(dirs)  # outside the lock
    if free is None or free < floor_bytes + HYSTERESIS:
        return False
    try:
        with _locked(logs_dir):
            current = read(logs_dir)
            if since_revision == UNREADABLE or (current is None and revision(logs_dir) == UNREADABLE):
                return None  # unknown monitor state: no evidence either way (IT4-07)
            if current is None or current.get("state") != "down":
                return True
            if revision(logs_dir) != since_revision:
                return False  # a failure after this publication began: it stays down
            log.warning("server disk has room again (free %d bytes)", free)
            ok = _write(_path(logs_dir), {"state": "recovered", "kind": current.get("kind"), "down_since": current.get("down_since"),
                                          "recovered_at": iso_utc_epoch(now), "recovered_at_epoch": now, "free_bytes": free,
                                          "floor_bytes": floor_bytes, "revision": since_revision})  # fmt: skip
            return True if ok else None
    except MonitorUnavailable as exc:
        log.warning("disk alert: %s", exc)
        return None
    except Exception:
        log.exception("disk alert: witness failed")
        return None
