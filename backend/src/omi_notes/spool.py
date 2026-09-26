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


def chunk_path(raw_dir: Path, device_id: str, capture_id: str, chunk_sequence: int) -> Path:
    return raw_dir / safe_component(device_id) / safe_component(capture_id) / f"{chunk_sequence}.omnc"


def store_chunk(raw_dir: Path, device_id: str, capture_id: str, chunk_sequence: int, body: bytes) -> Path:
    """Durably store a chunk body. Only after this returns may the ledger row be committed."""
    path = chunk_path(raw_dir, device_id, capture_id, chunk_sequence)
    atomic_write_bytes(path, body)
    return path
