"""`logs/alerts/disk.json`: the server's disk is below the upload floor (or a write hit ENOSPC), and when it recovered.

Same conventions as `alerts/local-transcription.json` (`state`, `down_since`, `alerted_at`/`recovered_at`, `check`),
for the brief / an external notifier. The state lives in the file itself, never in SQLite: a full disk may be exactly
what stops the index from writing. Nothing is ever deleted to make room (raw audio is kept permanently)."""

from __future__ import annotations

import json
import logging
import shutil
from pathlib import Path

from .util import iso_utc_epoch
from .vault import Vault

log = logging.getLogger(__name__)

CHECK = "df -h ~/OmiNotes; the phone keeps its audio and retries (507) until there is room"


def _path(logs_dir: Path) -> Path:
    return logs_dir / "alerts" / "disk.json"


def _read(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def note_down(logs_dir: Path, *, free_bytes: int | None, floor_bytes: int, reason: str, now: float) -> None:
    """The disk is too full to take audio: say so once (the first `down_since` stays until it recovers)."""
    path = _path(logs_dir)
    current = _read(path)
    if current and current.get("state") == "down":
        return
    log.error("server disk too full to take audio (%s; free %s, floor %d)", reason, free_bytes, floor_bytes)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        Vault.write_json(path, {"state": "down", "down_since": iso_utc_epoch(now), "alerted_at": iso_utc_epoch(now),
                                "reason": reason, "free_bytes": free_bytes, "floor_bytes": floor_bytes, "check": CHECK})  # fmt: skip
    except OSError as exc:  # the disk may be too full even for this small file: the log line above still says it
        log.error("couldn't write %s: %s", path, exc)


def watch(logs_dir: Path, data_dir: Path, *, floor_bytes: int, now: float) -> None:
    """From the worker: down while free space is below the floor; recovered once it is back above it."""
    try:
        free = shutil.disk_usage(data_dir).free
    except OSError:
        return
    if free < floor_bytes:
        note_down(logs_dir, free_bytes=free, floor_bytes=floor_bytes, reason="free space below the upload floor", now=now)
        return
    path = _path(logs_dir)
    current = _read(path)
    if current and current.get("state") == "down":
        log.warning("server disk has room again (free %d bytes)", free)
        try:
            Vault.write_json(path, {"state": "recovered", "down_since": current.get("down_since"),
                                    "recovered_at": iso_utc_epoch(now), "free_bytes": free, "floor_bytes": floor_bytes})  # fmt: skip
        except OSError as exc:
            log.error("couldn't write %s: %s", path, exc)
