"""The vault: one folder holding everything permanent (docs/vault.md).

The vault root is also the notes root. Machine data lives under `_omi/` (visible, so Obsidian
Sync copies it). SQLite is only an operational index kept *outside* the vault
(`index_dir()`), rebuilt from these files whenever it is missing or does not match.

Write rules (docs/vault.md, "Write rules"): every permanent fact is written atomically (temp in
the same directory → fsync → rename → fsync directory, new parent directories fsynced too) or
appended to a JSONL file (fsync) *before* the index transaction that refers to it, and the index
commits before any 2xx. Nothing in the vault is taken from file mtimes.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import socket
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import TYPE_CHECKING

from .spool import atomic_write_bytes, fsync_dir, make_dirs_durable, safe_component
from .util import canonical_json

if TYPE_CHECKING:
    from .settings import Settings

log = logging.getLogger(__name__)

FORMAT = 1
OMI = "_omi"
LEASE_RENEW_SECONDS = 5 * 60
LEASE_STALE_SECONDS = 15 * 60
LEGACY_DB_NAME = "omi-notes.sqlite3"

# Filenames sync tools produce for conflicting copies (Dropbox, Syncthing, iCloud/Finder
# duplicates like "seal 2.json", Obsidian Sync / Nextcloud "(conflict ...)").
_CONFLICT_NAMES = re.compile(
    r"(conflicted copy|\.sync-conflict-|\(conflict|^.+ \d+\.(json|jsonl|omnc|gone|omiaudio)$)",
    re.IGNORECASE,
)


class VaultError(RuntimeError):
    """The vault cannot be opened for writing (message says why and what to do)."""


class LeaseError(VaultError):
    """Another backend holds a live writer lease on this vault."""


def default_index_root() -> Path:
    if sys.platform == "darwin":
        return Path("~/Library/Application Support/omi-notes/index").expanduser()
    state = os.environ.get("XDG_STATE_HOME") or "~/.local/state"
    return Path(state).expanduser() / "omi-notes" / "index"


def uuid7_time(value: str) -> float | None:
    """The timestamp (epoch seconds) embedded in a UUIDv7, else None."""
    try:
        u = uuid.UUID(value)
    except ValueError:
        return None
    if u.version != 7:
        return None
    return (u.int >> 80) / 1000.0


@dataclass
class Vault:
    root: Path
    info: dict = field(default_factory=dict)

    # -- layout ----------------------------------------------------------------------------------

    @property
    def omi(self) -> Path:
        return self.root / OMI

    @property
    def raw(self) -> Path:
        return self.omi / "raw"

    @property
    def events_dir(self) -> Path:
        return self.omi / "events"

    @property
    def conversations(self) -> Path:
        return self.omi / "conversations"

    @property
    def people(self) -> Path:
        return self.omi / "people"

    @property
    def speakers(self) -> Path:
        return self.omi / "speakers"

    @property
    def displaced(self) -> Path:
        return self.omi / "displaced"

    @property
    def vault_json(self) -> Path:
        return self.omi / "VAULT.json"

    @property
    def writer_json(self) -> Path:
        return self.omi / "writer.json"

    @property
    def vault_id(self) -> str:
        return self.info["vault_id"]

    @property
    def timezone(self) -> str | None:
        return self.info.get("timezone")

    def capture_dir(self, device_id: str, capture_id: str) -> Path:
        return self.raw / safe_component(device_id) / safe_component(capture_id)

    def chunk_path(self, device_id: str, capture_id: str, seq: int) -> Path:
        return self.capture_dir(device_id, capture_id) / f"{seq}.omnc"

    def tombstone_path(self, device_id: str, capture_id: str, seq: int) -> Path:
        return self.capture_dir(device_id, capture_id) / f"{seq}.gone"

    def seal_path(self, device_id: str, capture_id: str) -> Path:
        return self.capture_dir(device_id, capture_id) / "seal.json"

    def receipts_path(self, device_id: str, capture_id: str) -> Path:
        return self.capture_dir(device_id, capture_id) / "receipts.jsonl"

    def capture_json_path(self, device_id: str, capture_id: str) -> Path:
        return self.capture_dir(device_id, capture_id) / "capture.json"

    def events_path(self, received_at: float) -> Path:
        day = datetime.fromtimestamp(received_at, UTC).date().isoformat()
        return self.events_dir / f"{day}.jsonl"

    def conversation_dir(self, conv_id: str) -> Path:
        """`_omi/conversations/YYYY-MM/<id>/` (month of the id's UUIDv7 time, UTC)."""
        t = uuid7_time(conv_id)
        month = datetime.fromtimestamp(t, UTC).strftime("%Y-%m") if t is not None else "unknown"
        return self.conversations / month / safe_component(conv_id)

    def person_dir(self, person_id: str) -> Path:
        return self.people / safe_component(person_id)

    def relpath(self, path: Path) -> str:
        return path.relative_to(self.root).as_posix()

    # -- opening ---------------------------------------------------------------------------------

    @classmethod
    def open(cls, settings: Settings, *, create: bool = True) -> Vault:
        """Open (and on first use initialize) the vault at VAULT_DIR.

        Refuses a legacy NOTES_DIR/DATA_DIR install (it must be migrated), a vault written by a
        newer format, and a `_omi/` folder without `VAULT.json` (an incomplete sync or an
        interrupted migration: "incomplete sync is not an empty vault")."""
        check_legacy(settings)
        vault = cls(settings.vault_dir)
        if vault.vault_json.exists():
            vault.info = json.loads(vault.vault_json.read_text())
            if int(vault.info.get("format", 0)) > FORMAT:
                raise VaultError(
                    f"{vault.root} was written by a newer omi-notes (vault format {vault.info.get('format')}); upgrade first"
                )
            vault.sync_render_settings(settings)
            return vault
        if vault.omi.exists() and any(vault.omi.iterdir()):
            raise VaultError(
                f"{vault.omi} exists but has no VAULT.json: the vault is incomplete (still syncing, or an interrupted "
                "`omi-notes migrate-vault`). Wait for the sync to finish or re-run the migration."
            )
        if not create:
            raise VaultError(f"{vault.root} is not an omi-notes vault (no _omi/VAULT.json)")
        vault.info = new_vault_info(settings)
        vault.write_json(vault.vault_json, vault.info)
        log.info("initialized vault %s (%s)", vault.root, vault.vault_id)
        return vault

    def sync_render_settings(self, settings: Settings) -> None:
        """Record explicitly configured render-affecting settings (TIMEZONE, OWNER_NAME) in
        VAULT.json, so another machine pointed at this vault renders the same notes."""
        changed = {key: getattr(settings, key) for key in ("timezone", "owner_name")
                   if key in settings.model_fields_set and self.info.get(key) != getattr(settings, key)}  # fmt: skip
        if changed:
            self.info |= changed
            self.write_json(self.vault_json, self.info)

    # -- files -----------------------------------------------------------------------------------

    @staticmethod
    def write_json(path: Path, value: object, *, pretty: bool = True) -> bytes:
        data = (json.dumps(value, indent=1, sort_keys=True, ensure_ascii=False) + "\n").encode() if pretty else (
            canonical_json(value).encode()
        )
        atomic_write_bytes(path, data)
        return data

    @staticmethod
    def read_json(path: Path) -> dict | None:
        try:
            return json.loads(path.read_text())
        except FileNotFoundError:
            return None

    @staticmethod
    def append_jsonl(path: Path, value: object) -> None:
        """Append one line durably. A torn last line (a crash mid-append) is terminated first, so
        the new line is never glued onto it; readers skip the torn line."""
        line = (canonical_json(value) + "\n").encode()
        new = not path.exists()
        if new:
            make_dirs_durable(path.parent)
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            size = os.fstat(fd).st_size
            if size:
                last = os.pread(fd, 1, size - 1)
                if last != b"\n":
                    line = b"\n" + line
            os.write(fd, line)
            os.fsync(fd)
        finally:
            os.close(fd)
        if new:
            fsync_dir(path.parent)

    @staticmethod
    def read_jsonl(path: Path) -> list[dict]:
        """Complete, parseable object lines (a torn or corrupt line is skipped)."""
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            return []
        out = []
        for raw in data.split(b"\n"):
            if not raw.strip():
                continue
            try:
                value = json.loads(raw)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if isinstance(value, dict):
                out.append(value)
        return out

    # -- writer lease ----------------------------------------------------------------------------

    def read_lease(self) -> dict | None:
        try:
            return json.loads(self.writer_json.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def acquire_lease(self, *, take_over: bool = False, now: float | None = None) -> str:
        """Become the vault's writer. The caller already holds the host lock (index dir), so a
        lease from this host is stale by construction; a foreign host's lease renewed less than
        15 minutes ago is refused unless `take_over` (only after that writer was stopped)."""
        now = time.time() if now is None else now
        lease = self.read_lease()
        host = socket.gethostname()
        if lease and lease.get("host") != host and not take_over:
            age = now - float(lease.get("renewed_at") or 0)
            if age < LEASE_STALE_SECONDS:
                raise LeaseError(
                    f"{lease.get('host')} (pid {lease.get('pid')}) is writing this vault (lease renewed "
                    f"{age / 60:.0f} min ago). Stop it first, or pass --take-over once it is stopped."
                )
        writer_id = uuid.uuid4().hex
        self.write_json(self.writer_json, {"writer_id": writer_id, "host": host, "pid": os.getpid(),
                                           "started_at": now, "renewed_at": now})  # fmt: skip
        return writer_id

    def check_lease(self, writer_id: str) -> bool:
        lease = self.read_lease()
        return lease is not None and lease.get("writer_id") == writer_id

    def renew_lease(self, writer_id: str, now: float | None = None) -> bool:
        """Renew our lease; False (fenced) when someone else took it over."""
        lease = self.read_lease()
        if lease is None or lease.get("writer_id") != writer_id:
            return False
        lease["renewed_at"] = time.time() if now is None else now
        self.write_json(self.writer_json, lease)
        return True

    def foreign_live_lease(self, now: float | None = None) -> dict | None:
        now = time.time() if now is None else now
        lease = self.read_lease()
        if lease and lease.get("host") != socket.gethostname():
            if now - float(lease.get("renewed_at") or 0) < LEASE_STALE_SECONDS:
                return lease
        return None

    # -- divergence ------------------------------------------------------------------------------

    def divergence(self) -> list[str]:
        """Sync conflict copies and duplicate conversation records under `_omi/` (never merged:
        writes stop until a person resolves them)."""
        problems: list[str] = []
        if not self.omi.exists():
            return problems
        for dirpath, _dirnames, filenames in os.walk(self.omi):
            for name in filenames:
                if name.startswith(".") and name.endswith(".tmp"):
                    continue
                if _CONFLICT_NAMES.search(name):
                    problems.append(f"sync conflict copy: {self.relpath(Path(dirpath) / name)}")
        seen: dict[str, Path] = {}
        if self.conversations.exists():
            for month in sorted(self.conversations.iterdir()):
                if not month.is_dir():
                    continue
                for conv in month.iterdir():
                    if conv.name in seen:
                        problems.append(f"duplicate conversation record {conv.name}: {self.relpath(seen[conv.name])} "
                                        f"and {self.relpath(conv)}")  # fmt: skip
                    seen[conv.name] = conv
        return problems


def new_vault_info(settings: Settings, *, now: float | None = None) -> dict:
    return {
        "vault_id": str(uuid.uuid4()),
        "format": FORMAT,
        "created_at": time.time() if now is None else now,
        # Render-affecting, non-secret settings: another machine renders the same notes.
        "timezone": settings.timezone,
        "owner_name": settings.owner_name,
    }


def index_dir(settings: Settings, vault: Vault) -> Path:
    """`<INDEX_DIR>/<vault_id>-<sha(realpath)[:8]>/`: two copies of one vault never share an index."""
    root = settings.index_dir or default_index_root()
    real = os.path.realpath(vault.root)
    return root / f"{vault.vault_id}-{hashlib.sha256(real.encode()).hexdigest()[:8]}"


def legacy_problem(settings: Settings) -> str | None:
    """Why this is an unmigrated NOTES_DIR/DATA_DIR install, else None."""
    if "vault_dir" in settings.model_fields_set:
        return None
    if settings.notes_dir is not None or settings.data_dir is not None:
        return "NOTES_DIR/DATA_DIR are set"
    legacy_db = Path("~/.local/share/omi-notes").expanduser() / LEGACY_DB_NAME
    if legacy_db.exists():
        return f"a pre-vault database exists at {legacy_db}"
    return None


def migrate_command(settings: Settings) -> str:
    notes = settings.notes_dir or Path("~/Documents/OmiNotes")
    data = settings.data_dir or Path("~/.local/share/omi-notes")
    return f"omi-notes migrate-vault --notes-dir {notes} --data-dir {data} --vault-dir {notes}"


def check_legacy(settings: Settings) -> None:
    problem = legacy_problem(settings)
    if problem:
        raise VaultError(
            f"This is a pre-vault install ({problem}). Stop the server and migrate it once:\n"
            f"  {migrate_command(settings)}\n"
            "then set VAULT_DIR (and remove NOTES_DIR/DATA_DIR) in backend/.env."
        )
