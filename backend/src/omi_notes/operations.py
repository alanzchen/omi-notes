"""App retries and keeps as durable operations (docs/vault.md, "Operations").

A retry the phone asked for is a file, `_omi/operations/<request_id>.json`, written (and fsync'd)
before anything is queued: `{format, id, kind: "retry", conversation_id, stage, failure_kind,
failure_id, record_sha, requested_at, state}`. Accepting it then commits `retry: {op, stage}` into
the conversation's record and bumps the reprocess counter to wake the worker. The attempt's outcome
is committed into the same record as `retry_outcome` together with the success or failure it
describes, so a rebuild tells a finished retry from a pending one; the operation file is then
closed (`done` / `failed` / `stopped`, never changed again).

Reconciliation repairs the gaps between those writes: an accepted operation whose record never got
`retry` (a crash in between) is queued again only while the record is still the very failed attempt
it was accepted for (`failure_id`); anything else supersedes it. A malformed operation file is
reported, never overwritten; a missing one whose outcome is recorded is written again from it.
Nothing here deletes, and a provider call can repeat only if the process dies between the response
and its cache write.

A keep (`kind: "keep"`, `POST /v1/conversations/{id}/keep`) is the same operation for a
`speakers_unknown` failure, plus the owner's decision: `resolution` is committed with `retry`, so the
attempt it queues makes a transcript-only note with the speaker unknown (cached text, no provider
call) instead of failing again. The vault is raised to format 3 first.
"""

from __future__ import annotations

import json
import logging
import math
import time
from pathlib import Path

from .ingest import ApiError
from .lock import SpeakerLock
from .util import UUID_RE, iso_utc_epoch
from .vault import Vault
from .views import LISTED

log = logging.getLogger(__name__)

FORMAT = 1
KINDS = ("retry", "keep")
KEPT = "kept_speaker_unknown"
TERMINAL = ("done", "failed", "stopped", "superseded")
REQUIRED = ("id", "kind", "conversation_id", "state")
STATES = ("accepted", *TERMINAL)
STAGES = ("transcribing", "summarizing")
SWEEP_BATCH = 50
BUSY = ("busy", "the server is working on this conversation right now; try again in a moment")


class OperationCorrupt(ApiError):
    pass


def ops_dir(vault: Vault) -> Path:
    return vault.omi / "operations"


def op_path(vault: Vault, op_id: str) -> Path:
    return ops_dir(vault) / f"{op_id}.json"


def lock(vault: Vault) -> SpeakerLock:
    return SpeakerLock(vault, name="operations.lock")


def read(vault: Vault, op_id: str) -> dict | None:
    """The operation, None if there is no file. A file that isn't a valid operation raises: it is
    evidence to keep, never something to write over."""
    try:
        op = json.loads(op_path(vault, op_id).read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        raise OperationCorrupt(500, "operation_unreadable", f"operation {op_id} is unreadable: {exc}") from exc
    if (not isinstance(op, dict) or any(not isinstance(op.get(k), str) for k in REQUIRED) or op["id"] != op_id
            or not isinstance(op.get("format"), int) or not 1 <= op["format"] <= FORMAT or op["kind"] not in KINDS
            or op["state"] not in STATES or (op["state"] == "accepted" and not _valid_accepted(op))):  # fmt: skip
        raise OperationCorrupt(500, "operation_unreadable", f"operation {op_id} is not a valid operation file")
    return op


def _valid_accepted(op: dict) -> bool:
    """An accepted operation carries what repair needs: its stage, when, and the failed attempt."""
    at = op.get("requested_at")
    return (op.get("stage") in STAGES and isinstance(at, (int, float)) and not isinstance(at, bool)
            and math.isfinite(at) and "failure_id" in op and "record_sha" in op)  # fmt: skip


def _write(vault: Vault, op: dict) -> None:
    Vault.write_json(op_path(vault, op["id"]), op)


def _row(db, conv_id: str):
    return db.one(f"SELECT * FROM conversations WHERE id=? AND {LISTED}", (conv_id,))


def _outcome(row) -> dict | None:
    try:
        outcome = json.loads(row["retry_outcome"]) if row and row["retry_outcome"] else None
    except json.JSONDecodeError:
        return None
    return outcome if isinstance(outcome, dict) and isinstance(outcome.get("op"), str) else None


def _state(outcome: dict) -> str:
    return {"failed": "failed", "frozen": "stopped"}.get(outcome.get("status") or "", "done")


# -- accepting --------------------------------------------------------------------------------------


def accept(pipeline, conv_id: str, request_id: str, *, read_only: str | None, kind: str = "retry") -> tuple[int, dict]:
    """`POST /v1/conversations/{id}/retry` (or `/keep`): 202 with the new operation, or 200 for a
    repeated request id once its acceptance is complete (a crash may have interrupted it)."""
    if not isinstance(request_id, str) or not UUID_RE.match(request_id):
        raise ApiError(422, "invalid_body", "request_id must be a lowercase UUID")
    if read_only:
        raise ApiError(503, "vault_read_only", read_only)
    vault, db = pipeline.vault, pipeline.db
    with lock(vault):
        existing = read(vault, request_id)
        if existing is not None:
            if existing.get("kind") != kind or existing.get("conversation_id") != conv_id:
                raise ApiError(409, "request_conflict", "this request id belongs to another operation")
            if not _repair(pipeline, existing):
                # accepted, but its queueing isn't committed yet: not an answer to settle on
                raise ApiError(409, *BUSY)
            return 200, view(pipeline, request_id)
        row = _row(db, conv_id)
        if row is None:
            raise ApiError(404, "not_found", "unknown conversation")
        outcome = _outcome(row)
        if outcome and outcome.get("op") == request_id:
            # this request already ran and its receipt was lost: answer with that outcome, never again
            _close(vault, outcome, conv_id)
            return 200, view(pipeline, request_id)
        token = pipeline.claim(conv_id)
        if token is None:
            raise ApiError(409, *BUSY)
        try:
            row = _row(db, conv_id)
            _check_retryable(row)
            if kind == "keep" and row["error_kind"] != "speakers_unknown":
                raise ApiError(409, "not_keepable", "only a conversation whose speakers couldn't be separated can be kept "
                               "this way")  # fmt: skip
            previous = _outcome(row)
            if previous:
                _close(vault, previous, conv_id)  # its receipt is final before a new attempt replaces it
            vault.raise_format(3 if kind == "keep" else 2)
            op = {"format": FORMAT, "id": request_id, "kind": kind, "conversation_id": conv_id,
                  "stage": row["failed_stage"] or "transcribing", "failure_kind": row["error_kind"],
                  "failure_id": row["failure_id"], "record_sha": row["record_sha"], "requested_at": time.time(),
                  "state": "accepted"}  # fmt: skip
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
    if row["reprocess_request"] > row["reprocess_handled"]:
        raise ApiError(409, "busy", "other processing of this conversation is queued; try again when it finishes")


def _enqueue(pipeline, row, op: dict) -> None:
    """Record the retry in conversation.json (then the index), then wake the worker. The counter is
    only a wake-up: which attempt is the retry's is decided by `retry` / `retry_outcome`."""
    keep = {}
    if op["kind"] == "keep":
        # the owner's decision, with the failure it resolves (it stays visible after the note exists)
        keep["resolution"] = json.dumps({"kind": KEPT, "op": op["id"], "resolved_at": op["requested_at"],
                                         "failure": {"stage": row["failed_stage"], "kind": row["error_kind"],
                                                     "id": row["failure_id"]}}, sort_keys=True)  # fmt: skip
    pipeline._commit(row["id"], retry_op=op["id"], retry_stage=op["stage"], **keep)
    pipeline.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1 WHERE id=?", (row["id"],))


# -- finishing and repairing ----------------------------------------------------------------------


def finished(pipeline, op_id: str | None) -> None:
    """Close an operation whose outcome was just committed. Best effort: reconciliation closes it
    later if this fails, so it never fails the conversation."""
    if not op_id:
        return
    try:
        row = pipeline.db.one("SELECT id, retry_outcome FROM conversations WHERE retry_outcome IS NOT NULL AND "
                              "json_extract(retry_outcome, '$.op') = ?", (op_id,))  # fmt: skip
        outcome = _outcome(row)
        if outcome:
            with lock(pipeline.vault):
                _close(pipeline.vault, outcome, row["id"])
    except Exception:
        log.exception("could not close operation %s", op_id)


def _close(vault: Vault, outcome: dict, conv_id: str | None) -> None:
    op = read(vault, outcome["op"])
    if op is not None and op.get("state") in TERMINAL:
        return
    if op is None:
        # the receipt is missing (lost from the vault) but its outcome is recorded: write it again
        log.warning("operation %s had no file; writing its receipt from the recorded outcome", outcome["op"])
        op = {"format": FORMAT, "id": outcome["op"], "kind": outcome.get("kind", "retry"), "conversation_id": conv_id,
              "reconstructed": True}  # fmt: skip
    op.update(state=_state(outcome), outcome=outcome.get("status"),
              outcome_failure_kind=outcome.get("failure_kind"), finished_at=outcome.get("finished_at"))  # fmt: skip
    _write(vault, op)


def _same_failure(row, op: dict) -> bool:
    """The row is still the failed attempt the operation was accepted for."""
    if op.get("failure_id") or row["failure_id"]:
        return row["failure_id"] == op.get("failure_id")
    return row["record_sha"] == op.get("record_sha")  # a failure recorded before failure ids existed


def _repair(pipeline, op: dict) -> bool:
    """Finish whatever a crash left undone for one accepted operation (caller holds the lock).
    True once nothing is left to do now (queued, closed or superseded); False if it must be tried
    again (the conversation is busy or missing, or the vault is read-only)."""
    if op.get("state") in TERMINAL:
        return True
    if any(pipeline.db.meta(k) for k in ("read_only", "divergence", "fenced")):
        return False
    vault, db = pipeline.vault, pipeline.db
    row = _row(db, op["conversation_id"])
    if row is None:
        log.warning("operation %s refers to conversation %s, which isn't in the index", op["id"], op["conversation_id"])
        return False  # an incomplete vault: keep the operation for when the record is back
    outcome = _outcome(row)
    if outcome and outcome.get("op") == op["id"]:
        _close(vault, outcome, row["id"])
    elif row["retry_op"] == op["id"]:
        if row["status"] == "failed" and row["reprocess_request"] <= row["reprocess_handled"]:
            # accepted before a rebuild reset the counters: wake it again
            db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1 WHERE id=?", (row["id"],))
    elif (row["retry_op"] is None and row["status"] == "failed" and _same_failure(row, op)
          and not row["frozen"] and not row["edited"]):  # fmt: skip
        if row["reprocess_request"] > row["reprocess_handled"]:
            return False  # other work was queued meanwhile: let it run, then see if this failure remains
        token = pipeline.claim(row["id"])
        if token is None:
            return False  # the worker has it; try again on the next sweep
        try:
            fresh = _row(db, row["id"])
            if (fresh["retry_op"] is not None or not _same_failure(fresh, op)
                    or fresh["reprocess_request"] > fresh["reprocess_handled"]):  # fmt: skip
                return False
            _enqueue(pipeline, fresh, op)
        finally:
            pipeline.release(row["id"], token)
    else:
        # the failed attempt it was accepted for is gone (another attempt ran, or the note changed)
        op.update(state="superseded", finished_at=time.time())
        _write(vault, op)
    return True


class Sweeper:
    """Bounded reconciliation on every worker tick. Closed operations are remembered so each file
    is read at most once per process, and each tick continues where the last one stopped, so a run
    of stuck or unreadable operations can't starve the ones after it."""

    def __init__(self) -> None:
        self.closed: set[str] = set()
        self.after = ""

    def run(self, pipeline) -> int:
        folder = ops_dir(pipeline.vault)
        if not folder.exists():
            return 0
        names = sorted(p.stem for p in folder.glob("*.json") if p.stem not in self.closed and UUID_RE.match(p.stem))
        if not names:
            return 0
        start = next((i for i, n in enumerate(names) if n > self.after), 0)
        batch = (names[start:] + names[:start])[:SWEEP_BATCH]
        self.after = batch[-1]
        for op_id in batch:
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
        return len(batch)


# -- reading ----------------------------------------------------------------------------------------


def view(pipeline, op_id: str) -> dict:
    """`GET /v1/operations/{id}`: the file's state, refined from the conversation row while open.
    Observational: it never writes or queues anything."""
    op = read(pipeline.vault, op_id)
    if op is None:
        raise ApiError(404, "not_found", "unknown operation")
    state = op.get("state", "accepted")
    finished_at = op.get("finished_at")
    row = _row(pipeline.db, op["conversation_id"]) if op.get("conversation_id") else None
    if state not in TERMINAL and row is not None:
        outcome = _outcome(row)
        if outcome and outcome.get("op") == op_id:
            state = _state(outcome)
            finished_at = outcome.get("finished_at")
        elif row["retry_op"] == op_id:
            now = time.time()
            if row["edited"] or row["frozen"]:
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
        "finished_at": iso_utc_epoch(finished_at) if finished_at else None,
        "message": (_KEEP_MESSAGES.get(state) if op.get("kind") == "keep" else None) or _MESSAGES.get(state, state),
    }


_MESSAGES = {
    "accepted": "Retry accepted",
    "queued": "Queued on the server",
    "running": "Retrying now",
    "backing_off": "The service is still having trouble; the server tries again on its own",
    "blocked": "Waiting: the note was edited or frozen on the server",
    "done": "Retried successfully",
    "failed": "The retry failed again",
    "stopped": "Stopped: the note is frozen on the server",
    "superseded": "Replaced by later processing",
}

_KEEP_MESSAGES = {
    "accepted": "Keeping it",
    "done": "Kept as a transcript; the speaker is unknown",
    "failed": "Couldn't keep it: processing failed for another reason",
}
