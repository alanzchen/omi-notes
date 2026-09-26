"""`DATA_DIR/worker.lock`: at most one process runs the pipeline at a time.

The worker holds an exclusive `flock` for its whole life. Maintenance commands (`reprocess`,
`retry-failed`, `rebuild`) try to take it: if they get it they run inline, otherwise they only
queue work (DB flags) for the running worker. `flock` locks belong to the open file, so they are
released automatically when the process dies.
"""

from __future__ import annotations

import fcntl
import os
from pathlib import Path


class WorkerLock:
    def __init__(self, data_dir: Path) -> None:
        self.path = data_dir / "worker.lock"
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

    def release(self) -> None:
        if self._fd is not None:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
            os.close(self._fd)
            self._fd = None

    def __enter__(self) -> WorkerLock:
        return self

    def __exit__(self, *exc: object) -> None:
        self.release()
