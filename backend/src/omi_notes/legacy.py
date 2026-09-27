"""The pre-vault SQLite ledger (`DATA_DIR/omi-notes.sqlite3`), read only by `omi-notes migrate-vault`.

Its migrations are kept verbatim so a ledger of any older version can be brought to the last
pre-vault schema (on a copy) before it is exported into a vault.
"""

from __future__ import annotations

import json
import sqlite3
from collections.abc import Callable
from pathlib import Path

_SQL_MIGRATIONS: list[str] = [
    # 1: initial schema
    """
    CREATE TABLE captures (
        capture_id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        source TEXT NOT NULL,
        payload_format TEXT,
        codec_id INTEGER,
        capture_started_at REAL,
        offline_storage INTEGER,
        device_name TEXT,
        model_number TEXT,
        firmware_revision TEXT,
        hardware_revision TEXT,
        timezone TEXT,
        created_at REAL NOT NULL,
        seal_json TEXT,
        seal_reason TEXT,
        last_chunk_sequence INTEGER,
        sealed_at REAL,
        ended_at REAL,
        ring_covers_until REAL,
        ring_activated INTEGER NOT NULL DEFAULT 0,
        processed_through INTEGER NOT NULL DEFAULT -1
    );
    CREATE INDEX captures_device ON captures(device_id);

    CREATE TABLE chunks (
        capture_id TEXT NOT NULL,
        chunk_sequence INTEGER NOT NULL,
        device_id TEXT NOT NULL,
        source TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        size INTEGER NOT NULL,
        path TEXT NOT NULL,
        received_at REAL NOT NULL,
        start_epoch REAL NOT NULL,
        end_epoch REAL NOT NULL,
        start_offset_us INTEGER NOT NULL,
        end_offset_us INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at REAL,
        error TEXT,
        processed_at REAL,
        audio_start REAL,
        audio_end REAL,
        carry_json TEXT,
        runs_json TEXT,
        stats_json TEXT,
        raw_deleted INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (capture_id, chunk_sequence)
    );
    CREATE INDEX chunks_status ON chunks(status);
    CREATE INDEX chunks_device_audio ON chunks(device_id, audio_start);

    CREATE TABLE speech (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT NOT NULL,
        start REAL NOT NULL,
        end REAL NOT NULL,
        capture_id TEXT NOT NULL,
        chunk_sequence INTEGER NOT NULL,
        claimed_by TEXT
    );
    CREATE INDEX speech_device ON speech(device_id, claimed_by, start);
    CREATE INDEX speech_chunk ON speech(capture_id, chunk_sequence);

    -- live/ring rows are inserted when their chunk is processed (active by construction);
    -- heartbeat rows become active once their capture is processed through requires_chunk.
    CREATE TABLE coverage (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        start REAL,
        end REAL,
        capture_id TEXT,
        chunk_sequence INTEGER,
        through_offset_us INTEGER,
        requires_chunk INTEGER,
        event_id TEXT
    );
    CREATE INDEX coverage_device ON coverage(device_id);
    CREATE INDEX coverage_chunk ON coverage(capture_id, chunk_sequence);

    CREATE TABLE events (
        event_id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        type TEXT NOT NULL,
        at REAL NOT NULL,
        capture_id TEXT,
        offset_us INTEGER,
        code INTEGER,
        body_json TEXT NOT NULL,
        received_at REAL NOT NULL,
        applied INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX events_device ON events(device_id, type);

    CREATE TABLE devices (
        device_id TEXT PRIMARY KEY,
        device_name TEXT,
        model_number TEXT,
        firmware_revision TEXT,
        last_seen REAL,
        heartbeat_json TEXT
    );

    CREATE TABLE ring_seen (
        device_id TEXT NOT NULL,
        ring_seq INTEGER NOT NULL,
        record_hash TEXT NOT NULL,
        capture_id TEXT NOT NULL,
        chunk_sequence INTEGER NOT NULL,
        PRIMARY KEY (device_id, ring_seq, record_hash)
    );

    CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        start REAL NOT NULL,
        end REAL NOT NULL,
        status TEXT NOT NULL,
        provisional INTEGER NOT NULL DEFAULT 0,
        late_audio INTEGER NOT NULL DEFAULT 0,
        related_id TEXT,
        start_explicit INTEGER NOT NULL DEFAULT 0,
        end_explicit INTEGER NOT NULL DEFAULT 0,
        speech_watermark INTEGER,
        speech_seconds REAL NOT NULL DEFAULT 0,
        gaps_json TEXT NOT NULL DEFAULT '[]',
        blocks_json TEXT NOT NULL DEFAULT '[]',
        speech_ids_json TEXT NOT NULL DEFAULT '[]',
        waiting_for TEXT,
        sources_json TEXT NOT NULL DEFAULT '[]',
        title TEXT,
        index_json TEXT,
        note_path TEXT,
        stub_path TEXT,
        revision INTEGER NOT NULL DEFAULT 0,
        content_sha TEXT,
        needs_render INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at REAL,
        error TEXT,
        error_kind TEXT,
        failed_stage TEXT,
        audio_sha TEXT,
        stt_ref TEXT,
        transcript_sha TEXT,
        llm_ref TEXT,
        llm_status TEXT,
        relevance TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        finalized_at REAL,
        done_at REAL
    );
    CREATE INDEX conversations_status ON conversations(status);
    CREATE INDEX conversations_device ON conversations(device_id, start);
    """,
    # 2: review fixes — normalized seal values, ring evidence, final flush, open (in-progress)
    # speech rows, explicit losses, persisted dirty days, work claims, per-note render inputs.
    """
    ALTER TABLE captures ADD COLUMN seal_end_offset_us INTEGER;
    ALTER TABLE captures ADD COLUMN ring_generation INTEGER;
    ALTER TABLE captures ADD COLUMN ring_info_read_seq INTEGER;
    ALTER TABLE captures ADD COLUMN ring_dropped INTEGER;
    ALTER TABLE captures ADD COLUMN finalized INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE captures DROP COLUMN ring_activated;
    ALTER TABLE speech ADD COLUMN open INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE conversations ADD COLUMN claim_token TEXT;
    ALTER TABLE conversations ADD COLUMN claim_expires REAL;
    ALTER TABLE conversations ADD COLUMN prompt_version INTEGER;
    ALTER TABLE conversations ADD COLUMN language TEXT;
    ALTER TABLE conversations ADD COLUMN clock_suspect INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE conversations ADD COLUMN lost_seconds REAL NOT NULL DEFAULT 0;
    ALTER TABLE conversations ADD COLUMN stale_note_path TEXT;
    ALTER TABLE conversations ADD COLUMN force_restt INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE conversations ADD COLUMN force_llm INTEGER NOT NULL DEFAULT 0;

    CREATE TABLE losses (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT NOT NULL,
        start REAL NOT NULL,
        end REAL NOT NULL,
        kind TEXT NOT NULL,
        count INTEGER NOT NULL DEFAULT 0,
        capture_id TEXT NOT NULL,
        chunk_sequence INTEGER NOT NULL
    );
    CREATE INDEX losses_device ON losses(device_id, start);
    CREATE INDEX losses_chunk ON losses(capture_id, chunk_sequence);

    CREATE TABLE dirty_days (day TEXT PRIMARY KEY);

    -- Monotonic (capture-relative) times; raw wall-clock values only when no anchor is known.
    CREATE VIEW capture_times AS
        SELECT *, COALESCE(capture_started_at + seal_end_offset_us / 1e6, ended_at) AS seal_end FROM captures;
    CREATE VIEW event_times AS
        SELECT e.*, COALESCE(k.capture_started_at + e.offset_us / 1e6, e.at) AS t
        FROM events e LEFT JOIN captures k ON k.capture_id = e.capture_id;
    """,
]


def _legacy_int(value: object) -> int | None:
    """Integers as schema v1 accepted them (it coerced numeric strings); anything else is None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


def _migration_3(conn: sqlite3.Connection) -> None:
    """Reprocess requests and dropped-record reconciliation state; backfill the normalized seal
    columns that schema v2 added but left empty for captures sealed before it."""
    for statement in (
        "ALTER TABLE conversations ADD COLUMN reprocess_request INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE conversations ADD COLUMN reprocess_handled INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE captures ADD COLUMN dropped_reconciled INTEGER NOT NULL DEFAULT 0",
        # v2 queued `reprocess` work only as force flags: turn it into pending requests.
        "UPDATE conversations SET reprocess_request = 1 WHERE force_restt = 1 OR force_llm = 1",
    ):
        conn.execute(statement)
    rows = conn.execute(
        "SELECT capture_id, seal_json, last_chunk_sequence, processed_through FROM captures WHERE seal_json IS NOT NULL"
    ).fetchall()
    for capture_id, seal_json, last, processed in rows:
        try:
            seal = json.loads(seal_json)
        except json.JSONDecodeError:
            continue
        ring = seal.get("ring") if isinstance(seal.get("ring"), dict) else {}
        offset = _legacy_int(seal.get("end_offset_us"))
        values = {
            "seal_end_offset_us": offset if offset is not None and offset >= 0 else None,
            "ring_generation": _legacy_int(ring.get("generation")),
            "ring_info_read_seq": _legacy_int(ring.get("info_read_seq")),
            "ring_dropped": _legacy_int(ring.get("dropped")),
        }
        # Only fill what is missing: values written by the v2 ingest are already validated.
        sets = ", ".join(f"{column} = COALESCE({column}, ?)" for column in values)
        conn.execute(f"UPDATE captures SET {sets} WHERE capture_id=?", (*values.values(), capture_id))
        if last is not None and processed is not None and processed >= last:
            final = conn.execute(
                "SELECT stats_json FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, last)
            ).fetchone()
            if last < 0 or (final and json.loads(final[0] or "{}").get("final")):
                conn.execute("UPDATE captures SET finalized=1 WHERE capture_id=?", (capture_id,))


def _migration_4(conn: sqlite3.Connection) -> None:
    """Repair databases that ran an earlier migration 3 which didn't convert v2 force flags: a force
    flag without a pending request would never be picked up (consuming a request clears the flags,
    so a set flag always means unfinished work)."""
    conn.execute(
        """UPDATE conversations SET reprocess_request = reprocess_handled + 1
           WHERE (force_restt = 1 OR force_llm = 1) AND reprocess_request <= reprocess_handled"""
    )


# Applied in order; `PRAGMA user_version` records how many have run.
MIGRATIONS: list[str | Callable[[sqlite3.Connection], None]] = [*_SQL_MIGRATIONS, _migration_3, _migration_4]




def open_legacy(path: Path) -> sqlite3.Connection:
    """A connection to an upgraded *copy* of a legacy ledger (the original is never modified)."""
    conn = sqlite3.connect(path, isolation_level=None)
    conn.row_factory = sqlite3.Row
    upgrade(conn)
    return conn


def upgrade(conn: sqlite3.Connection) -> None:
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    for index in range(version, len(MIGRATIONS)):
        step = MIGRATIONS[index]
        if isinstance(step, str):
            conn.executescript("BEGIN IMMEDIATE;" + step + f"; PRAGMA user_version={index + 1}; COMMIT;")
            continue
        conn.execute("BEGIN IMMEDIATE")
        try:
            step(conn)
            conn.execute(f"PRAGMA user_version={index + 1}")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
        conn.execute("COMMIT")
