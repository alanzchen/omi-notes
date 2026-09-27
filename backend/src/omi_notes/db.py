"""The operational SQLite index (WAL, `synchronous=FULL`), kept outside the vault (docs/vault.md).

Everything permanent is a file in the vault; this database is a queue plus a cache of file facts
and is rebuilt from the vault (`rebuild.py`) whenever it is missing or its `meta` does not match
(schema version, vault id, vault path). There are no migrations: a schema change bumps
`SCHEMA_VERSION` and the next start rebuilds.

Every column has a declared source in `COLUMN_SOURCES` (a vault file, or "operational" with what
rebuilds it); `tests/test_vault_rebuild.py` fails when a column lacks one.

Status columns are queue positions, not locks: a crash mid-stage just redoes that (idempotent,
cached) stage.
"""

from __future__ import annotations

import sqlite3
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from .spool import make_dirs_durable

SCHEMA_VERSION = 5

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

CREATE TABLE IF NOT EXISTS captures (
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
    seal_end_offset_us INTEGER,
    ring_covers_until REAL,
    ring_generation INTEGER,
    ring_info_read_seq INTEGER,
    ring_dropped INTEGER,
    processed_through INTEGER NOT NULL DEFAULT -1,
    finalized INTEGER NOT NULL DEFAULT 0,
    dropped_reconciled INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS captures_device ON captures(device_id);

CREATE TABLE IF NOT EXISTS chunks (
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
CREATE INDEX IF NOT EXISTS chunks_status ON chunks(status);
CREATE INDEX IF NOT EXISTS chunks_device_audio ON chunks(device_id, audio_start);

-- Every ring record each received chunk contains (for the order-independent ownership rule).
CREATE TABLE IF NOT EXISTS ring_records (
    device_id TEXT NOT NULL,
    ring_seq INTEGER NOT NULL,
    record_hash TEXT NOT NULL,
    capture_id TEXT NOT NULL,
    chunk_sequence INTEGER NOT NULL,
    received_at REAL NOT NULL,
    PRIMARY KEY (capture_id, chunk_sequence, ring_seq)
);
CREATE INDEX IF NOT EXISTS ring_records_record ON ring_records(device_id, ring_seq, record_hash);

CREATE TABLE IF NOT EXISTS speech (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL,
    start REAL NOT NULL,
    end REAL NOT NULL,
    capture_id TEXT NOT NULL,
    chunk_sequence INTEGER NOT NULL,
    claimed_by TEXT,
    open INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS speech_device ON speech(device_id, claimed_by, start);
CREATE INDEX IF NOT EXISTS speech_chunk ON speech(capture_id, chunk_sequence);

-- live/ring rows are inserted when their chunk is processed (active by construction);
-- heartbeat rows become active once their capture is processed through requires_chunk.
CREATE TABLE IF NOT EXISTS coverage (
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
CREATE INDEX IF NOT EXISTS coverage_device ON coverage(device_id);
CREATE INDEX IF NOT EXISTS coverage_chunk ON coverage(capture_id, chunk_sequence);

CREATE TABLE IF NOT EXISTS events (
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
CREATE INDEX IF NOT EXISTS events_device ON events(device_id, type);

CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY,
    device_name TEXT,
    model_number TEXT,
    firmware_revision TEXT,
    last_seen REAL,
    heartbeat_json TEXT
);

CREATE TABLE IF NOT EXISTS ring_seen (
    device_id TEXT NOT NULL,
    ring_seq INTEGER NOT NULL,
    record_hash TEXT NOT NULL,
    capture_id TEXT NOT NULL,
    chunk_sequence INTEGER NOT NULL,
    PRIMARY KEY (device_id, ring_seq, record_hash)
);

CREATE TABLE IF NOT EXISTS losses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL,
    start REAL NOT NULL,
    end REAL NOT NULL,
    kind TEXT NOT NULL,
    count INTEGER NOT NULL DEFAULT 0,
    capture_id TEXT NOT NULL,
    chunk_sequence INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS losses_device ON losses(device_id, start);
CREATE INDEX IF NOT EXISTS losses_chunk ON losses(capture_id, chunk_sequence);

CREATE TABLE IF NOT EXISTS dirty_days (day TEXT PRIMARY KEY);

CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    start REAL NOT NULL,
    end REAL NOT NULL,
    status TEXT NOT NULL,
    provisional INTEGER NOT NULL DEFAULT 0,
    late_audio INTEGER NOT NULL DEFAULT 0,
    related_id TEXT,
    enrollment_id TEXT,
    start_explicit INTEGER NOT NULL DEFAULT 0,
    end_explicit INTEGER NOT NULL DEFAULT 0,
    speech_seconds REAL NOT NULL DEFAULT 0,
    gaps_json TEXT NOT NULL DEFAULT '[]',
    blocks_json TEXT NOT NULL DEFAULT '[]',
    sources_json TEXT NOT NULL DEFAULT '[]',
    lost_seconds REAL NOT NULL DEFAULT 0,
    clock_suspect INTEGER NOT NULL DEFAULT 0,
    waiting_for TEXT,
    settings_json TEXT,
    title TEXT,
    index_json TEXT,
    note_path TEXT,
    stale_note_path TEXT,
    stub_path TEXT,
    revision INTEGER NOT NULL DEFAULT 0,
    content_sha TEXT,
    written_sha TEXT,
    frozen INTEGER NOT NULL DEFAULT 0,
    edited INTEGER NOT NULL DEFAULT 0,
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
    prompt_version INTEGER,
    language TEXT,
    force_restt INTEGER NOT NULL DEFAULT 0,
    force_llm INTEGER NOT NULL DEFAULT 0,
    skip_stt TEXT,
    skip_llm TEXT,
    reprocess_request INTEGER NOT NULL DEFAULT 0,
    reprocess_handled INTEGER NOT NULL DEFAULT 0,
    claim_token TEXT,
    claim_expires REAL,
    record_sha TEXT,
    speakers_revision INTEGER NOT NULL DEFAULT 0,
    rendered_speakers_revision INTEGER,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    finalized_at REAL,
    done_at REAL
);
CREATE INDEX IF NOT EXISTS conversations_status ON conversations(status);
CREATE INDEX IF NOT EXISTS conversations_device ON conversations(device_id, start);

-- decision.known_through: speech from (capture, seq) is known to a finalized conversation iff
-- seq <= known_through[capture] (the seal flush is virtual chunk last + 1).
CREATE TABLE IF NOT EXISTS known_through (
    conversation_id TEXT NOT NULL,
    capture_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    PRIMARY KEY (conversation_id, capture_id)
);
CREATE INDEX IF NOT EXISTS known_through_capture ON known_through(capture_id);

-- Speaker learning (docs/speaker-learning.md): caches of People notes and `_omi/people/`,
-- `_omi/conversations/*/<id>/voices-*.json` and `speakers.json`.
CREATE TABLE IF NOT EXISTS people (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    me INTEGER NOT NULL DEFAULT 0,
    note_path TEXT,
    aliases_json TEXT NOT NULL DEFAULT '[]',
    attested_at REAL
);
CREATE TABLE IF NOT EXISTS samples (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    model TEXT NOT NULL,
    model_sha TEXT NOT NULL,
    vector BLOB NOT NULL,
    source TEXT NOT NULL,
    seconds REAL,
    day TEXT,
    session TEXT,
    conversation_id TEXT,
    label TEXT,
    request_id TEXT,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS samples_person ON samples(person_id);
CREATE INDEX IF NOT EXISTS samples_request ON samples(request_id);
CREATE TABLE IF NOT EXISTS voices (
    conversation_id TEXT NOT NULL,
    label TEXT NOT NULL,
    file TEXT NOT NULL,
    model TEXT NOT NULL,
    model_sha TEXT NOT NULL,
    vector BLOB,
    seconds REAL NOT NULL,
    turns INTEGER NOT NULL,
    spread REAL NOT NULL DEFAULT 0,
    rms_db REAL,
    clips_json TEXT NOT NULL,
    PRIMARY KEY (conversation_id, label)
);
CREATE TABLE IF NOT EXISTS speaker_labels (
    conversation_id TEXT NOT NULL,
    label TEXT NOT NULL,
    person_id TEXT,
    source TEXT,
    distance REAL,
    margin REAL,
    evidence_s REAL,
    not_json TEXT NOT NULL DEFAULT '[]',
    forgotten INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (conversation_id, label)
);
CREATE INDEX IF NOT EXISTS speaker_labels_person ON speaker_labels(person_id);

-- Monotonic (capture-relative) times; raw wall-clock values only when no anchor is known.
CREATE VIEW IF NOT EXISTS capture_times AS
    SELECT *, COALESCE(capture_started_at + seal_end_offset_us / 1e6, ended_at) AS seal_end FROM captures;
CREATE VIEW IF NOT EXISTS event_times AS
    SELECT e.*, COALESCE(k.capture_started_at + e.offset_us / 1e6, e.at) AS t
    FROM events e LEFT JOIN captures k ON k.capture_id = e.capture_id;
"""

_SEAL = "raw/<dev>/<cap>/seal.json"
_HEADER = "chunk envelope header (or <seq>.gone tombstone header)"
_REPLAY = "operational — rebuilt by replaying surviving raw chunks"
_CAPTURE_JSON = "raw/<dev>/<cap>/capture.json evidence for deleted chunks"

# table -> column -> where its value comes from on a rebuild.
COLUMN_SOURCES: dict[str, dict[str, str]] = {
    "meta": {
        "key": "operational — written by the rebuild (schema_version, vault_id, vault_path, complete, replay_pending, read_only)",
        "value": "operational — see key",
    },
    "captures": {
        "capture_id": "raw/<dev>/<cap>/ directory name",
        "device_id": "raw/<dev>/ directory (= envelope header / seal device_id)",
        "source": f"{_HEADER} / {_SEAL}",
        "payload_format": _HEADER,
        "codec_id": _HEADER,
        "capture_started_at": _HEADER,
        "offline_storage": _HEADER,
        "device_name": _HEADER,
        "model_number": _HEADER,
        "firmware_revision": _HEADER,
        "hardware_revision": _HEADER,
        "timezone": _HEADER,
        "created_at": "earliest received_at in receipts.jsonl / seal.json",
        "seal_json": f"{_SEAL} body",
        "seal_reason": f"{_SEAL} body",
        "last_chunk_sequence": f"{_SEAL} body",
        "sealed_at": f"{_SEAL} received_at",
        "ended_at": f"{_SEAL} body",
        "seal_end_offset_us": f"{_SEAL} body",
        "ring_covers_until": f"{_SEAL} body",
        "ring_generation": f"{_SEAL} body",
        "ring_info_read_seq": f"{_SEAL} body",
        "ring_dropped": f"{_HEADER} ring.dropped, else {_SEAL} (applied in receipt order)",
        "processed_through": f"{_REPLAY} (deleted prefix: tombstones)",
        "finalized": f"{_REPLAY} (seal flush; {_CAPTURE_JSON} when the last chunk is deleted)",
        "dropped_reconciled": "operational — 1 when both seals are present and recorded losses match (reconcile_dropped)",
    },
    "chunks": {
        "capture_id": "raw/<dev>/<cap>/",
        "chunk_sequence": "<seq>.omnc / <seq>.gone file name",
        "device_id": _HEADER,
        "source": _HEADER,
        "sha256": "sha256 of <seq>.omnc (tombstone sha256 when deleted)",
        "size": "<seq>.omnc size (tombstone size when deleted)",
        "path": "vault-relative path of <seq>.omnc",
        "received_at": "raw/<dev>/<cap>/receipts.jsonl",
        "start_epoch": _HEADER,
        "end_epoch": _HEADER,
        "start_offset_us": _HEADER,
        "end_offset_us": _HEADER,
        "status": f"{_REPLAY}; tombstoned chunks are 'processed'",
        "attempts": "operational — retry counter, reset by a rebuild",
        "next_attempt_at": "operational — backoff, reset by a rebuild",
        "error": "operational — last processing error",
        "processed_at": _REPLAY,
        "audio_start": f"{_REPLAY}; {_CAPTURE_JSON}",
        "audio_end": f"{_REPLAY}; {_CAPTURE_JSON}",
        "carry_json": f"{_REPLAY}; {_CAPTURE_JSON} (continuation checkpoints)",
        "runs_json": f"{_REPLAY}; {_CAPTURE_JSON}",
        "stats_json": f"{_REPLAY}; {_CAPTURE_JSON}",
        "raw_deleted": "<seq>.gone tombstone present",
    },
    "ring_records": {
        "device_id": _HEADER,
        "ring_seq": "ring records in <seq>.omnc; capture.json ring evidence for deleted chunks",
        "record_hash": "sha1 of each ring record in <seq>.omnc; capture.json ring evidence",
        "capture_id": "raw/<dev>/<cap>/",
        "chunk_sequence": "<seq>.omnc",
        "received_at": "receipts.jsonl",
    },
    "speech": {c: _REPLAY for c in ("id", "device_id", "start", "end", "capture_id", "chunk_sequence", "open")}
    | {"claimed_by": "operational — from conversation.json decision.known_through (segmentation re-claims)"},
    "coverage": {
        c: f"{_REPLAY} (live/ring); _omi/events/*.jsonl heartbeats; {_CAPTURE_JSON}"
        for c in ("id", "device_id", "kind", "start", "end", "capture_id", "chunk_sequence", "through_offset_us",
                  "requires_chunk", "event_id")
    },
    "events": {
        c: "_omi/events/YYYY-MM-DD.jsonl line (event_id, received_at, body)"
        for c in ("event_id", "device_id", "type", "at", "capture_id", "offset_us", "code", "body_json", "received_at")
    }
    | {"applied": "operational — late-event application is idempotent and re-run"},
    "devices": {
        c: "envelope headers, seals and events applied in received_at order"
        for c in ("device_id", "device_name", "model_number", "firmware_revision", "last_seen", "heartbeat_json")
    },
    "ring_seen": {
        c: f"{_REPLAY}; {_CAPTURE_JSON}" for c in ("device_id", "ring_seq", "record_hash", "capture_id", "chunk_sequence")
    },
    "losses": {
        c: f"{_REPLAY}; {_CAPTURE_JSON}; ring_dropped rows by reconcile_dropped"
        for c in ("id", "device_id", "start", "end", "kind", "count", "capture_id", "chunk_sequence")
    },
    "dirty_days": {"day": "operational — every day with a conversation is queued after a rebuild"},
    "conversations": {
        "id": "_omi/conversations/YYYY-MM/<id>/ (open conversations: operational, recomputed)",
        **{c: "conversation.json decision" for c in (
            "device_id", "start", "end", "provisional", "late_audio", "related_id", "start_explicit", "end_explicit",
            "speech_seconds", "gaps_json", "blocks_json", "sources_json", "lost_seconds", "clock_suspect", "finalized_at",
            "enrollment_id",
        )},  # fmt: skip
        "status": "derived: no render → closed; render.kind → done/discarded; decision.enrollment_id → discarded; "
                  "failure → failed (open: operational)",
        "waiting_for": "operational — open conversations only",
        "settings_json": "conversation.json settings (snapshot of render-affecting settings)",
        **{c: "conversation.json render" for c in (
            "title", "index_json", "note_path", "stale_note_path", "revision", "content_sha", "written_sha", "frozen",
            "audio_sha", "stt_ref", "transcript_sha", "llm_ref", "llm_status", "relevance", "prompt_version",
            "language", "done_at",
        )},  # fmt: skip
        "rendered_speakers_revision": "conversation.json render.speakers_revision (the labels the note shows)",
        "error": "conversation.json failure (else operational: last re-render error)",
        "error_kind": "conversation.json failure (else operational)",
        "failed_stage": "conversation.json failure",
        "stub_path": "operational — stubs are re-rendered",
        "edited": "operational — recomputed from the note file vs written_sha before each re-render",
        "needs_render": "operational — set for every rendered record by a rebuild",
        "attempts": "operational — reset by a rebuild",
        "next_attempt_at": "operational — reset by a rebuild",
        "force_restt": "operational — pending `reprocess --restt` request",
        "force_llm": "operational — pending `reprocess --force-llm` request",
        "skip_stt": "operational — STT results a forced reprocess must not reuse",
        "skip_llm": "operational — LLM results a forced reprocess must not reuse",
        "reprocess_request": "operational — request counter",
        "reprocess_handled": "operational — request counter",
        "claim_token": "operational — work claim",
        "claim_expires": "operational — work claim",
        "record_sha": "operational — sha256 of conversation.json as last written/applied",
        "speakers_revision": "<conversation dir>/speakers.json revision",
        "created_at": "operational",
        "updated_at": "operational",
    },
    "people": {
        "id": "People/*.md frontmatter omi_person_id (or an _omi/people/<id>/ folder without a note)",
        "name": "People note file name (else the name recorded with its samples)",
        "me": "People note frontmatter omi_me",
        "note_path": "vault-relative path of the People note",
        "aliases_json": "People note frontmatter aliases",
        "attested_at": "_omi/people/<id>/consent.json",
    },
    "samples": {
        c: "_omi/people/<person_id>/samples/<sample_id>.json"
        for c in ("id", "person_id", "model", "model_sha", "vector", "source", "seconds", "day", "session",
                  "conversation_id", "label", "request_id", "created_at")
    },
    "voices": {
        c: "<conversation dir>/voices-<model>-<audio_sha16>.json" for c in (
            "conversation_id", "label", "file", "model", "model_sha", "vector", "seconds", "turns", "spread", "rms_db",
            "clips_json")
    },  # fmt: skip
    "speaker_labels": {
        c: "<conversation dir>/speakers.json labels"
        for c in ("conversation_id", "label", "person_id", "source", "distance", "margin", "evidence_s", "not_json",
                  "forgotten")
    },
    "known_through": {
        "conversation_id": "conversation.json id",
        "capture_id": "conversation.json decision.known_through key",
        "seq": "conversation.json decision.known_through value",
    },
}


class Database:
    """Thread-local SQLite connections to one index file (the schema is created if missing)."""

    def __init__(self, path: Path) -> None:
        self.path = path
        make_dirs_durable(path.parent)
        self._local = threading.local()
        conn = self.conn()
        conn.executescript(SCHEMA)
        conn.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?)", (str(SCHEMA_VERSION),))

    def conn(self) -> sqlite3.Connection:
        conn = getattr(self._local, "conn", None)
        if conn is None:
            conn = sqlite3.connect(self.path, isolation_level=None, timeout=30.0, check_same_thread=False)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            # FULL: a committed ingest row must survive power loss before we answer 2xx.
            conn.execute("PRAGMA synchronous=FULL")
            conn.execute("PRAGMA foreign_keys=ON")
            conn.execute("PRAGMA busy_timeout=30000")
            self._local.conn = conn
        return conn

    @contextmanager
    def tx(self) -> Iterator[sqlite3.Connection]:
        """`BEGIN IMMEDIATE` … `COMMIT` (rolled back on exception). Nested use joins the outer one."""
        conn = self.conn()
        if conn.in_transaction:
            yield conn
            return
        conn.execute("BEGIN IMMEDIATE")
        try:
            yield conn
        except BaseException:
            conn.execute("ROLLBACK")
            raise
        conn.execute("COMMIT")

    def query(self, sql: str, params: tuple | dict = ()) -> list[sqlite3.Row]:
        return self.conn().execute(sql, params).fetchall()

    def one(self, sql: str, params: tuple | dict = ()) -> sqlite3.Row | None:
        return self.conn().execute(sql, params).fetchone()

    def execute(self, sql: str, params: tuple | dict = ()) -> sqlite3.Cursor:
        return self.conn().execute(sql, params)

    def meta(self, key: str) -> str | None:
        row = self.one("SELECT value FROM meta WHERE key=?", (key,))
        return row["value"] if row else None

    def set_meta(self, key: str, value: str | None) -> None:
        if value is None:
            self.execute("DELETE FROM meta WHERE key=?", (key,))
        else:
            self.execute("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                         (key, value))  # fmt: skip

    def close(self) -> None:
        conn = getattr(self._local, "conn", None)
        if conn is not None:
            conn.close()
            self._local.conn = None
