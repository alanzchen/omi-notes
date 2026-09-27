"""`omi-notes migrate-vault`: turn a pre-vault install (NOTES_DIR + DATA_DIR) into a vault.

Run with the server stopped (docs/vault.md, "Migration"). The legacy data is only read (the
ledger through a consistent SQLite backup copy); on any mismatch the new vault is left invalid
(no `VAULT.json`) and the legacy install keeps working.

1. copy and verify every raw chunk; a tombstone (plus `capture.json` evidence) for each chunk
   retention already deleted; `receipts.jsonl` from the ledger's receipt times;
2. `seal_json` → `seal.json` (its body re-serializes byte-for-byte to the stored canonical JSON);
3. events → `events/YYYY-MM-DD.jsonl`;
4. finalized conversations → `conversation.json` records, with
   `known_through[capture]` = the highest chunk sequence of that capture's speech rows with
   `id <= speech_watermark` (`last + 1` when all of a finalized capture's speech was known), and
   their provider results copied from `DATA_DIR/derived/conversations/<id>/`;
5. `VAULT.json` last; then a dry run: a hard-linked scratch copy is rebuilt and re-rendered with
   providers that refuse to be called, and every migrated note must come out byte-identical.
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from . import legacy
from .notes.writer import generated_sha
from .records import record_from_row, write_record
from .settings import Settings
from .spool import atomic_write_bytes, safe_component
from .util import canonical_json, sha256_hex
from .vault import FORMAT, LEGACY_DB_NAME, Vault, new_vault_info

SEGMENT_CONTEXT = 5.0


class MigrationError(RuntimeError):
    pass


@dataclass
class MigrationReport:
    chunks: int = 0
    tombstones: int = 0
    seals: int = 0
    events: int = 0
    conversations: int = 0
    notes_checked: int = 0
    problems: list[str] = field(default_factory=list)
    mismatches: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.mismatches


def _backup(db_path: Path, target: Path) -> sqlite3.Connection:
    source = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    dest = sqlite3.connect(target)
    try:
        source.backup(dest)
    finally:
        source.close()
        dest.close()
    return legacy.open_legacy(target)


def _header_from_row(capture, chunk) -> dict:
    """An envelope header for a chunk whose bytes are gone (only what the index needs)."""
    from datetime import UTC, datetime

    started = datetime.fromtimestamp(capture["capture_started_at"], UTC).isoformat().replace("+00:00", "Z")
    header = {
        "schema_version": 1,
        "capture_id": chunk["capture_id"],
        "chunk_sequence": chunk["chunk_sequence"],
        "device_id": chunk["device_id"],
        "device_name": capture["device_name"],
        "model_number": capture["model_number"],
        "firmware_revision": capture["firmware_revision"],
        "hardware_revision": capture["hardware_revision"],
        "source": chunk["source"],
        "payload_format": capture["payload_format"],
        "codec_id": capture["codec_id"],
        "sample_rate": 16000,
        "channels": 1,
        "capture_started_at": started,
        "chunk_start_offset_us": chunk["start_offset_us"],
        "chunk_end_offset_us": chunk["end_offset_us"],
        "timezone": capture["timezone"],
        "record_count": 0,
        "payload_bytes": 0,
        "offline_storage": None if capture["offline_storage"] is None else bool(capture["offline_storage"]),
    }
    if capture["payload_format"] == "ring_records_v1":
        header["ring"] = {"first_sequence": 0, "record_size": 444, "dropped": capture["ring_dropped"]}
    return header


def _known_through(conn, row, gap: float) -> dict[str, int]:
    """Legacy `speech_watermark` (speech row ids) → known_through (chunk sequences per capture)."""
    watermark = row["speech_watermark"]
    if watermark is None:
        return {}
    lo, hi = row["start"] - gap - SEGMENT_CONTEXT, row["end"] + gap + SEGMENT_CONTEXT
    known: dict[str, int] = {}
    for cap in conn.execute(
        """SELECT DISTINCT s.capture_id FROM speech s WHERE s.device_id=? AND s.end >= ? AND s.start <= ?""",
        (row["device_id"], lo, hi),
    ).fetchall():
        capture_id = cap["capture_id"]
        stats = conn.execute(
            """SELECT MAX(CASE WHEN id <= ? THEN chunk_sequence END) AS known, MAX(id) AS newest
               FROM speech WHERE capture_id=?""",
            (watermark, capture_id),
        ).fetchone()
        if stats["known"] is None:
            continue
        capture = conn.execute("SELECT * FROM captures WHERE capture_id=?", (capture_id,)).fetchone()
        if capture["finalized"] and stats["newest"] <= watermark and capture["last_chunk_sequence"] is not None:
            known[capture_id] = capture["last_chunk_sequence"] + 1  # everything, the seal flush included
        else:
            known[capture_id] = stats["known"]
    return known


def migrate(settings: Settings, notes_dir: Path, data_dir: Path, vault_dir: Path, *, check: bool = True) -> MigrationReport:
    notes_dir, data_dir, vault_dir = notes_dir.expanduser(), data_dir.expanduser(), vault_dir.expanduser()
    db_path = data_dir / LEGACY_DB_NAME
    if not db_path.exists():
        raise MigrationError(f"no legacy database at {db_path}")
    vault = Vault(vault_dir)
    if vault.vault_json.exists():
        raise MigrationError(f"{vault_dir} is already a vault (_omi/VAULT.json exists)")
    if vault.omi.exists() and any(vault.omi.iterdir()):
        raise MigrationError(f"{vault.omi} exists (an interrupted migration?); move it away and run again")
    report = MigrationReport()
    with tempfile.TemporaryDirectory(prefix="omi-notes-migrate-") as tmp:
        conn = _backup(db_path, Path(tmp) / "legacy.sqlite3")
        try:
            if notes_dir.resolve() != vault_dir.resolve() and notes_dir.exists():
                shutil.copytree(notes_dir, vault_dir, dirs_exist_ok=True,
                                ignore=shutil.ignore_patterns(".DS_Store"))  # fmt: skip
            _raw(conn, data_dir, vault, report)
            _events(conn, vault, report)
            _conversations(conn, settings, data_dir, vault, report)
            vault.info = new_vault_info(settings) | {"format": FORMAT, "migrated_from": {"notes_dir": str(notes_dir),
                                                                                         "data_dir": str(data_dir)}}  # fmt: skip
            Vault.write_json(vault.vault_json, vault.info)
            if check:
                _check(conn, settings, vault, report)
        finally:
            conn.close()
    if not report.ok:
        vault.vault_json.unlink(missing_ok=True)  # leave the new vault invalid; the legacy install is untouched
    return report


def _raw(conn, data_dir: Path, vault: Vault, report: MigrationReport) -> None:
    captures = {r["capture_id"]: r for r in conn.execute("SELECT * FROM captures").fetchall()}
    deleted: dict[str, set[int]] = {}
    for chunk in conn.execute("SELECT * FROM chunks ORDER BY received_at, capture_id, chunk_sequence").fetchall():
        capture = captures[chunk["capture_id"]]
        device, capture_id, seq = chunk["device_id"], chunk["capture_id"], chunk["chunk_sequence"]
        if chunk["raw_deleted"]:
            tomb = {"sha256": chunk["sha256"], "size": chunk["size"], "header": _header_from_row(capture, chunk),
                    "deleted_at": None}  # fmt: skip
            Vault.write_json(vault.tombstone_path(device, capture_id, seq), tomb, pretty=False)
            deleted.setdefault(capture_id, set()).add(seq)
            report.tombstones += 1
        else:
            src = data_dir / "raw" / safe_component(device) / safe_component(capture_id) / f"{seq}.omnc"
            data = src.read_bytes()
            if sha256_hex(data) != chunk["sha256"]:
                raise MigrationError(f"{src} does not match its recorded sha256")
            atomic_write_bytes(vault.chunk_path(device, capture_id, seq), data)
            report.chunks += 1
        Vault.append_jsonl(vault.receipts_path(device, capture_id),
                           {"seq": seq, "sha256": chunk["sha256"], "received_at": chunk["received_at"]})  # fmt: skip
    for capture_id, capture in captures.items():
        if capture["seal_json"] is not None:
            body = json.loads(capture["seal_json"])
            if canonical_json(body) != capture["seal_json"]:
                raise MigrationError(f"seal of {capture_id} does not re-serialize to its stored bytes")
            Vault.write_json(vault.seal_path(capture["device_id"], capture_id),
                             {"body": body, "received_at": capture["sealed_at"]}, pretty=False)  # fmt: skip
            report.seals += 1
    for capture_id, seqs in deleted.items():
        capture = captures[capture_id]
        Vault.write_json(vault.capture_json_path(capture["device_id"], capture_id), _evidence(conn, capture, seqs))


def _evidence(conn, capture, seqs: set[int]) -> dict:
    capture_id = capture["capture_id"]
    marks = ",".join("?" * len(seqs))
    args = (capture_id, *sorted(seqs))
    rows = lambda sql: [list(r) for r in conn.execute(sql.format(marks=marks), args).fetchall()]  # noqa: E731
    deleted = {}
    for c in conn.execute(f"SELECT * FROM chunks WHERE capture_id=? AND chunk_sequence IN ({marks})", args).fetchall():
        seq = c["chunk_sequence"]
        deleted[str(seq)] = {
            "audio_start": c["audio_start"], "audio_end": c["audio_end"],
            "runs": json.loads(c["runs_json"] or "[]"), "stats": json.loads(c["stats_json"] or "{}"),
            "carry": json.loads(c["carry_json"]) if c["carry_json"] and seq + 1 not in seqs else None,
        }  # fmt: skip
    ring = rows("""SELECT chunk_sequence, ring_seq, record_hash FROM ring_seen WHERE capture_id=?
                   AND chunk_sequence IN ({marks}) ORDER BY ring_seq""")
    return {
        "capture_id": capture_id,
        "device_id": capture["device_id"],
        "finalized": bool(capture["finalized"]),
        "deleted": deleted,
        "coverage": rows("""SELECT chunk_sequence, kind, start, end FROM coverage WHERE capture_id=?
                            AND chunk_sequence IN ({marks}) AND kind IN ('live','ring') ORDER BY id"""),
        "losses": rows("""SELECT chunk_sequence, start, end, kind, count FROM losses WHERE capture_id=?
                          AND chunk_sequence IN ({marks}) AND kind <> 'ring_dropped' ORDER BY id"""),
        "ring_seen": ring,
        "ring_records": ring,
        "speech_open": rows("""SELECT chunk_sequence, start, end FROM speech WHERE capture_id=? AND open=1
                               AND chunk_sequence IN ({marks}) ORDER BY id"""),
    }


def _events(conn, vault: Vault, report: MigrationReport) -> None:
    for ev in conn.execute("SELECT * FROM events ORDER BY received_at, event_id").fetchall():
        Vault.append_jsonl(vault.events_path(ev["received_at"]),
                           {"event_id": ev["event_id"], "received_at": ev["received_at"], "body": json.loads(ev["body_json"])})  # fmt: skip
        report.events += 1


def _conversations(conn, settings: Settings, data_dir: Path, vault: Vault, report: MigrationReport) -> None:
    gap = settings.conversation_gap_seconds
    snapshot = json.dumps({"owner_name": settings.owner_name, "timezone": settings.timezone}, sort_keys=True)
    notes_root = vault.root
    for row in conn.execute("SELECT * FROM conversations WHERE status <> 'open' ORDER BY start").fetchall():
        values = dict(row)
        values["settings_json"] = snapshot if row["note_path"] else None
        values["frozen"] = 0
        values["written_sha"] = None
        if row["note_path"]:
            note = notes_root / row["note_path"]
            if note.exists():
                values["written_sha"] = generated_sha(note.read_text(encoding="utf-8"))
            else:
                report.problems.append(f"note {row['note_path']} of {row['id']} is missing; it will be written again")
        if values["status"] in ("transcribing", "summarizing"):
            values["status"] = "closed"
        src = data_dir / "derived" / "conversations" / row["id"]
        dest = vault.conversation_dir(row["id"])
        if src.exists():
            for path in sorted(src.iterdir()):
                if path.is_file():
                    atomic_write_bytes(dest / path.name, path.read_bytes())
        write_record(vault, record_from_row(values, _known_through(conn, row, gap)))
        report.conversations += 1


class _Refuse:
    """Providers for the dry run: rebuilding and re-rendering must never call one."""

    def __getattr__(self, name):
        raise MigrationError(f"the migration check tried to use a provider ({name})")


def _check(conn, settings: Settings, vault: Vault, report: MigrationReport) -> None:
    """Rebuild a hard-linked scratch copy and re-render it without providers; every migrated
    note must be byte-identical and the conversation set the same."""
    from .pipeline.worker import Worker
    from .rebuild import open_index

    with tempfile.TemporaryDirectory(prefix="omi-notes-migrate-check-") as tmp:
        scratch = Path(tmp) / "vault"

        def link_raw(src: str, dst: str) -> None:
            # Raw envelopes are hard-linked (never written in place); everything else is copied,
            # since the check may rewrite or append to it.
            if src.endswith(".omnc"):
                os.link(src, dst)
            else:
                shutil.copy2(src, dst)

        shutil.copytree(vault.root, scratch, copy_function=link_raw)
        check_settings = settings.model_copy(update={"vault_dir": scratch, "index_dir": Path(tmp) / "index",
                                                     "notes_dir": None, "data_dir": None})  # fmt: skip
        db = open_index(check_settings, Vault.open(check_settings, create=False), sweep_orphans=False)
        from .pipeline.conversations import Providers

        providers = Providers(check_settings)
        providers._stt = providers._llm = _Refuse()  # type: ignore[assignment]
        providers._diarizer = False
        worker = Worker(check_settings, db, providers=providers)
        now = max((r["updated_at"] or 0) for r in conn.execute("SELECT updated_at FROM conversations").fetchall()) \
            if conn.execute("SELECT COUNT(*) FROM conversations").fetchone()[0] else 0.0
        for _ in range(50):
            result = worker.tick(now)
            if not worker.replaying and not db.one("SELECT 1 FROM conversations WHERE needs_render=1"):
                if not result["chunks"] and not result["conversations"]:
                    break
        legacy_rows = {r["id"]: r for r in conn.execute("SELECT * FROM conversations WHERE status <> 'open'").fetchall()}
        rebuilt = {r["id"]: r for r in db.query("SELECT * FROM conversations WHERE status <> 'open'")}
        missing = set(legacy_rows) - set(rebuilt)
        if missing:
            report.mismatches.append(f"conversations missing after the rebuild: {sorted(missing)[:5]}")
        for conv_id, old in legacy_rows.items():
            new = rebuilt.get(conv_id)
            if new is None:
                continue
            for column in ("start", "end", "note_path"):
                if old[column] != new[column]:
                    report.mismatches.append(f"{conv_id}: {column} {old[column]!r} → {new[column]!r}")
            status = old["status"] if old["status"] not in ("transcribing", "summarizing") else "closed"
            if status != new["status"]:
                report.mismatches.append(f"{conv_id}: status {status} → {new['status']}")
            if old["note_path"]:
                original = vault.root / old["note_path"]
                rendered = scratch / old["note_path"]
                if original.exists() and rendered.exists() and original.read_bytes() != rendered.read_bytes():
                    report.mismatches.append(f"{old['note_path']} renders differently from the vault")
                report.notes_checked += 1
        db.close()
