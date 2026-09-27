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


def test_a_retry_that_fails_again_is_failed_once_without_looping(client, worker):
    row = failed_summary(client, worker)
    rid = retry(client, row["id"]).json()["operation"]["id"]
    worker.tick(T0 + 500)
    llm = worker.providers._llm
    assert op(client, rid)["state"] == "failed" and llm.calls == 2
    for t in range(3):
        worker.tick(T0 + 600 + t)
    assert llm.calls == 2 and convs(worker)[0]["status"] == "failed"
    assert record(worker, row["id"])["retry_outcome"] == {"op": rid, "status": "failed", "failure_kind": "auth",
                                                          "finished_at": T0 + 500}  # fmt: skip


def test_a_crash_between_the_operation_and_the_record_is_repaired(client, worker, settings):
    row = failed_summary(client, worker)
    rid = str(uuid.uuid4())
    # the operation file was written, then the process died before conversation.json/index changed
    settings.vault_dir.joinpath("_omi", "operations").mkdir(parents=True, exist_ok=True)
    (settings.vault_dir / "_omi" / "operations" / f"{rid}.json").write_text(json.dumps({
        "format": 1, "id": rid, "kind": "retry", "conversation_id": row["id"], "stage": "summarizing",
        "failure_kind": "auth", "record_sha": row["record_sha"], "requested_at": T0, "state": "accepted"}))  # fmt: skip
    assert op(client, rid)["state"] == "accepted"  # observing never repairs
    assert record(worker, row["id"]).get("retry") is None
    worker.providers._llm = CountingLlm()
    worker.tick(T0 + 500)  # the sweep queues it again; the next pipeline pass runs it
    worker.tick(T0 + 501)
    assert op(client, rid)["state"] == "done" and convs(worker)[0]["status"] == "done"


def test_an_orphan_for_a_different_failure_is_superseded(client, worker, settings):
    row = failed_summary(client, worker)
    rid = str(uuid.uuid4())
    settings.vault_dir.joinpath("_omi", "operations").mkdir(parents=True, exist_ok=True)
    (settings.vault_dir / "_omi" / "operations" / f"{rid}.json").write_text(json.dumps({
        "format": 1, "id": rid, "kind": "retry", "conversation_id": row["id"], "stage": "summarizing",
        "failure_kind": "auth", "record_sha": "0" * 64, "requested_at": T0, "state": "accepted"}))  # fmt: skip
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
