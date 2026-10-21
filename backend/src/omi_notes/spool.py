"""Durable file writes: temp file in the same directory → fsync → rename → fsync directory."""

from __future__ import annotations

import os
import re
import tempfile
from pathlib import Path

_UNSAFE = re.compile(r"[^A-Za-z0-9._-]")


def safe_component(value: str) -> str:
    """A path component that cannot escape its directory."""
    cleaned = _UNSAFE.sub("_", value)[:128].strip(".")
    return cleaned or "_"


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def make_dirs_durable(path: Path) -> None:
    """`mkdir -p` that fsyncs each new directory's parent, so the entries survive power loss."""
    missing: list[Path] = []
    probe = path
    while not probe.exists():
        missing.append(probe)
        probe = probe.parent
    for directory in reversed(missing):
        try:
            directory.mkdir()
        except FileExistsError:
            pass
        fsync_dir(directory.parent)


def atomic_write_bytes(path: Path, data: bytes) -> None:
    make_dirs_durable(path.parent)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    fsync_dir(path.parent)
