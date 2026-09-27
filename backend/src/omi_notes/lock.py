"""Host locks of a vault (docs/vault.md, "Writer ownership"), one `flock` per role.

- `api.lock`: at most one HTTP server per vault on this host (it writes chunks, events and speaker
  changes). A second `serve` refuses to start, before it writes anything.
- `worker.lock`: at most one process runs the pipeline. Maintenance commands (`reprocess`,
  `retry-failed`) try to take it: if they get it they run inline, otherwise they only queue work
  (DB flags) for the running worker. `rebuild-index` needs both.
- `speakers.lock` (`SpeakerLock`): serializes speaker-label read-modify-writes between the API and
  the worker, also when the worker is a separate process.

They live in one folder per vault *path* under LOCK_DIR (default: next to the index root), so every
process using a vault on this host finds them whatever its INDEX_DIR — and never inside the synced
vault. The vault's `_omi/writer.json` lease is the advisory cross-host part. `flock` locks belong
to the open file, so they are released automatically when the process dies.
"""

from __future__ import annotations

import fcntl
import hashlib
import os
import threading
from pathlib import Path


class WorkerLock:
    def __init__(self, directory: Path, name: str = "worker.lock") -> None:
        self.path = directory / name
        self._fd: int | None = None

    @property
    def held(self) -> bool:
        return self._fd is not None

    def acquire(self) -> bool:
        """Take the lock without waiting; False if another process (or handle) holds it."""
        if self._fd is not None:
            return True
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return False
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode())
        self._fd = fd
        return True

    def held_elsewhere(self) -> bool:
        """Another process (or handle) holds it. Creates nothing: without the file nobody does."""
        if self._fd is not None:
            return False
        try:
            fd = os.open(self.path, os.O_RDONLY)
        except FileNotFoundError:
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        finally:
            os.close(fd)  # closing drops a lock we just took
        return False

    def owner(self) -> str:
        """The pid written by the holder (diagnostics only)."""
        try:
            return self.path.read_text().strip() or "?"
        except OSError:
            return "?"

    def release(self) -> None:
        if self._fd is not None:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
            os.close(self._fd)
            self._fd = None

    def __enter__(self) -> WorkerLock:
        return self

    def __exit__(self, *exc: object) -> None:
        self.release()


def locks_dir(vault) -> Path:
    from .vault import default_index_root

    root = vault.lock_root or default_index_root().parent / "locks"
    return root / hashlib.sha256(os.path.realpath(vault.root).encode()).hexdigest()[:16]


def worker_lock(vault) -> WorkerLock:
    return WorkerLock(locks_dir(vault), "worker.lock")


def api_lock(vault) -> WorkerLock:
    return WorkerLock(locks_dir(vault), "api.lock")


class SpeakerLock:
    """Re-entrant within a thread, exclusive across threads and processes: a process-wide
    `RLock` plus a blocking `flock` held by the outermost acquirer."""

    _shared: dict[str, tuple[threading.RLock, threading.local]] = {}  # per lock file, for every instance
    _guard = threading.Lock()

    def __init__(self, vault) -> None:
        self.path = locks_dir(vault) / "speakers.lock"
        key = os.path.realpath(self.path)
        with self._guard:
            self._rlock, self._local = self._shared.setdefault(key, (threading.RLock(), threading.local()))

    def __enter__(self) -> SpeakerLock:
        self._rlock.acquire()
        depth = getattr(self._local, "depth", 0)
        if depth == 0:
            try:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
                fcntl.flock(fd, fcntl.LOCK_EX)
            except BaseException:
                self._rlock.release()
                raise
            self._local.fd = fd
        self._local.depth = depth + 1
        return self

    def __exit__(self, *exc: object) -> None:
        self._local.depth -= 1
        if self._local.depth == 0:
            fcntl.flock(self._local.fd, fcntl.LOCK_UN)
            os.close(self._local.fd)
            self._local.fd = None
        self._rlock.release()
