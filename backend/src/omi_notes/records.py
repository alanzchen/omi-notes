"""`_omi/conversations/YYYY-MM/<id>/conversation.json`: a finalized conversation's permanent record.

Blocks (docs/vault.md):
- `decision`: everything segmentation decided at finalize (never recomputed: it depended on the
  wall clock, arrival and processing order, and evidence retention later deletes), including
  `known_through` — speech from (capture, seq) is known to this conversation iff
  `seq <= known_through[capture]`;
- `settings`: render-affecting settings at completion (config changes don't rewrite history);
- `render`: what the note was rendered from and where it is;
- `failure`: why it failed permanently.

Open conversations have no record: they are recomputed. The index row is derived from the record
(`row_from_record`) and the record from the row (`record_from_row`), so the rebuild and the running
worker agree by construction.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path

from .spool import atomic_write_bytes
from .util import sha256_hex
from .vault import Vault

FORMAT = 1

DECISION_COLUMNS = {
    # record key: (column, kind)
    "start": ("start", "float"),
    "end": ("end", "float"),
    "provisional": ("provisional", "bool"),
    "late_audio": ("late_audio", "bool"),
    "related_id": ("related_id", "str"),
    "start_explicit": ("start_explicit", "bool"),
    "end_explicit": ("end_explicit", "bool"),
    "speech_seconds": ("speech_seconds", "float"),
    "gaps": ("gaps_json", "json"),
    "blocks": ("blocks_json", "json"),
    "sources": ("sources_json", "json"),
    "lost_seconds": ("lost_seconds", "float"),
    "clock_suspect": ("clock_suspect", "bool"),
    "finalized_at": ("finalized_at", "float"),
    # set when the conversation lies inside a voice-enrollment window: discarded without STT
    "enrollment_id": ("enrollment_id", "str"),
}

RENDER_COLUMNS = {
    "kind": None,  # from index_json.kind
    "note_path": ("note_path", "str"),
    "stale_note_path": ("stale_note_path", "str"),
    "revision": ("revision", "int"),
    "content_sha": ("content_sha", "str"),
    "written_sha": ("written_sha", "str"),
    "frozen": ("frozen", "bool"),
    "title": ("title", "str"),
    "index": ("index_json", "json"),
    "stt_ref": ("stt_ref", "str"),
    "audio_sha": ("audio_sha", "str"),
    "transcript_sha": ("transcript_sha", "str"),
    "llm_ref": ("llm_ref", "str"),
    "llm_status": ("llm_status", "str"),
    "prompt_version": ("prompt_version", "int"),
    "language": ("language", "str"),
    "relevance": ("relevance", "str"),
    "done_at": ("done_at", "float"),
}


def _out(value, kind: str):
    if value is None:
        return None
    if kind == "bool":
        return bool(value)
    if kind == "json":
        return json.loads(value)
    if kind == "float":
        return float(value)
    if kind == "int":
        return int(value)
    return value


def _in(value, kind: str):
    if value is None:
        return None if kind not in ("bool",) else 0
    if kind == "bool":
        return int(bool(value))
    if kind == "json":
        return json.dumps(value, ensure_ascii=False)
    return value


def _get(row, col: str):
    """A column value; None when the row predates the column (e.g. a legacy install's row)."""
    try:
        return row[col]
    except (KeyError, IndexError):
        return None


def record_from_row(row, known_through: dict[str, int]) -> dict:
    """The permanent record of a non-open conversation row."""
    decision = {key: _out(_get(row, col), kind) for key, (col, kind) in DECISION_COLUMNS.items()}
    decision["known_through"] = dict(sorted(known_through.items()))
    record: dict = {
        "format": FORMAT,
        "id": row["id"],
        "device_id": row["device_id"],
        "decision": decision,
        "settings": json.loads(row["settings_json"]) if row["settings_json"] else None,
        "render": None,
        "failure": None,
    }
    if row["note_path"]:
        render = {key: _out(row[col], kind) for key, spec in RENDER_COLUMNS.items() if spec for col, kind in [spec]}
        render["kind"] = (json.loads(row["index_json"]) if row["index_json"] else {}).get("kind")
        record["render"] = render
    if row["status"] == "failed":
        record["failure"] = {"stage": row["failed_stage"], "error": row["error"], "kind": row["error_kind"]}
    return record


def row_from_record(record: dict) -> tuple[dict, dict[str, int]]:
    """Index column values (and known_through) for a record; status is derived."""
    decision = record["decision"]
    values: dict = {"id": record["id"], "device_id": record["device_id"]}
    for key, (col, kind) in DECISION_COLUMNS.items():
        values[col] = _in(decision.get(key), kind)
    for col in ("gaps_json", "blocks_json", "sources_json"):
        values[col] = values[col] if values[col] is not None else "[]"
    for col in ("speech_seconds", "lost_seconds"):
        values[col] = values[col] if values[col] is not None else 0.0
    values["settings_json"] = json.dumps(record["settings"]) if record.get("settings") else None
    render = record.get("render")
    failure = record.get("failure")
    for key, spec in RENDER_COLUMNS.items():
        if spec:
            col, kind = spec
            values[col] = _in(render.get(key), kind) if render else _in(None, kind)
    values["revision"] = values["revision"] or 0
    if failure:
        status = "failed"
        values.update(error=failure.get("error"), error_kind=failure.get("kind"), failed_stage=failure.get("stage"))
    else:
        values.update(error=None, error_kind=None, failed_stage=None)
        if decision.get("enrollment_id"):
            status = "discarded"
        else:
            status = ("discarded" if render.get("kind") == "discarded" else "done") if render else "closed"
    values["status"] = status
    return values, {k: int(v) for k, v in (decision.get("known_through") or {}).items()}


def record_path(vault: Vault, conv_id: str) -> Path:
    return vault.conversation_dir(conv_id) / "conversation.json"


def record_bytes(record: dict) -> bytes:
    return (json.dumps(record, indent=1, sort_keys=True, ensure_ascii=False) + "\n").encode()


def write_record(vault: Vault, record: dict) -> str:
    data = record_bytes(record)
    atomic_write_bytes(record_path(vault, record["id"]), data)
    return sha256_hex(data)


def load_records(vault: Vault) -> Iterator[tuple[Path, dict | None, str]]:
    """(path, record or None if unreadable, sha256 of the bytes) for every conversation.json."""
    if not vault.conversations.exists():
        return
    for month in sorted(vault.conversations.iterdir()):
        if not month.is_dir():
            continue
        for conv in sorted(month.iterdir()):
            path = conv / "conversation.json"
            try:
                data = path.read_bytes()
            except (FileNotFoundError, NotADirectoryError):
                continue
            try:
                record = json.loads(data)
            except (json.JSONDecodeError, UnicodeDecodeError):
                record = None
            yield path, record, sha256_hex(data)
