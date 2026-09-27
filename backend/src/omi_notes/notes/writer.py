"""Filesystem side of the notes folder: atomic writes, write-if-changed, My Notes preservation."""

from __future__ import annotations

import hashlib
import re
import threading
from datetime import datetime
from pathlib import Path

import yaml

from .. import spool
from ..spool import atomic_write_bytes

MY_NOTES_START = "<!-- my-notes:start -->"
MY_NOTES_END = "<!-- my-notes:end -->"

_lock = threading.Lock()
_UNSAFE_TITLE = re.compile(r'[/\\:*?"<>|#^\[\]\x00-\x1f]')


_REGION = re.compile(r"^## My Notes[ \t]*\n[ \t]*\n?" + re.escape(MY_NOTES_START), re.MULTILINE)


class UserRegionError(ValueError):
    """The file's My Notes markers are ambiguous; it must not be overwritten."""


def extract_my_notes(text: str) -> str | None:
    """The user's text in the dedicated `## My Notes` block, or None when the file has no markers.

    Generated text never contains the markers (the renderer neutralizes `<!--`), so exactly one
    start and one end marker must exist, the start directly under the `## My Notes` heading.
    Anything else raises `UserRegionError` rather than guessing which text is the user's.
    """
    starts, ends = text.count(MY_NOTES_START), text.count(MY_NOTES_END)
    if starts == 0 and ends == 0:
        return None
    if starts != 1 or ends != 1:
        raise UserRegionError(f"{starts} start and {ends} end markers")
    match = _REGION.search(text)
    end = text.find(MY_NOTES_END)
    if match is None or end < match.end():
        raise UserRegionError("markers are not in the My Notes section")
    return text[match.end() : end]


def generated_sha(text: str) -> str:
    """sha256 of a note without its My Notes content: equal before and after the user writes in
    My Notes, different once anything else was edited (`written_sha`, docs/vault.md "Notes")."""
    try:
        mine = extract_my_notes(text)
    except UserRegionError:
        mine = None
    if mine:
        start = text.find(MY_NOTES_START) + len(MY_NOTES_START)
        text = text[:start] + text[start + len(mine) :]
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_note_id(path: Path) -> str | None:
    """The `id` in a note's YAML frontmatter (None if missing or unreadable)."""
    try:
        text = path.read_text(encoding="utf-8")
    except (FileNotFoundError, UnicodeDecodeError):
        return None
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None
    try:
        front = yaml.safe_load(text[4:end])
    except yaml.YAMLError:
        return None
    value = front.get("id") if isinstance(front, dict) else None
    return value if isinstance(value, str) else None


def write_if_changed(path: Path, content: str) -> bool:
    """Atomically replace `path` only when the bytes differ (keeps sync tools and Obsidian calm)."""
    data = content.encode("utf-8")
    with _lock:
        try:
            if path.read_bytes() == data:
                return False
        except FileNotFoundError:
            pass
        atomic_write_bytes(path, data)
        return True


def remove(path: Path | None) -> bool:
    """Delete a file durably (the directory entry is fsynced); False if it was not there."""
    if path is None:
        return False
    with _lock:
        try:
            path.unlink()
        except FileNotFoundError:
            return False
        spool.fsync_dir(path.parent)
        return True


def sanitize_title(title: str, limit: int = 80) -> str:
    cleaned = _UNSAFE_TITLE.sub(" ", title)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" .")
    if len(cleaned) > limit:
        cleaned = cleaned[:limit].rsplit(" ", 1)[0].strip(" .") or cleaned[:limit]
    return cleaned or "Conversation"


def conversation_relpath(start_local: datetime, title: str) -> str:
    return (
        f"Conversations/{start_local:%Y}/{start_local:%Y-%m}/"
        f"{start_local:%Y-%m-%d %H%M} {sanitize_title(title)}.md"
    )


def with_suffix_id(relpath: str, short_id: str) -> str:
    stem, ext = relpath.rsplit(".", 1)
    return f"{stem} {short_id}.{ext}"


def discarded_relpath(start_local: datetime, short_id: str) -> str:
    return f"_discarded/{start_local:%Y-%m-%d %H%M} {short_id}.md"


def stub_relpath(start_local: datetime, short_id: str) -> str:
    return f"_in-progress/{start_local:%Y-%m-%d %H%M} (recording) {short_id}.md"


def link_target(relpath: str) -> str:
    """Obsidian wikilink target for a notes-relative path (no extension)."""
    return relpath[:-3] if relpath.endswith(".md") else relpath
