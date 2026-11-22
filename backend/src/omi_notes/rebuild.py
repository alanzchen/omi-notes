"""Build the operational index from the vault; index orphan files at startup (docs/vault.md, "Rebuild").

`open_index` is how every process gets its database: it uses the existing index when its `meta`
matches this vault (schema version, vault id, real path, complete) and rebuilds it otherwise.

A rebuild reads files only (zero provider calls, no vault writes):
1. raw captures: chunks (`pending`; tombstoned ones `processed` + `raw_deleted`), seals,
   receipts and `capture.json` evidence for deleted chunks;
2. events (deduplicated by id, first line wins; a conflicting body is reported);
3. conversation records (status derived from their blocks);
4. validation: a record that references a chunk or result that is neither present nor tombstoned
   opens the vault read-only ("incomplete sync is not an empty vault");
then `meta.replay_pending` makes the worker replay every surviving chunk through the normal
`process_chunks` before segmentation and loss refreshes run again, and every rendered record is
queued for a cache-only re-render.
"""

from __future__ import annotations

import fcntl
import json
import sqlite3
import logging
import os
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

from .db import SCHEMA_VERSION, Database
from .envelope import EnvelopeError, parse_envelope
from .ingest import (
    ApiError,
    index_chunk,
    index_event,
    index_seal,
    ring_record_hashes,
    tombstone_header,
    validate_event,
    validate_seal,
)
from .records import load_records, row_from_record
from .settings import Settings
from . import spool
from .spool import fsync_dir
from .util import canonical_json, sha256_hex
from .vault import Vault, index_dir

log = logging.getLogger(__name__)

# The publication rule an index was built under (meta `publication_contract`). An index without it (or older) trusted
# files by existence; it is rebuilt once, confirming every file and its chain, before any of its rows is trusted
# (ASTRA-20261122-DESIGN-02). Only a complete build stamps it.
PUBLICATION_CONTRACT = "1"


@dataclass
class Report:
    chunks: int = 0
    tombstones: int = 0
    seals: int = 0
    events: int = 0
    conversations: int = 0
    problems: list[str] = field(default_factory=list)  # reported, not fatal
    gaps: list[str] = field(default_factory=list)  # missing dependencies ⇒ read-only
    unresolved: list[str] = field(default_factory=list)  # captures whose files couldn't be confirmed: not indexed yet

    @property
    def read_only_reason(self) -> str | None:
        if not self.gaps:
            return None
        more = f" (and {len(self.gaps) - 5} more)" if len(self.gaps) > 5 else ""
        return "incomplete vault: " + "; ".join(self.gaps[:5]) + more


# -- scanning --------------------------------------------------------------------------------------


@dataclass
class _Op:
    received_at: float
    rank: int  # chunks before seals before events at the same instant
    key: tuple
    fn: object  # (conn, received_at) -> None

    def apply(self, conn) -> None:
        self.fn(conn, self.received_at)


def _receipts(vault: Vault, device: str, capture: str) -> dict[tuple[int, str], float]:
    """First receipt time per (sequence, digest): a line for other bytes never supplies a time (DESIGN-03)."""
    out: dict[tuple[int, str], float] = {}
    for line in Vault.read_jsonl(vault.receipts_path(device, capture)):
        seq, at, sha = line.get("seq"), line.get("received_at"), line.get("sha256")
        if isinstance(seq, int) and isinstance(at, (int, float)) and isinstance(sha, str) and (seq, sha) not in out:
            out[(seq, sha)] = float(at)
    return out


@dataclass
class RecoveryState:
    """What the startup sweep learned for this process's requests, so a request never scans history (DESIGN-03/04):
    - `high_water`: per capture, the highest sequence with a file (.omnc or .gone) on disk, confirmed or not; a new
      seal can't declare a smaller last chunk. The ingest adds what this process publishes.
    - for captures the sweep could not resolve (`unresolved`): their receipt times by (sequence, digest) and their
      parsed capture.json evidence (None: none; `UNREADABLE`: couldn't be read), used by that identity's own retry.
    Disposable: rebuilt by every sweep, never a vault format."""

    high_water: dict[str, int] = field(default_factory=dict)
    unresolved: set[tuple[str, str]] = field(default_factory=set)
    receipts: dict[tuple[str, str], dict[tuple[int, str], float]] = field(default_factory=dict)
    evidence: dict[tuple[str, str], object] = field(default_factory=dict)
    retry_at: dict[tuple[str, str], tuple[float, int]] = field(default_factory=dict)  # (next try, failures so far)


UNREADABLE = object()


def drain_unresolved(db: Database, vault: Vault, *, now: float, limit: int = 1) -> int:
    """Off the request path (the worker tick): retry at most `limit` known unresolved captures whose backoff has passed,
    through the same confirming `index_capture_orphans`. No discovery walk; the identities come from the startup sweep
    and from publications that failed after their file existed (DESIGN-05, A9). Returns the captures resolved."""
    state = recovery_state(vault)
    due = [k for k in sorted(state.unresolved) if state.retry_at.get(k, (0.0, 0))[0] <= now][:limit]
    resolved = 0
    for device, capture in due:
        try:
            index_capture_orphans(db, vault, device, capture)
        except OSError as exc:
            failures = state.retry_at.get((device, capture), (0.0, 0))[1] + 1
            state.retry_at[(device, capture)] = (now + min(3600.0, 60.0 * 2 ** (failures - 1)), failures)
            log.warning("capture %s still can't be confirmed (%s); next try in %d s", capture, exc,
                        int(state.retry_at[(device, capture)][0] - now))  # fmt: skip
            continue
        for table in (state.unresolved, state.receipts, state.evidence, state.retry_at):
            table.discard((device, capture)) if isinstance(table, set) else table.pop((device, capture), None)
        resolved += 1
        log.info("capture %s: its files are confirmed and indexed now", capture)
    if due:
        db.set_meta("unresolved", json.dumps(sorted(f"{d}/{c}" for d, c in state.unresolved)[:200]) or None)
    return resolved
_STATES: dict[str, RecoveryState] = {}


def recovery_state(vault: Vault) -> RecoveryState:
    return _STATES.setdefault(os.path.realpath(vault.root), RecoveryState())


class Unconfirmed(OSError):
    """A capture's files or directories couldn't be confirmed durable: nothing of it is trusted yet."""


def _capture_ops(vault: Vault, device: str, capture: str, report: Report, *, skip: set[tuple[str, int]] | None = None,
                 skip_seal: bool = False) -> list[_Op]:  # fmt: skip
    """Index operations for one capture directory's files (`skip`: rows the index already has). Every file an operation
    trusts (chunk, tombstone, seal, receipts, capture.json evidence) is synced, then the capture and device directories;
    any failure raises `Unconfirmed` and nothing of the capture is used (the caller confirms raw → vault root)."""
    cap_dir = vault.capture_dir(device, capture)
    ops: list[_Op] = []
    names = {p.name for p in cap_dir.iterdir()} if cap_dir.exists() else set()
    try:
        for name in sorted(names):
            if name.endswith((".omnc", ".gone")) or name in ("seal.json", "receipts.jsonl", "capture.json"):
                stem = name.partition(".")[0]
                if stem.isdigit() and skip is not None and (capture, int(stem)) in skip:
                    continue
                spool.fsync_file(cap_dir / name)
        if names:
            spool.fsync_dir(cap_dir)
            spool.fsync_dir(cap_dir.parent)
    except OSError as exc:
        raise Unconfirmed(exc.errno, f"capture {device}/{capture} can't be confirmed durable now: {exc}") from exc
    receipts = _receipts(vault, device, capture)
    # the saved seal bounds the capture here as on a request (DESIGN-04): a chunk above it is kept, never indexed
    seal_last = None
    if "seal.json" in names:
        try:
            seal_last = validate_seal(json.loads((cap_dir / "seal.json").read_text())["body"]).seal.last_chunk_sequence
        except (ApiError, KeyError, TypeError, ValueError):
            seal_last = None  # reported below with the seal itself
    seqs: dict[int, str] = {}
    for name in names:
        stem, dot, ext = name.partition(".")
        if dot and ext in ("omnc", "gone") and stem.isdigit():
            seq = int(stem)
            if ext == "omnc" or seqs.get(seq) != "omnc":
                seqs[seq] = ext
    for seq, ext in sorted(seqs.items()):
        if skip is not None and (capture, seq) in skip:
            continue
        if seal_last is not None and seq > seal_last:
            report.problems.append(f"{vault.relpath(cap_dir / f'{seq}.{ext}')} is above its capture's seal: kept, not indexed")
            continue
        path = cap_dir / f"{seq}.omnc"
        if ext == "omnc":
            data = path.read_bytes()
            try:
                env = parse_envelope(data, capture_id=capture, chunk_sequence=seq)
            except EnvelopeError as exc:
                report.problems.append(f"unreadable chunk {vault.relpath(path)}: {exc}")
                continue
            digest, size, header, deleted, ring = sha256_hex(data), len(data), env.header, False, ring_record_hashes(env)
            report.chunks += 1
        else:
            tomb = json.loads((cap_dir / f"{seq}.gone").read_text())
            digest, size, header, deleted, ring = tomb["sha256"], int(tomb["size"]), tombstone_header(tomb), True, []
            report.tombstones += 1
        receipt = receipts.get((seq, digest))
        if receipt is not None:
            received = receipt
        else:
            # No receipt (a crash before it was appended): the chunk's own end time is the best
            # stable stand-in; the startup sweep appends a real receipt when it adopts the file.
            received = header.chunk_end_epoch
            report.problems.append(f"no receipt for {vault.relpath(path)}")

        def fn(conn, received, header=header, digest=digest, size=size, path=path, deleted=deleted, ring=ring):
            index_chunk(conn, header, digest=digest, size=size, path=vault.relpath(path), received_at=received,
                        raw_deleted=deleted, ring=ring)  # fmt: skip

        ops.append(_Op(received, 0, (capture, seq), fn))
    if "seal.json" in names and not skip_seal:
        stored = json.loads((cap_dir / "seal.json").read_text())
        try:
            facts = validate_seal(stored["body"])
        except (ApiError, KeyError) as exc:
            report.problems.append(f"invalid seal {vault.relpath(cap_dir / 'seal.json')}: {exc}")
        else:
            received = float(stored["received_at"])
            ops.append(_Op(received, 1, (capture, -1), lambda conn, r, f=facts: index_seal(conn, capture, f, r)))
            report.seals += 1
    return ops


def _captures(vault: Vault):
    if not vault.raw.exists():
        return
    for device_dir in sorted(vault.raw.iterdir()):
        if device_dir.is_dir():
            for cap_dir in sorted(device_dir.iterdir()):
                if cap_dir.is_dir():
                    yield device_dir.name, cap_dir.name


def _event_ops(vault: Vault, report: Report, known: dict[str, str] | None = None, since: str | None = None) -> list[_Op]:
    """Events from `_omi/events/*.jsonl` (first line per id wins; conflicting bodies reported)."""
    ops: list[_Op] = []
    seen: dict[str, str] = dict(known or {})
    if not vault.events_dir.exists():
        return ops
    for path in sorted(vault.events_dir.glob("*.jsonl")):
        if since is not None and path.stem < since:
            continue
        for line in Vault.read_jsonl(path):
            event_id, body, received = line.get("event_id"), line.get("body"), line.get("received_at")
            if not isinstance(event_id, str) or not isinstance(received, (int, float)):
                continue
            canonical = canonical_json(body)
            if event_id in seen:
                if seen[event_id] != canonical:
                    report.problems.append(f"event {event_id} appears with two different bodies; the first is kept")
                continue
            try:
                facts = validate_event(body)
            except ApiError as exc:
                report.problems.append(f"invalid event {event_id}: {exc.detail}")
                continue
            seen[event_id] = canonical
            ops.append(_Op(float(received), 2, (event_id,), lambda conn, r, e=event_id, f=facts: index_event(conn, e, f, r)))
            report.events += 1
    return ops


# -- capture.json evidence ---------------------------------------------------------------------------


def apply_capture_evidence(conn, vault: Vault, device: str, capture: str, *, only_seq: int | None = None,
                           evidence: dict | None = None) -> None:  # fmt: skip
    """Restore what deleted chunks contributed (from `capture.json`, or `evidence` already parsed at startup): chunk
    facts, coverage, losses, ring ownership, tentative speech, continuation checkpoints. With `only_seq` the index is
    read for that one chunk only (a request's own identity, DESIGN-03)."""
    if evidence is None:
        evidence = Vault.read_json(vault.capture_json_path(device, capture))
    if not evidence:
        return
    deleted = {int(k): v for k, v in (evidence.get("deleted") or {}).items()}
    if only_seq is not None:
        tombstoned = {r["chunk_sequence"] for r in conn.execute(
            "SELECT chunk_sequence FROM chunks WHERE capture_id=? AND chunk_sequence=? AND raw_deleted=1", (capture, only_seq)
        )}  # fmt: skip
    else:
        tombstoned = {r["chunk_sequence"] for r in conn.execute(
            "SELECT chunk_sequence FROM chunks WHERE capture_id=? AND raw_deleted=1", (capture,)
        )}  # fmt: skip
    seqs = {s for s in deleted if s in tombstoned and (only_seq is None or s == only_seq)}
    for seq in sorted(seqs):
        facts = deleted[seq]
        conn.execute(
            """UPDATE chunks SET status='processed', audio_start=?, audio_end=?, runs_json=?, stats_json=?,
                   carry_json=COALESCE(?, carry_json) WHERE capture_id=? AND chunk_sequence=?""",
            (facts.get("audio_start"), facts.get("audio_end"), json.dumps(facts.get("runs") or []),
             json.dumps(facts.get("stats") or {}), json.dumps(facts["carry"]) if facts.get("carry") else None,
             capture, seq),
        )  # fmt: skip
        for table in ("coverage", "losses", "ring_seen", "speech"):
            conn.execute(f"DELETE FROM {table} WHERE capture_id=? AND chunk_sequence=?", (capture, seq))
    rows = lambda key: [r for r in evidence.get(key) or [] if int(r[0]) in seqs]  # noqa: E731
    conn.executemany(
        "INSERT INTO coverage (device_id, kind, start, end, capture_id, chunk_sequence) VALUES (?,?,?,?,?,?)",
        [(device, kind, a, b, capture, seq) for seq, kind, a, b in rows("coverage")],
    )
    conn.executemany(
        "INSERT INTO losses (device_id, start, end, kind, count, capture_id, chunk_sequence) VALUES (?,?,?,?,?,?,?)",
        [(device, a, b, kind, n, capture, seq) for seq, a, b, kind, n in rows("losses")],
    )
    conn.executemany(
        "INSERT OR IGNORE INTO ring_seen (device_id, ring_seq, record_hash, capture_id, chunk_sequence) VALUES (?,?,?,?,?)",
        [(device, rs, h, capture, seq) for seq, rs, h in rows("ring_seen")],
    )
    received = {r["chunk_sequence"]: r["received_at"] for r in conn.execute(
        "SELECT chunk_sequence, received_at FROM chunks WHERE capture_id=?" + (" AND chunk_sequence=?" if only_seq is not None else ""),
        (capture,) if only_seq is None else (capture, only_seq),
    )}  # fmt: skip
    conn.executemany(
        """INSERT OR IGNORE INTO ring_records (device_id, ring_seq, record_hash, capture_id, chunk_sequence, received_at)
           VALUES (?,?,?,?,?,?)""",
        [(device, rs, h, capture, seq, received.get(seq, 0.0)) for seq, rs, h in rows("ring_records")],
    )
    conn.executemany(
        "INSERT INTO speech (device_id, start, end, capture_id, chunk_sequence, open) VALUES (?,?,?,?,?,1)",
        [(device, a, b, capture, seq) for seq, a, b in rows("speech_open")],
    )
    if only_seq is None and evidence.get("finalized"):
        cap = conn.execute("SELECT last_chunk_sequence FROM captures WHERE capture_id=?", (capture,)).fetchone()
        if cap is not None and cap["last_chunk_sequence"] is not None and cap["last_chunk_sequence"] in tombstoned:
            conn.execute("UPDATE captures SET finalized=1 WHERE capture_id=?", (capture,))


def advance_processed(conn, capture: str) -> None:
    """processed_through = end of the unbroken run of already-processed (tombstoned) chunks."""
    cap = conn.execute("SELECT processed_through FROM captures WHERE capture_id=?", (capture,)).fetchone()
    through = cap["processed_through"]
    while conn.execute(
        "SELECT 1 FROM chunks WHERE capture_id=? AND chunk_sequence=? AND status='processed'", (capture, through + 1)
    ).fetchone():
        through += 1
    conn.execute("UPDATE captures SET processed_through=? WHERE capture_id=?", (through, capture))


# -- records -----------------------------------------------------------------------------------------


def apply_record(conn, record: dict, sha: str, now: float, vault: Vault | None = None) -> None:
    """Make the index row of a conversation match its permanent record."""
    values, known = row_from_record(record)
    if vault is not None:
        _resume_newer_transcript(vault, values)
        values["class_choice"] = _class_choice(vault, values["id"])
    current = conn.execute("SELECT * FROM conversations WHERE id=?", (values["id"],)).fetchone()
    values["record_sha"] = sha
    if current is None or current["start"] != values["start"] or current["speech_seconds"] != values.get("speech_seconds"):
        values["day"] = None  # day and short flag filled when the index is opened, or by the worker (`home.py`)
    if current is None:
        values.update(created_at=values.get("finalized_at") or now, updated_at=now,
                      needs_render=int(values.get("note_path") is not None))  # fmt: skip
        cols = ", ".join(values)
        conn.execute(f"INSERT INTO conversations ({cols}) VALUES ({', '.join('?' * len(values))})", tuple(values.values()))
    else:
        if current["status"] in ("transcribing", "summarizing") and values["status"] == "closed":
            values.pop("status")  # work in progress on a closed record: keep its queue position
        values["updated_at"] = now
        conn.execute(f"UPDATE conversations SET {', '.join(f'{k}=?' for k in values)} WHERE id=?",
                     (*values.values(), values["id"]))  # fmt: skip
    conn.execute("DELETE FROM known_through WHERE conversation_id=?", (values["id"],))
    conn.executemany(
        "INSERT INTO known_through (conversation_id, capture_id, seq) VALUES (?,?,?)",
        [(values["id"], cap, seq) for cap, seq in known.items()],
    )
    # Speech this conversation knows about is claimed (segmentation re-derives the exact claims).


def _class_choice(vault: Vault, conv_id: str) -> str | None:
    """The owner's recording-class choice in `class.json` (the `class_choice` column); None for auto, none, or an
    unreadable file (shown as an issue by the API, which reads the file itself)."""
    try:
        data = Vault.read_json(vault.conversation_dir(conv_id) / "class.json")
    except (OSError, ValueError):
        return None
    chosen = data.get("class") if isinstance(data, dict) else None
    return chosen if chosen in ("monologue", "dialogue", "passive") else None


def _resume_newer_transcript(vault: Vault, values: dict) -> None:
    """A transcript.json newer than the record's last render (a forced re-transcription that a
    crash interrupted before its render was committed) is finished — summarized and rendered —
    rather than paired with the old summary."""
    if values.get("status") not in ("done", "failed", "discarded") or values.get("enrollment_id") or not values.get("transcript_sha"):
        return
    data = Vault.read_json(vault.conversation_dir(values["id"]) / "transcript.json")
    if not data:
        return
    current = sha256_hex(canonical_json(data.get("segments") or []).encode())
    if current != values["transcript_sha"]:
        log.info("conversation %s: its transcript is newer than its note; summarizing it again", values["id"])
        values.update(status="summarizing", transcript_sha=current, stt_ref=data.get("stt_file") or values.get("stt_ref"),
                      audio_sha=data.get("audio_sha") or values.get("audio_sha"))  # fmt: skip


def _validate(conn, vault: Vault, record: dict, report: Report) -> None:
    conv_dir = vault.conversation_dir(record["id"])
    render = record.get("render") or {}
    for key in ("stt_ref", "llm_ref"):
        name = render.get(key)
        if name and not (conv_dir / name).exists():
            report.gaps.append(f"conversation {record['id']} references missing {key} {name}")
    if render and not (conv_dir / "transcript.json").exists():
        report.gaps.append(f"conversation {record['id']} has no transcript.json")
    for capture, through in (record["decision"].get("known_through") or {}).items():
        cap = conn.execute("SELECT * FROM captures WHERE capture_id=?", (capture,)).fetchone()
        if cap is None:
            report.gaps.append(f"conversation {record['id']} references capture {capture}, which is missing")
            continue
        last = cap["last_chunk_sequence"]
        upto = min(through, last) if last is not None else through
        have = {r["chunk_sequence"] for r in conn.execute(
            "SELECT chunk_sequence FROM chunks WHERE capture_id=? AND chunk_sequence<=?", (capture, upto)
        )}  # fmt: skip
        missing = [s for s in range(0, upto + 1) if s not in have]
        if missing:
            report.gaps.append(f"conversation {record['id']} references chunks {missing[:3]} of {capture}, which are missing")
        if last is None and through > (max(have) if have else -1):
            report.gaps.append(f"conversation {record['id']} references the seal of {capture}, which is missing")


# -- build -------------------------------------------------------------------------------------------


def build(settings: Settings, vault: Vault, path: Path, *, now: float | None = None) -> Report:
    """Build a complete index at `path` from the vault (the file is replaced)."""
    now = time.time() if now is None else now
    for suffix in ("", "-wal", "-shm", "-journal"):
        Path(str(path) + suffix).unlink(missing_ok=True)
    db = Database(path)
    report = Report()
    ops: list[_Op] = []
    captures = []
    for device, capture in _captures(vault):
        try:
            ops += _capture_ops(vault, device, capture, report)
            captures.append((device, capture))
        except Unconfirmed as exc:  # kept on disk and reported; indexed once it can be confirmed (sweep / its own PUT)
            report.unresolved.append(f"{device}/{capture}")
            report.problems.append(str(exc))
    if vault.raw.exists():
        vault.confirm(vault.raw)  # raw → _omi → vault root (anchored); failing here fails the build, never a weaker index
    ops += _event_ops(vault, report)
    ops.sort(key=lambda op: (op.received_at, op.rank, op.key))
    with db.tx() as conn:
        for op in ops:
            op.apply(conn)
        for device, capture in captures:
            apply_capture_evidence(conn, vault, device, capture)
            if conn.execute("SELECT 1 FROM captures WHERE capture_id=?", (capture,)).fetchone():
                advance_processed(conn, capture)
        for record_path, record, sha in load_records(vault):
            if record is None:
                report.problems.append(f"unreadable conversation record {vault.relpath(record_path)}")
                continue
            apply_record(conn, record, sha, now, vault)
            _validate(conn, vault, record, report)
            report.conversations += 1
        days = {r["start"] for r in conn.execute("SELECT start FROM conversations")}
    _mark_days(db, settings, days)
    _load_speakers(db, vault, settings)
    for problem in vault.divergence():
        report.gaps.append(problem)
    db.set_meta("vault_id", vault.vault_id)
    db.set_meta("vault_path", os.path.realpath(vault.root))
    db.set_meta("replay_pending", "1")
    db.set_meta("read_only", report.read_only_reason)
    db.set_meta("problems", json.dumps(report.problems[:50]) if report.problems else None)
    db.set_meta("built_at", repr(now))
    db.set_meta("unresolved", json.dumps(report.unresolved[:200]) if report.unresolved else None)
    db.set_meta("publication_contract", PUBLICATION_CONTRACT)
    db.set_meta("complete", "1")
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close()
    return report


def _load_speakers(db: Database, vault: Vault, settings: Settings) -> None:
    """People notes, samples, and per-conversation voices / speaker assignments."""
    from .speakers.store import SpeakerStore

    store = SpeakerStore(vault, db, auto_assign_default=settings.speaker_auto_assign)
    store.scan_people()
    store.load_samples()
    for row in db.query("SELECT id FROM conversations"):
        store.load_conversation(row["id"])


def _mark_days(db: Database, settings: Settings, starts) -> None:
    from datetime import datetime

    tz = settings.tz
    days = {datetime.fromtimestamp(s, tz).date().isoformat() for s in starts}
    db.conn().executemany("INSERT OR IGNORE INTO dirty_days (day) VALUES (?)", [(d,) for d in days])


@contextmanager
def _rebuild_lock(directory: Path):
    directory.mkdir(parents=True, exist_ok=True)
    fd = os.open(directory / "rebuild.lock", os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def index_is_current(path: Path, vault: Vault) -> str | None:
    """None when the index at `path` matches this vault, else why it must be rebuilt."""
    if not path.exists():
        return "no index"
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            meta = dict(conn.execute("SELECT key, value FROM meta").fetchall())
        finally:
            conn.close()
    except sqlite3.Error as exc:
        return f"unreadable index ({exc})"
    if meta.get("schema_version") != str(SCHEMA_VERSION):
        return f"schema {meta.get('schema_version')} != {SCHEMA_VERSION}"
    if meta.get("vault_id") != vault.vault_id:
        return "vault id differs"
    if meta.get("vault_path") != os.path.realpath(vault.root):
        return "vault path differs"
    if meta.get("complete") != "1":
        return "incomplete build"
    if meta.get("publication_contract") != PUBLICATION_CONTRACT:
        return "built under an older publication rule: every file is confirmed once before its rows are trusted"
    if meta.get("read_only"):
        return "the last build found an incomplete vault"
    return None


def rebuild(settings: Settings, vault: Vault, *, now: float | None = None) -> Report:
    """Rebuild the index into `index.tmp`, then atomically replace `index.sqlite3`."""
    directory = index_dir(settings, vault)
    directory.mkdir(parents=True, exist_ok=True)
    tmp, target = directory / "index.tmp", directory / "index.sqlite3"
    report = build(settings, vault, tmp, now=now)
    for suffix in ("-wal", "-shm"):
        Path(str(target) + suffix).unlink(missing_ok=True)
    os.replace(tmp, target)
    fsync_dir(directory)
    log.info("rebuilt the index for %s: %d chunks, %d tombstones, %d seals, %d events, %d conversations%s",
             vault.root, report.chunks, report.tombstones, report.seals, report.events, report.conversations,
             f"; READ-ONLY: {report.read_only_reason}" if report.read_only_reason else "")  # fmt: skip
    for problem in report.problems[:20]:
        log.warning("rebuild: %s", problem)
    return report


def open_index(settings: Settings, vault: Vault, *, sweep_orphans: bool = True, force_rebuild: bool = False) -> Database:
    """The vault's index database: reused when current, rebuilt otherwise; orphans swept."""
    directory = index_dir(settings, vault)
    target = directory / "index.sqlite3"
    with _rebuild_lock(directory):
        reason = "requested" if force_rebuild else index_is_current(target, vault)
        if reason:
            log.info("rebuilding the index (%s)", reason)
            rebuild(settings, vault)
        db = Database(target)
        if sweep_orphans and not db.meta("read_only"):
            sweep(db, vault)
        from . import home

        home.ensure_home(db, home.timezone_name(settings, vault), home.short_threshold(settings))
    return db


# -- startup sweep -----------------------------------------------------------------------------------


def index_capture_orphans(db: Database, vault: Vault, device: str, capture: str) -> int:
    """Index files of one capture that have no index row (and give them receipts)."""
    report = Report()
    have = {(capture, r["chunk_sequence"]) for r in db.query("SELECT chunk_sequence FROM chunks WHERE capture_id=?", (capture,))}
    cap = db.one("SELECT seal_json FROM captures WHERE capture_id=?", (capture,))
    # the capture's files and directories are synced (Unconfirmed otherwise), then its chain up to the vault root
    ops = _capture_ops(vault, device, capture, report, skip=have, skip_seal=cap is not None and cap["seal_json"] is not None)
    if not ops:
        return 0
    vault.confirm(vault.capture_dir(device, capture))
    receipts = _receipts(vault, device, capture)
    now = time.time()
    for op in ops:
        seq = op.key[1]
        if seq < 0:
            continue
        data = vault.chunk_path(device, capture, seq)
        digest = sha256_hex(data.read_bytes()) if data.exists() else json.loads(
            vault.tombstone_path(device, capture, seq).read_text())["sha256"]
        if (seq, digest) not in receipts:
            # Adopted now: persist a confirmed receipt so the next rebuild sees the same time.
            vault.append_confirmed(vault.receipts_path(device, capture), {"seq": seq, "sha256": digest, "received_at": now})
            op.received_at = now
    with db.tx() as conn:
        for op in sorted(ops, key=lambda o: (o.received_at, o.rank, o.key)):
            try:
                op.apply(conn)
            except sqlite3.IntegrityError:  # a concurrent process indexed it first
                pass
        apply_capture_evidence(conn, vault, device, capture)
    return len(ops)


def sweep(db: Database, vault: Vault) -> dict:
    """Index files a crash left without index rows: raw chunks/tombstones/seals, recent event
    lines, and conversation records newer than their index row."""
    counts = {"raw": 0, "events": 0, "records": 0}
    state = RecoveryState()
    for device, capture in _captures(vault):
        cap_dir = vault.capture_dir(device, capture)
        seqs = [int(p.name.partition(".")[0]) for p in cap_dir.iterdir()
                if p.suffix in (".omnc", ".gone") and p.name.partition(".")[0].isdigit()]  # fmt: skip
        if seqs:
            state.high_water[capture] = max(seqs)
        files = len(set(seqs))
        cap = db.one("SELECT seal_json FROM captures WHERE capture_id=?", (capture,))
        indexed = db.one("SELECT COUNT(*) AS n FROM chunks WHERE capture_id=?", (capture,))["n"]
        seal_missing = (cap_dir / "seal.json").exists() and (cap is None or cap["seal_json"] is None)
        if files != indexed or seal_missing:
            try:
                counts["raw"] += index_capture_orphans(db, vault, device, capture)
            except OSError as exc:  # can't be confirmed now: kept unindexed, its facts prepared for its own retry
                log.warning("sweep: capture %s not indexed yet: %s", capture, exc)
                state.unresolved.add((device, capture))
                state.receipts[(device, capture)] = _receipts(vault, device, capture)
                try:
                    state.evidence[(device, capture)] = Vault.read_json(vault.capture_json_path(device, capture))
                except (OSError, ValueError):
                    state.evidence[(device, capture)] = UNREADABLE
    _STATES[os.path.realpath(vault.root)] = state
    if state.unresolved:
        log.warning("sweep: %d capture(s) have files that can't be confirmed yet; their own uploads retry them",
                    len(state.unresolved))
    latest = db.one("SELECT MAX(received_at) AS m FROM events")["m"]
    if vault.events_dir.exists():
        from datetime import UTC, datetime

        since = datetime.fromtimestamp(latest - 86400, UTC).date().isoformat() if latest else None
        known = {r["event_id"]: r["body_json"] for r in db.query("SELECT event_id, body_json FROM events WHERE received_at >= ?",
                                                                  ((latest or 0) - 3 * 86400,))}  # fmt: skip
        report = Report()
        ops = _event_ops(vault, report, known=known, since=since)
        with db.tx() as conn:
            for op in ops:
                if conn.execute("SELECT 1 FROM events WHERE event_id=?", op.key).fetchone() is None:
                    op.apply(conn)
                    counts["events"] += 1
    shas = {r["id"]: r["record_sha"] for r in db.query("SELECT id, record_sha FROM conversations")}
    now = time.time()
    for _path, record, sha in load_records(vault):
        if record is None or shas.get(record["id"]) == sha:
            continue
        with db.tx() as conn:
            apply_record(conn, record, sha, now, vault)
        counts["records"] += 1
    counts["speakers"] = _sweep_speakers(db, vault)
    if any(counts.values()):
        log.info("startup sweep indexed %s", counts)
    return counts


def _sweep_speakers(db: Database, vault: Vault) -> int:
    """People, samples, and per-conversation speakers/voices files newer than the index."""
    from .speakers.store import SpeakerStore

    store = SpeakerStore(vault, db)
    with store.lock:  # a separate worker process sweeps while the API may be writing labels
        changed = int(store.scan_people()) + int(store.sync_samples())
        for r in db.query("SELECT id FROM conversations WHERE status <> 'open'"):
            if store.sync_conversation(r["id"]):
                changed += 1
                db.set_meta("relabel_pending", "1")  # its dependent work (renders, other assignments)
    return changed

