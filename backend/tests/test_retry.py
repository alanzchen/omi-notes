"""Durable app retries (docs/vault.md, "Operations"): accepted before 2xx, never lost or repeated
by a crash or an index rebuild, and closed by the attempt that actually ran."""

from __future__ import annotations

import json
import shutil
import uuid

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes import operations
from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.devtools import synth_speech_like
from omi_notes.pipeline.worker import Worker
from omi_notes.providers import ProviderError
from omi_notes.providers.fake import FakeLlm, FakeStt

from .conftest import AUTH
from .helpers import T0, convs, note_text, replay, silence

SPEECH = np.concatenate([silence(1), synth_speech_like(12), silence(2)])


class CountingLlm(FakeLlm):
    def __init__(self, error: ProviderError | None = None):
        self.calls, self.error = 0, error

    def summarize(self, request):
        self.calls += 1
        if self.error:
            raise self.error
        return super().summarize(request)


AUTH_ERROR = ProviderError("invalid x-api-key", terminal=True, kind="auth")


def failed_summary(client, worker) -> dict:
    worker.providers._llm = CountingLlm(AUTH_ERROR)
    replay(client, SPEECH)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "failed" and row["failed_stage"] == "summarizing" and row["note_path"]
    return row


def retry(client, conv_id: str, request_id: str | None = None):
    return client.post(f"/v1/conversations/{conv_id}/retry", json={"request_id": request_id or str(uuid.uuid4())}, headers=AUTH)


def op(client, op_id: str) -> dict:
    r = client.get(f"/v1/operations/{op_id}", headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()["operation"]


def op_file(settings, op_id: str) -> dict:
    return json.loads((settings.vault_dir / "_omi" / "operations" / f"{op_id}.json").read_text())


def write_op(settings, op: dict) -> None:
    folder = settings.vault_dir / "_omi" / "operations"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{op['id']}.json").write_text(json.dumps(op))


def record(worker, conv_id: str) -> dict:
    return json.loads((worker.pipeline.conv_dir(conv_id) / "conversation.json").read_text())


def reopen(settings, llm=None):
    """A fresh process on the same vault after the index was deleted (it rebuilds)."""
    shutil.rmtree(settings.index_dir)
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    if llm is not None:
        worker.providers._llm = llm
    for t in range(5):  # the replay after a rebuild, then normal ticks
        worker.tick(T0 + 1000 + t)
    return client, worker


def test_retry_of_a_failed_summary_is_durable_and_closed_by_its_attempt(client, worker, settings):
    row = failed_summary(client, worker)
    r = retry(client, row["id"], rid := str(uuid.uuid4()))
    assert r.status_code == 202 and r.json()["operation"]["state"] == "queued", r.text
    assert json.loads((settings.vault_dir / "_omi" / "VAULT.json").read_text())["format"] == 2
    stored = json.loads((settings.vault_dir / "_omi" / "operations" / f"{rid}.json").read_text())
    assert stored["state"] == "accepted" and stored["stage"] == "summarizing" and stored["conversation_id"] == row["id"]
    assert record(worker, row["id"])["retry"] == {"op": rid, "stage": "summarizing"}

    worker.providers._llm = llm = CountingLlm()
    worker.tick(T0 + 500)
    (after,) = convs(worker)
    assert after["status"] == "done" and "status: completed" in note_text(settings, after) and llm.calls == 1
    assert op(client, rid)["state"] == "done"
    rec = record(worker, row["id"])
    assert "retry" not in rec and rec["retry_outcome"]["op"] == rid and rec["retry_outcome"]["status"] == "done"
    assert json.loads((settings.vault_dir / "_omi" / "operations" / f"{rid}.json").read_text())["state"] == "done"


def test_repeated_and_conflicting_request_ids(client, worker):
    row = failed_summary(client, worker)
    rid = str(uuid.uuid4())
    assert retry(client, row["id"], rid).status_code == 202
    again = retry(client, row["id"], rid)
    assert again.status_code == 200 and again.json()["operation"]["id"] == rid
    other = retry(client, row["id"])
    assert other.status_code == 409 and other.json()["error"] == "retry_in_progress"
    assert retry(client, str(uuid.uuid4()), rid).json()["error"] == "request_conflict"
    assert retry(client, row["id"], "not-a-uuid").status_code == 422
    assert client.post(f"/v1/conversations/{row['id']}/resummarize", headers=AUTH).json()["error"] == "retry_in_progress"


def test_only_failed_unfrozen_unconflicted_conversations_can_be_retried(client, worker):
    replay(client, SPEECH)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert retry(client, row["id"]).json()["error"] == "not_failed"
    worker.db.execute("UPDATE conversations SET status='failed', failed_stage='summarizing', frozen=1 WHERE id=?", (row["id"],))
    assert retry(client, row["id"]).json()["error"] == "note_frozen"
    worker.db.execute("UPDATE conversations SET frozen=0, edited=1 WHERE id=?", (row["id"],))
    assert retry(client, row["id"]).json()["error"] == "note_conflict"
    worker.db.set_meta("read_only", "divergence")
    assert retry(client, row["id"]).status_code == 503


def test_a_retry_that_fails_again_is_failed_once_without_looping(client, worker, settings):
    row = failed_summary(client, worker)
    rid = retry(client, row["id"]).json()["operation"]["id"]
    worker.tick(T0 + 500)
    llm = worker.providers._llm
    assert op(client, rid)["state"] == "failed" and llm.calls == 2
    for t in range(3):
        worker.tick(T0 + 600 + t)
    assert llm.calls == 2 and convs(worker)[0]["status"] == "failed"
    outcome = record(worker, row["id"])["retry_outcome"]
    assert outcome["op"] == rid and outcome["status"] == "failed" and outcome["failure_kind"] == "auth"
    assert outcome["finished_at"] >= op_file(settings, rid)["requested_at"]


def test_a_crash_between_the_operation_and_the_record_is_repaired(client, worker, settings):
    row = failed_summary(client, worker)
    rid = str(uuid.uuid4())
    # the operation file was written, then the process died before conversation.json/index changed
    write_op(settings, orphan(row, rid))
    assert op(client, rid)["state"] == "accepted"  # observing never repairs
    assert record(worker, row["id"]).get("retry") is None
    worker.providers._llm = CountingLlm()
    worker.tick(T0 + 500)  # the sweep queues it again; the next pipeline pass runs it
    worker.tick(T0 + 501)
    assert op(client, rid)["state"] == "done" and convs(worker)[0]["status"] == "done"


def test_an_orphan_for_a_different_failure_is_superseded(client, worker, settings):
    row = failed_summary(client, worker)
    rid = str(uuid.uuid4())
    write_op(settings, orphan(row, rid, failure_id="another-attempt", record_sha="0" * 64))
    worker.tick(T0 + 500)
    assert op(client, rid)["state"] == "superseded" and convs(worker)[0]["status"] == "failed"
    assert worker.providers._llm.calls == 1


def test_a_rebuild_before_the_worker_consumed_the_retry_keeps_it(client, worker, settings):
    row = failed_summary(client, worker)
    rid = retry(client, row["id"]).json()["operation"]["id"]
    client, worker = reopen(settings)
    assert op(client, rid)["state"] in ("queued", "done")
    worker.tick(T0 + 2000)
    assert op(client, rid)["state"] == "done" and convs(worker)[0]["status"] == "done"


def test_a_rebuild_mid_retry_requeues_the_stage_instead_of_calling_it_done(client, worker, settings):
    row = failed_summary(client, worker)
    rid = retry(client, row["id"]).json()["operation"]["id"]
    worker.providers._llm = CountingLlm(ProviderError("overloaded", kind="transient"))
    worker.tick(T0 + 500)  # consumed: the record lost its failure, the attempt is backing off
    assert "failure" not in record(worker, row["id"]) or record(worker, row["id"])["failure"] is None
    assert op(client, rid)["state"] == "backing_off"
    client, worker = reopen(settings, CountingLlm(ProviderError("still overloaded", kind="transient")))
    (rebuilt,) = convs(worker)
    assert rebuilt["status"] == "summarizing" and rebuilt["retry_op"] == rid
    assert op(client, rid)["state"] == "backing_off"  # the old transcript-only note is not success
    worker.providers._llm = CountingLlm()
    worker.tick(T0 + 9000)
    assert op(client, rid)["state"] == "done" and "status: completed" in note_text(settings, convs(worker)[0])


def test_a_finished_failure_is_not_retried_again_after_a_crash_and_rebuild(client, worker, settings, monkeypatch):
    row = failed_summary(client, worker)
    rid = retry(client, row["id"]).json()["operation"]["id"]
    monkeypatch.setattr(operations, "_close", lambda vault, outcome: None)  # dies before closing the file
    worker.tick(T0 + 500)
    monkeypatch.undo()
    assert json.loads((settings.vault_dir / "_omi" / "operations" / f"{rid}.json").read_text())["state"] == "accepted"
    client, worker = reopen(settings, llm := CountingLlm())
    worker.tick(T0 + 5000)
    assert op(client, rid)["state"] == "failed" and llm.calls == 0


def test_a_failed_retranscription_redoes_transcription_even_with_an_older_transcript(client, worker):
    replay(client, SPEECH)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    worker.pipeline._commit(row["id"], status="failed", failed_stage="transcribing", error_kind="transient", error="x")
    for cached in worker.pipeline.conv_dir(row["id"]).glob("stt-*.json"):
        cached.unlink()  # so the retried stage has to reach the provider

    class FailingStt(FakeStt):
        calls = 0

        def transcribe(self, request):
            FailingStt.calls += 1
            raise ProviderError("gpu busy", kind="transient")

    worker.providers._stt = FailingStt()
    rid = retry(client, row["id"]).json()["operation"]["id"]
    worker.tick(T0 + 500)
    assert FailingStt.calls == 1 and convs(worker)[0]["status"] == "transcribing"
    assert op(client, rid)["state"] == "backing_off"


def test_failed_chunks_can_be_queued_again(client, worker):
    replay(client, SPEECH)
    worker.db.execute("UPDATE chunks SET status='failed', attempts=5 WHERE rowid IN (SELECT rowid FROM chunks LIMIT 1)")
    r = client.post("/v1/chunks/retry", headers=AUTH)
    assert r.status_code == 200 and r.json() == {"chunks_queued": 1}
    assert worker.db.one("SELECT COUNT(*) AS n FROM chunks WHERE status='failed'")["n"] == 0


@pytest.mark.parametrize("path", ["/v1/operations/not-a-uuid", f"/v1/operations/{uuid.uuid4()}"])
def test_unknown_operations_are_404(client, path):
    assert client.get(path, headers=AUTH).status_code == 404


def orphan(row, rid: str, **extra) -> dict:
    return {"format": 1, "id": rid, "kind": "retry", "conversation_id": row["id"], "stage": "summarizing",
            "failure_kind": "auth", "failure_id": row["failure_id"], "record_sha": row["record_sha"],
            "requested_at": T0, "state": "accepted"} | extra  # fmt: skip


def test_an_orphan_for_another_attempt_with_identical_bytes_is_superseded(client, worker, settings):
    row = failed_summary(client, worker)
    rid = str(uuid.uuid4())
    write_op(settings, orphan(row, rid, failure_id="an-earlier-attempt"))
    worker.tick(T0 + 500)
    assert op(client, rid)["state"] == "superseded" and worker.providers._llm.calls == 1


@pytest.mark.parametrize("content", ["[]", "{not json", json.dumps({"id": "other", "kind": "retry"})])
def test_a_malformed_operation_is_reported_and_never_overwritten(client, worker, settings, content):
    row = failed_summary(client, worker)
    rid = str(uuid.uuid4())
    path = settings.vault_dir / "_omi" / "operations" / f"{rid}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    r = retry(client, row["id"], rid)
    assert r.status_code == 500 and r.json()["error"] == "operation_unreadable"
    assert path.read_text() == content and convs(worker)[0]["retry_op"] is None
    worker.tick(T0 + 500)  # the sweep skips it and carries on
    assert path.read_text() == content


def test_a_missing_receipt_is_written_again_from_the_recorded_outcome(client, worker, settings):
    row = failed_summary(client, worker)
    rid = retry(client, row["id"]).json()["operation"]["id"]
    worker.tick(T0 + 500)  # fails again: outcome recorded, receipt closed
    (settings.vault_dir / "_omi" / "operations" / f"{rid}.json").unlink()
    second = retry(client, row["id"])  # closing the previous receipt comes first
    assert second.status_code == 202
    assert op_file(settings, rid)["state"] == "failed" and op_file(settings, rid)["reconstructed"] is True


def test_a_repeated_request_is_not_confirmed_until_it_is_queued(client, worker, settings):
    row = failed_summary(client, worker)
    rid = str(uuid.uuid4())
    write_op(settings, orphan(row, rid))
    token = worker.pipeline.claim(row["id"])  # the worker holds the conversation
    r = retry(client, row["id"], rid)
    assert r.status_code == 409 and r.json()["error"] == "busy"
    worker.pipeline.release(row["id"], token)
    r = retry(client, row["id"], rid)
    assert r.status_code == 200 and r.json()["operation"]["state"] == "queued"


def test_freezing_the_note_during_a_retry_stops_it_without_looping(client, worker, settings):
    row = failed_summary(client, worker)
    rid = retry(client, row["id"]).json()["operation"]["id"]
    worker.providers._llm = CountingLlm(ProviderError("overloaded", kind="transient"))
    worker.tick(T0 + 500)
    assert op(client, rid)["state"] == "backing_off"
    worker.db.execute("UPDATE conversations SET frozen=1 WHERE id=?", (row["id"],))
    assert op(client, rid)["state"] == "blocked"
    worker.providers._llm = CountingLlm()
    worker.tick(T0 + 5000)
    (after,) = convs(worker)
    assert op(client, rid)["state"] == "stopped" and after["retry_op"] is None and after["status"] == "done"
    assert worker.pipeline.run(T0 + 5001) == 0  # nothing left in the queue


def test_other_enqueues_leave_a_pending_retry_alone(client, worker, settings):
    row = failed_summary(client, worker)
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1 WHERE id=?", (row["id"],))
    assert retry(client, row["id"]).json()["error"] == "busy"  # a reprocess is already queued
    worker.tick(T0 + 450)
    worker.db.execute("UPDATE conversations SET status='failed', failed_stage='summarizing' WHERE id=?", (row["id"],))
    rid = retry(client, row["id"]).json()["operation"]["id"]
    from typer.testing import CliRunner

    from omi_notes.cli import app as cli

    from .conftest import cli_env

    out = CliRunner().invoke(cli, ["reprocess", row["id"], "--force-llm"], env=cli_env(settings)).output
    assert "Skipped 1" in out and convs(worker)[0]["force_llm"] == 0
    # retry-failed leaves it to the retry (which it then runs inline, as the worker would)
    assert "Queued 0 conversation" in CliRunner().invoke(cli, ["retry-failed"], env=cli_env(settings)).output
    assert op(client, rid)["state"] == "done" and convs(worker)[0]["force_llm"] == 0


def test_the_sweep_rotates_past_stuck_operations(client, worker, settings, monkeypatch):
    row = failed_summary(client, worker)
    monkeypatch.setattr(operations, "SWEEP_BATCH", 3)
    for _ in range(5):  # operations for a conversation that isn't there: never settled
        write_op(settings, {"format": 1, "id": "0" + str(uuid.uuid4())[1:], "kind": "retry", "stage": "summarizing",
                            "conversation_id": str(uuid.uuid4()), "state": "accepted", "requested_at": T0,
                            "failure_id": None, "record_sha": None})  # fmt: skip
    rid = "f" + str(uuid.uuid4())[1:]  # sorts last
    write_op(settings, orphan(row, rid))
    worker.providers._llm = CountingLlm()
    for t in range(4):
        worker.tick(T0 + 500 + t)
    assert op(client, rid)["state"] == "done"


def test_a_note_frozen_before_the_retry_ran_stops_it_without_calling_the_provider(client, worker):
    row = failed_summary(client, worker)
    rid = retry(client, row["id"]).json()["operation"]["id"]
    worker.db.execute("UPDATE conversations SET frozen=1 WHERE id=?", (row["id"],))
    worker.providers._llm = llm = CountingLlm()
    worker.tick(T0 + 500)
    assert op(client, rid)["state"] == "stopped" and llm.calls == 0 and convs(worker)[0]["retry_op"] is None


def test_a_repeat_of_a_finished_retry_whose_receipt_was_lost_is_not_run_again(client, worker, settings):
    row = failed_summary(client, worker)
    rid = retry(client, row["id"]).json()["operation"]["id"]
    worker.tick(T0 + 500)  # fails again
    (settings.vault_dir / "_omi" / "operations" / f"{rid}.json").unlink()
    llm = worker.providers._llm
    r = retry(client, row["id"], rid)
    assert r.status_code == 200 and r.json()["operation"]["state"] == "failed"
    worker.tick(T0 + 600)
    assert llm.calls == 2 and convs(worker)[0]["retry_op"] is None


@pytest.mark.parametrize("op_body", [
    {"id": "X", "kind": "retry", "conversation_id": "c", "state": "accepted", "requested_at": 1},  # no format
    {"format": 1, "id": "X", "kind": "retry", "conversation_id": "c", "state": "weird", "requested_at": 1},
    {"format": 1, "id": "X", "kind": "retry", "conversation_id": "c", "state": "accepted"},  # no requested_at
    {"format": 1, "id": "X", "kind": "retry", "conversation_id": "c", "state": "accepted", "requested_at": 1,
     "stage": "dancing", "failure_id": None, "record_sha": None},
    {"format": 1, "id": "X", "kind": "retry", "conversation_id": "c", "state": "accepted", "requested_at": 1,
     "stage": "summarizing"},  # no failure binding
])  # fmt: skip
def test_invalid_operation_files_are_rejected(settings, op_body):
    from omi_notes.vault import Vault

    vault = Vault.open(settings)
    rid = str(uuid.uuid4())
    write_op(settings, op_body | {"id": rid})
    with pytest.raises(operations.OperationCorrupt):
        operations.read(vault, rid)


def test_an_orphan_waits_for_other_queued_work_instead_of_merging_with_it(client, worker, settings):
    row = failed_summary(client, worker)
    rid = str(uuid.uuid4())
    write_op(settings, orphan(row, rid))  # accepted, then a crash before the record got `retry`
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_llm = 1 WHERE id=?",
                      (row["id"],))  # a CLI `reprocess --force-llm` meanwhile  # fmt: skip
    worker.tick(T0 + 500)  # the forced reprocess runs alone (and fails again with a new attempt id)
    assert convs(worker)[0]["retry_op"] is None
    worker.tick(T0 + 501)
    assert op(client, rid)["state"] == "superseded"
