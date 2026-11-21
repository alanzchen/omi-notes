"""`logs/alerts/disk.json`: the server's disk is below the upload floor (or a write hit ENOSPC / SQLITE_FULL), and when it
recovered.

Same conventions as `alerts/local-transcription.json` (`state`, `down_since`, `alerted_at`/`recovered_at`, `check`),
for the brief / an external notifier. The state lives in the file itself, never in SQLite: a full disk may be exactly
what stops the index from writing. Nothing is ever deleted to make room (raw audio is kept permanently).

Two kinds, each cleared only on its own evidence (ASTRA-20261121-IT1-03):
- `space`: free space below the floor on a watched volume; recovered once every watched volume (the vault's raw
  directory and the index directory) has the floor plus `HYSTERESIS` free, so a value hovering at the floor doesn't
  flap the file and the log.
- `write`: a write failed for lack of space; recovered only once the index has written again after the latest such
  failure, and every watched volume was measured with room (one that can't be measured is not evidence).
Monitoring never fails the caller: a malformed or unwritable alert file is logged and treated as unknown
(ASTRA-20261121-IT1-02)."""

from __future__ import annotations

import json
import logging
import shutil
from collections.abc import Iterable
from pathlib import Path

from .util import iso_utc_epoch
from .vault import Vault

log = logging.getLogger(__name__)

CHECK = "df -h ~/OmiNotes; the phone keeps its audio and retries (507) until there is room"
HYSTERESIS = 256 * 1024 * 1024


def _path(logs_dir: Path) -> Path:
    return logs_dir / "alerts" / "disk.json"


def read(logs_dir: Path) -> dict | None:
    """The alert as written, or None when absent or not an alert-shaped object (unknown)."""
    try:
        value = json.loads(_path(logs_dir).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(value, dict) or value.get("state") not in ("down", "recovered"):
        return None
    return value


def _write(path: Path, value: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        Vault.write_json(path, value)
    except OSError as exc:  # the disk may be too full even for this small file: the log line still says it
        log.error("couldn't write %s: %s", path, exc)


def note_down(logs_dir: Path, *, free_bytes: int | None, floor_bytes: int, reason: str, now: float, kind: str = "write") -> None:
    """The disk is too full to take audio: say so once (the first `down_since` stays until it recovers). A write failure
    during a space alert upgrades it to `write` (it then needs write evidence to clear)."""
    try:
        path = _path(logs_dir)
        current = read(logs_dir)
        if current and current.get("state") == "down":
            if kind == "write":
                # every write failure moves the cutoff: only an index write after the latest one is evidence
                # (ASTRA-20261121-IT3-02)
                _write(path, {**current, "kind": "write", "reason": reason, "last_failure_epoch": now})
            return
        log.error("server disk too full to take audio (%s; free %s, floor %d)", reason, free_bytes, floor_bytes)
        _write(path, {"state": "down", "kind": kind, "down_since": iso_utc_epoch(now), "down_since_epoch": now,
                      "alerted_at": iso_utc_epoch(now), "last_failure_epoch": now, "reason": reason, "free_bytes": free_bytes,
                      "floor_bytes": floor_bytes, "check": CHECK})  # fmt: skip
    except Exception:
        log.exception("disk alert: couldn't note down")


def watch(logs_dir: Path, data_dir: Path, *, floor_bytes: int, now: float, other_dirs: Iterable[Path] = (),
          last_index_write: float | None = None) -> None:
    """From the worker: down while a watched volume is below the floor; recovered per the alert's kind (see module)."""
    try:
        frees, unmeasured = [], False
        for d in [data_dir, *other_dirs]:
            try:
                frees.append(shutil.disk_usage(d).free)
            except OSError:
                unmeasured = True
        if not frees:
            return
        free = min(frees)
        if free < floor_bytes:
            note_down(logs_dir, free_bytes=free, floor_bytes=floor_bytes, reason="free space below the upload floor", now=now, kind="space")
            return
        current = read(logs_dir)
        if not current or current.get("state") != "down":
            return
        if unmeasured or free < floor_bytes + HYSTERESIS:
            return  # a volume that can't be measured, or one hovering at the floor, is not recovery
        if current.get("kind", "write") == "write":
            since = current.get("last_failure_epoch", current.get("down_since_epoch"))
            if last_index_write is None or not isinstance(since, (int, float)) or last_index_write <= since:
                return  # no evidence the index has written since the latest failure
        log.warning("server disk has room again (free %d bytes)", free)
        _write(_path(logs_dir), {"state": "recovered", "kind": current.get("kind"), "down_since": current.get("down_since"),
                                 "recovered_at": iso_utc_epoch(now), "free_bytes": free, "floor_bytes": floor_bytes})  # fmt: skip
    except Exception:
        log.exception("disk alert: watch failed")
