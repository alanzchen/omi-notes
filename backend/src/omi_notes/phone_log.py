"""The phone's diagnostic log tail (`PUT /v1/diagnostics/phone-log`, feature `phone_log`).

Not notes data: plain lines kept beside the server's own log (`Settings.logs_dir / "phone"`, outside
the vault), so a person can read why a phone stalled without a TestFlight log export. The phone
sends only selected categories and warnings/errors, with tokens redacted, in bounded batches; this
side bounds them again and keeps at most `MAX_FILE_BYTES` per phone plus one rotated file, and at
most `MAX_TOTAL_BYTES` (and nothing older than `MAX_AGE_DAYS`) for all phones together: the oldest
other phones' files go first. These are disposable diagnostics, not notes data.

Read them with: `tail -n 200 "<logs_dir>/phone/<device id>.log"` (production:
`~/Library/Application Support/omi-notes/index/logs/phone/`).
"""

from __future__ import annotations

import re
import threading
import time
from pathlib import Path

MAX_LINES = 2000
MAX_MESSAGE = 500
MAX_FILE_BYTES = 5_000_000
MAX_TOTAL_BYTES = 50_000_000
MAX_AGE_DAYS = 30
LEVELS = {"debug", "info", "warning", "error"}
# what the app sends: "phone-" + its install id, a lowercase UUID (validated, never sanitized, so two
# ids can't share a file and none can name a path)
_DEVICE = re.compile(r"phone-[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
_lock = threading.Lock()


class PhoneLogError(ValueError):
    pass


def _text(value: object, limit: int, field: str = "app_version") -> str:
    if value is None:
        return ""
    if not isinstance(value, str):
        raise PhoneLogError(f"{field} must be a string")
    return re.sub(r"[\r\n\t]+", " ", value)[:limit]


def append(logs_dir: Path, body: object) -> int:
    """Validates a batch and appends it; returns how many lines were stored."""
    if not isinstance(body, dict):
        raise PhoneLogError("expected an object")
    device = body.get("device_id")
    lines = body.get("lines")
    if not isinstance(device, str) or not isinstance(lines, list):
        raise PhoneLogError("device_id and lines are required")
    if not _DEVICE.fullmatch(device):
        raise PhoneLogError("device_id must be phone-<install id>")
    if len(lines) > MAX_LINES:
        raise PhoneLogError(f"at most {MAX_LINES} lines")
    version = _text(body.get("app_version"), 40)
    out = []
    for line in lines:
        if not isinstance(line, dict):
            raise PhoneLogError("each line is an object")
        level = _text(line.get("level"), 16, "level")
        level = level if level in LEVELS else "info"
        at, category = _text(line.get("at"), 30, "at"), _text(line.get("category"), 24, "category")
        message = _text(line.get("message"), MAX_MESSAGE, "message")
        out.append(f"{at} {level} [{category}] {message}{' · ' + version if version else ''}\n")
    if not out:
        return 0  # nothing to keep: no file
    folder = logs_dir / "phone"
    path = folder / f"{device}.log"
    with _lock:
        folder.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.stat().st_size > MAX_FILE_BYTES:
            path.replace(path.with_suffix(".log.1"))
        with path.open("a", encoding="utf-8") as fh:
            fh.writelines(out)
        _retain(folder, keep=device)
    return len(out)


def _retain(folder: Path, keep: str) -> None:
    """Drops files past the age limit, then the oldest other phones' files while the folder is over
    its total; the phone that just wrote keeps its log."""
    cutoff = time.time() - MAX_AGE_DAYS * 86_400
    files = []
    for f in folder.iterdir():
        try:
            st = f.stat()
        except FileNotFoundError:
            continue
        if not f.is_file():
            continue
        if st.st_mtime < cutoff and not f.name.startswith(keep + "."):
            f.unlink(missing_ok=True)
            continue
        files.append((st.st_mtime, st.st_size, f))
    total = sum(size for _, size, _ in files)
    for _, size, f in sorted(files, key=lambda t: t[0]):
        if total <= MAX_TOTAL_BYTES:
            break
        if f.name.startswith(keep + "."):
            continue
        f.unlink(missing_ok=True)
        total -= size
