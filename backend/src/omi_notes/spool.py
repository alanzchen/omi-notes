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


def fsync_file(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def confirm_chain(path: Path, anchor: Path) -> None:
    """The publication proof (DURABILITY-DESIGN, ASTRA-20261122-DESIGN-01/02): fsync `path` itself, then every directory
    from its parent up to and including `anchor`, unconditionally. A directory that already exists may have been
    created by an earlier attempt whose parent sync failed, so existence proves nothing (IT5-01). Raises OSError."""
    path, anchor = Path(path), Path(anchor)
    if path != anchor and anchor not in path.parents:
        raise ValueError(f"{path} is not under {anchor}")
    fsync_file(path) if not path.is_dir() else fsync_dir(path)
    directory = path.parent if path != anchor else None
    while directory is not None:
        fsync_dir(directory)
        directory = None if directory == anchor else directory.parent


def publish_new_bytes(path: Path, data: bytes, anchor: Path) -> None:
    """Write a new immutable artifact: directory chain confirmed → same-directory temp file → fsync → non-destructive link
    (an existing file is never replaced: FileExistsError) → `confirm_chain` of the file to `anchor`."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # the ancestors first (from the directory holding this file's directory up to the anchor): a directory whose own
    # entry can't be published gets no file in it. The file's own directory is confirmed with the file, after it.
    if path.parent != anchor:
        confirm_chain(path.parent.parent, anchor)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.link(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:  # a leftover temp name is harmless (readers ignore dot-files); it never fails the publication
            pass
    confirm_chain(path, anchor)


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
