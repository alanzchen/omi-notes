"""App retries as durable operations (docs/vault.md, "Operations").

A retry the phone asked for is a file, `_omi/operations/<request_id>.json`, written (and fsync'd)
before anything is queued: `{format, id, kind: "retry", conversation_id, stage, failure_kind,
record_sha, requested_at, state}`. Accepting it then commits `retry: {op, stage}` into the
conversation's record and bumps the reprocess counter to wake the worker. The attempt's outcome is
committed into the same record as `retry_outcome` together with the success or failure it
describes, so a rebuild tells a finished retry from a pending one; the operation file is then
closed (`done` / `failed`, never changed again).

Reconciliation repairs the gaps between those writes: an accepted operation whose record never got
`retry` (a crash in between) is queued again only while the record is still the exact failure it
was accepted for (`record_sha`); anything else supersedes it. Nothing here deletes, and a provider
call can repeat only if the process dies between the response and its cache write.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

from .ingest import ApiError
from .lock import SpeakerLock
from .util import UUID_RE, iso_utc_epoch
from .vault import Vault
from .views import LISTED

log = logging.getLogger(__name__)

FORMAT = 1
TERMINAL = ("done", "failed", "superseded")
SWEEP_BATCH = 50


def ops_dir(vault: Vault) -> Path:
    return vault.omi / "operations"


def op_path(vault: Vault, op_id: str) -> Path:
    return ops_dir(vault) / f"{op_id}.json"


def lock(vault: Vault) -> SpeakerLock:
    return SpeakerLock(vault, name="operations.lock")


def read(vault: Vault, op_id: str) -> dict | None:
    try:
        op = json.loads(op_path(vault, op_id).read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        raise ApiError(500, "operation_unreadable", f"operation {op_id} is unreadable: {exc}") from exc
    return op if isinstance(op, dict) else None


def _write(vault: Vault, op: dict) -> None:
    Vault.write_json(op_path(vault, op["id"]), op)


def _row(db, conv_id: str):
    return db.one(f"SELECT * FROM conversations WHERE id=? AND {LISTED}", (conv_id,))


def _outcome(row) -> dict | None:
    try:
        return json.loads(row["retry_outcome"]) if row and row["retry_outcome"] else None
    except json.JSONDecodeError:
        return None


# -- accepting --------------------------------------------------------------------------------------


def accept(pipeline, conv_id: str, request_id: str, *, read_only: str | None) -> tuple[int, dict]:
    """`POST /v1/conversations/{id}/retry`: 202 with the new operation, or 200 for a repeated
    request id (after finishing its acceptance if a crash interrupted it)."""
    if not isinstance(request_id, str) or not UUID_RE.match(request_id):
        raise ApiError(422, "invalid_body", "request_id must be a lowercase UUID")
    if read_only:
        raise ApiError(503, "vault_read_only", read_only)
    vault, db = pipeline.vault, pipeline.db
    with lock(vault):
        existing = read(vault, request_id)
        if existing is not None:
            if existing.get("kind") != "retry" or existing.get("conversation_id") != conv_id:
                raise ApiError(409, "request_conflict", "this request id belongs to another operation")
            _repair(pipeline, existing)
            return 200, view(pipeline, request_id)
        row = _row(db, conv_id)
        if row is None:
            raise ApiError(404, "not_found", "unknown conversation")
        token = pipeline.claim(conv_id)
        if token is None:
            raise ApiError(409, "busy", "the server is working on this conversation right now; try again in a moment")
        try:
            row = _row(db, conv_id)
            _check_retryable(row)
            previous = _outcome(row)
            if previous:
                _close(vault, previous)  # its receipt is final before a new attempt replaces the outcome
            vault.raise_format(2)
            op = {"format": FORMAT, "id": request_id, "kind": "retry", "conversation_id": conv_id,
                  "stage": row["failed_stage"] or "transcribing", "failure_kind": row["error_kind"],
                  "record_sha": row["record_sha"], "requested_at": time.time(), "state": "accepted"}  # fmt: skip
            _write(vault, op)
            _enqueue(pipeline, row, op)
        finally:
            pipeline.release(conv_id, token)
    return 202, view(pipeline, request_id)


def _check_retryable(row) -> None:
    if row is None:
        raise ApiError(404, "not_found", "unknown conversation")
    if row["retry_op"]:
        raise ApiError(409, "retry_in_progress", f"a retry of this conversation is already queued ({row['retry_op']})")
    if row["status"] != "failed":
        raise ApiError(409, "not_failed", "only a failed conversation can be retried")
    if row["frozen"]:
        raise ApiError(409, "note_frozen", "the note is frozen; unfreeze it on the server to let it be updated")
    if row["edited"]:
        raise ApiError(409, "note_conflict", "the note was edited outside My Notes; resolve that on the server first")


def _enqueue(pipeline, row, op: dict) -> None:
    """Record the retry in conversation.json (then the index), then wake the worker. The counter is
    only a wake-up: which attempt is the retry's is decided by `retry`/`retry_outcome`."""
    pipeline._commit(row["id"], retry_op=op["id"], retry_stage=op["stage"])
    pipeline.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1 WHERE id=?", (row["id"],))


# -- finishing and repairing ----------------------------------------------------------------------


def finished(pipeline, op_id: str | None) -> None:
    """Close an operation whose outcome was just committed. Best effort: reconciliation closes it
    later if this fails, so it never fails the conversation."""
    if not op_id:
        return
    try:
        row = pipeline.db.one("SELECT retry_outcome FROM conversations WHERE retry_outcome IS NOT NULL AND "
                              "json_extract(retry_outcome, '$.op') = ?", (op_id,))  # fmt: skip
        outcome = _outcome(row)
        if outcome:
            with lock(pipeline.vault):
                _close(pipeline.vault, outcome)
    except Exception:
        log.exception("could not close operation %s", op_id)


def _close(vault: Vault, outcome: dict) -> None:
    op = read(vault, outcome["op"])
    if op is None or op.get("state") in TERMINAL:
        return
    op.update(state="failed" if outcome.get("status") == "failed" else "done", outcome=outcome.get("status"),
              outcome_failure_kind=outcome.get("failure_kind"), finished_at=outcome.get("finished_at"))  # fmt: skip
    _write(vault, op)


def _repair(pipeline, op: dict) -> None:
    """Finish whatever a crash left undone for one accepted operation (caller holds the lock)."""
    if op.get("state") in TERMINAL or any(pipeline.db.meta(k) for k in ("read_only", "divergence", "fenced")):
        return
    vault, db = pipeline.vault, pipeline.db
    row = _row(db, op["conversation_id"])
    if row is None:
        return  # an incomplete vault: leave the operation for when the record is back
    outcome = _outcome(row)
    if outcome and outcome.get("op") == op["id"]:
        _close(vault, outcome)
    elif row["retry_op"] == op["id"]:
        if row["status"] == "failed" and row["reprocess_request"] <= row["reprocess_handled"]:
            # accepted before a rebuild reset the counters: wake it again
            db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1 WHERE id=?", (row["id"],))
    elif (row["retry_op"] is None and row["status"] == "failed" and row["record_sha"] == op.get("record_sha")
          and not row["frozen"] and not row["edited"]):  # fmt: skip
        token = pipeline.claim(row["id"])
        if token is None:
            return  # the worker has it; try again on the next sweep
        try:
            fresh = _row(db, row["id"])
            if fresh["retry_op"] is None and fresh["record_sha"] == op.get("record_sha"):
                _enqueue(pipeline, fresh, op)
        finally:
            pipeline.release(row["id"], token)
    else:
        # the failure it was accepted for is gone (another attempt ran, or the note changed)
        op.update(state="superseded", finished_at=time.time())
        _write(vault, op)


class Sweeper:
    """Bounded reconciliation on every worker tick: closed operations are remembered so each file
    is read at most once per process."""

    def __init__(self) -> None:
        self.closed: set[str] = set()

    def run(self, pipeline) -> int:
        folder = ops_dir(pipeline.vault)
        if not folder.exists():
            return 0
        done = 0
        for path in sorted(folder.glob("*.json")):
            op_id = path.stem
            if op_id in self.closed or not UUID_RE.match(op_id):
                continue
            if done >= SWEEP_BATCH:
                break
            done += 1
            try:
                with lock(pipeline.vault):
                    op = read(pipeline.vault, op_id)
                    if op is None:
                        continue
                    _repair(pipeline, op)
                    if (read(pipeline.vault, op_id) or {}).get("state") in TERMINAL:
                        self.closed.add(op_id)
            except Exception:  # one unreadable operation must not stall the others
                log.exception("could not reconcile operation %s", op_id)
        return done


# -- reading ----------------------------------------------------------------------------------------


def view(pipeline, op_id: str) -> dict:
    """`GET /v1/operations/{id}`: the file's state, refined from the conversation row while open.
    Observational: it never writes or queues anything."""
    op = read(pipeline.vault, op_id)
    if op is None:
        raise ApiError(404, "not_found", "unknown operation")
    state = op.get("state", "accepted")
    row = _row(pipeline.db, op["conversation_id"]) if op.get("conversation_id") else None
    if state not in TERMINAL and row is not None:
        outcome = _outcome(row)
        if outcome and outcome.get("op") == op_id:
            state = "failed" if outcome.get("status") == "failed" else "done"
        elif row["retry_op"] == op_id:
            now = time.time()
            if row["edited"]:
                state = "blocked"
            elif row["status"] == "failed":
                state = "queued"
            elif row["error"] and row["next_attempt_at"]:
                state = "backing_off"
            elif row["claim_token"] and (row["claim_expires"] or 0) > now:
                state = "running"
            else:
                state = "queued"
    return {
        "id": op_id,
        "kind": op.get("kind"),
        "conversation_id": op.get("conversation_id"),
        "stage": op.get("stage"),
        "state": state,
        "requested_at": iso_utc_epoch(op["requested_at"]) if op.get("requested_at") else None,
        "finished_at": iso_utc_epoch(op["finished_at"]) if op.get("finished_at") else None,
        "message": _MESSAGES.get(state, state),
    }


_MESSAGES = {
    "accepted": "Retry accepted",
    "queued": "Waiting for the server to start",
    "running": "Retrying now",
    "backing_off": "The service is still having trouble; the server tries again on its own",
    "blocked": "Waiting: the note was edited outside My Notes",
    "done": "Retried successfully",
    "failed": "The retry failed again",
    "superseded": "Replaced by later processing",
}
