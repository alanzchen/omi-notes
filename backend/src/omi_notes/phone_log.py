"""The phone's diagnostic log tail (`PUT /v1/diagnostics/phone-log`, feature `phone_log`).

Not notes data: plain lines kept beside the server's own log (`Settings.logs_dir / "phone"`, outside
the vault), so a person can read why a phone stalled without a TestFlight log export. The phone
sends only selected categories and warnings/errors, with tokens redacted, in bounded batches; this
side bounds them again and keeps at most `MAX_FILE_BYTES` per phone plus one rotated file.

Read them with: `tail -n 200 "<logs_dir>/phone/<device id>.log"` (production:
`~/Library/Application Support/omi-notes/index/logs/phone/`).
"""

from __future__ import annotations

import re
import threading
from pathlib import Path

MAX_LINES = 2000
MAX_MESSAGE = 500
MAX_FILE_BYTES = 5_000_000
LEVELS = {"debug", "info", "warning", "error"}
_SAFE = re.compile(r"[^A-Za-z0-9._-]")
_lock = threading.Lock()


class PhoneLogError(ValueError):
    pass


def _text(value: object, limit: int) -> str:
    return re.sub(r"[\r\n\t]+", " ", str(value))[:limit] if value is not None else ""


def append(logs_dir: Path, body: object) -> int:
    """Validates a batch and appends it; returns how many lines were stored."""
    if not isinstance(body, dict):
        raise PhoneLogError("expected an object")
    device = body.get("device_id")
    lines = body.get("lines")
    if not isinstance(device, str) or not device.strip() or not isinstance(lines, list):
        raise PhoneLogError("device_id and lines are required")
    if len(lines) > MAX_LINES:
        raise PhoneLogError(f"at most {MAX_LINES} lines")
    version = _text(body.get("app_version"), 40)
    out = []
    for line in lines:
        if not isinstance(line, dict):
            raise PhoneLogError("each line is an object")
        level = line.get("level") if line.get("level") in LEVELS else "info"
        out.append(f"{_text(line.get('at'), 30)} {level} [{_text(line.get('category'), 24)}] {_text(line.get('message'), MAX_MESSAGE)}"
                   f"{' · ' + version if version else ''}\n")
    name = _SAFE.sub("_", device.strip())[:80] or "phone"
    path = logs_dir / "phone" / f"{name}.log"
    with _lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.stat().st_size > MAX_FILE_BYTES:
            path.replace(path.with_suffix(".log.1"))
        with path.open("a", encoding="utf-8") as fh:
            fh.writelines(out)
    return len(out)
