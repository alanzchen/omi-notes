"""Keeping a conversation whose speakers couldn't be separated (`POST /v1/conversations/{id}/keep`).

A `speakers_unknown` failure is an incomplete result, not an outage: the phone's owner can keep the
automated text with the speaker explicitly unknown. The decision is a durable operation recorded in
conversation.json, so it survives a rebuild; nothing is deleted and no speaker is invented."""

from __future__ import annotations

import json
import shutil
import uuid

import numpy as np
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.devtools import synth_speech_like
from omi_notes.pipeline.worker import Worker
from omi_notes.providers import ProviderError

from .conftest import AUTH
from .helpers import T0, convs, note_text, replay, silence
from .test_retry import CountingLlm, failed_summary, write_op
from .test_speakers import NoTurnsDiarizer, pipeline, text_only

SPEECH = np.concatenate([silence(1), synth_speech_like(12), silence(2)])
WORDS = "Remind me to call the dentist tomorrow."


def unseparated(tmp_path):
    settings, client, worker = pipeline(tmp_path, stt_diarization="local")
    seen: list = []
    worker.providers._stt = text_only(seen, WORDS)
    worker.providers._diarizer = NoTurnsDiarizer()
    worker.providers._llm = llm = CountingLlm()
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "failed" and row["error_kind"] == "speakers_unknown"
    return settings, client, worker, row, seen, llm


def keep(client, conv_id: str, request_id: str | None = None):
    return client.post(f"/v1/conversations/{conv_id}/keep", json={"request_id": request_id or str(uuid.uuid4())}, headers=AUTH)


def get(client, path: str) -> dict:
    r = client.get(path, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()


def failed_issues(client) -> list[dict]:
    return [i for i in get(client, "/v1/issues")["issues"] if i["code"] == "conversation_failed"]


def record(worker, conv_id: str) -> dict:
    return json.loads((worker.pipeline.conv_dir(conv_id) / "conversation.json").read_text())


def test_an_unresolved_no_speaker_result_offers_keep_and_says_nothing_it_cannot_know(tmp_path):
    _, client, worker, row, _, _ = unseparated(tmp_path)
    (issue,) = failed_issues(client)
    assert issue["can_keep"] is True and issue["retryable"] is False
    # the generic message has no per-record duration: no "very short", and no "only a model update fixes it"
    assert "short" not in issue["message"] and "kept" in issue["message"]
    assert "model" not in issue["next_step"] and "update" not in issue["next_step"]
    assert get(client, "/v1/status")["queue"]["conversations_failed"] == 1


def test_keeping_makes_a_transcript_only_note_with_the_speaker_unknown_and_clears_the_failure(tmp_path):
    settings, client, worker, row, seen, llm = unseparated(tmp_path)
    r = keep(client, row["id"], rid := str(uuid.uuid4()))
    assert r.status_code == 202, r.text
    assert r.json()["operation"]["kind"] == "keep" and r.json()["operation"]["state"] == "queued"
    rec = record(worker, row["id"])
    assert rec["resolution"]["kind"] == "kept_speaker_unknown" and rec["resolution"]["op"] == rid
    assert rec["resolution"]["failure"]["kind"] == "speakers_unknown"
    # an older backend would drop `resolution` when it rewrote the record: it must refuse the vault
    assert json.loads((settings.vault_dir / "_omi" / "VAULT.json").read_text())["format"] == 3

    worker.tick(T0 + 300)
    (after,) = convs(worker)
    assert after["status"] == "done" and after["note_path"]
    assert len(seen) == 1 and llm.calls == 0  # the cached text is reused; nothing is summarized
    note = note_text(settings, after)
    assert "status: transcript_only" in note and WORDS in note and "speaker is unknown" in note
    assert "Speaker 1" not in note and "**Speakers:** unknown" in note
    assert not worker.db.query("SELECT 1 FROM speaker_labels WHERE conversation_id=?", (row["id"],))
    assert get(client, f"/v1/operations/{rid}")["operation"]["state"] == "done"
    # the raw audio is still there
    chunks = worker.db.query("SELECT path, raw_deleted FROM chunks")
    assert chunks and all(not c["raw_deleted"] and (settings.vault_dir / c["path"]).exists() for c in chunks)

    assert failed_issues(client) == [] and get(client, "/v1/status")["queue"]["conversations_failed"] == 0
    detail = get(client, f"/v1/conversations/{row['id']}")
    assert detail["state"]["code"] == "kept_speaker_unknown" and detail["speakers_ready"] is False
    assert detail["summary_state"] == "not_applicable" and detail["transcript_state"] == "ready"
    assert {s["speaker"] for s in detail["transcript"]["segments"]} == {"unknown"}
    res = detail["resolution"]
    assert res["kind"] == "kept_speaker_unknown" and res["resolved_at"]
    assert res["original"]["code"] == "speakers_unknown" and "speaker" in res["original"]["message"]
    assert detail["speech_s"] > 0 and detail["duration_s"] >= detail["speech_s"]


def test_a_kept_result_survives_a_rebuild_without_calling_any_provider(tmp_path):
    settings, client, worker, row, seen, llm = unseparated(tmp_path)
    assert keep(client, row["id"]).status_code == 202
    worker.tick(T0 + 300)
    before = note_text(settings, convs(worker)[0])

    shutil.rmtree(settings.index_dir)
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    worker.providers._stt = text_only(seen, WORDS)
    worker.providers._diarizer = NoTurnsDiarizer()
    worker.providers._llm = llm
    for t in range(5):
        worker.tick(T0 + 1000 + t)
    (after,) = convs(worker)
    assert after["status"] == "done" and note_text(settings, after) == before
    assert len(seen) == 1 and llm.calls == 0
    assert failed_issues(client) == [] and get(client, "/v1/status")["queue"]["conversations_failed"] == 0
    assert get(client, f"/v1/conversations/{row['id']}")["resolution"]["original"]["code"] == "speakers_unknown"


def test_keep_is_idempotent_by_request_id(tmp_path):
    _, client, worker, row, _, _ = unseparated(tmp_path)
    rid = str(uuid.uuid4())
    assert keep(client, row["id"], rid).status_code == 202
    again = keep(client, row["id"], rid)
    assert again.status_code == 200 and again.json()["operation"]["id"] == rid
    worker.tick(T0 + 300)
    assert keep(client, row["id"], rid).json()["operation"]["state"] == "done"
    # the same id can't be reused for a retry, and a finished keep can't be kept again
    assert client.post(f"/v1/conversations/{row['id']}/retry", json={"request_id": rid}, headers=AUTH).status_code == 409
    assert keep(client, row["id"]).status_code == 409


def test_genuine_failures_are_not_keepable_and_stay_listed(client, worker):
    row = failed_summary(client, worker)
    assert row["error_kind"] == "auth"
    r = keep(client, row["id"])
    assert r.status_code == 409 and r.json()["error"] == "not_keepable", r.text
    (issue,) = failed_issues(client)
    assert issue["retryable"] is True and not issue.get("can_keep")
    assert get(client, "/v1/status")["queue"]["conversations_failed"] == 1


def test_a_kept_conversation_that_then_fails_for_another_reason_is_listed_again(tmp_path):
    settings, client, worker, row, seen, llm = unseparated(tmp_path)
    for cached in worker.pipeline.conv_dir(row["id"]).glob("stt-*.json"):
        cached.unlink()  # the text must be fetched again, and the service is down
    worker.providers._stt.transcribe = lambda request: (_ for _ in ()).throw(
        ProviderError("bad key", terminal=True, kind="auth"))
    assert keep(client, row["id"]).status_code == 202
    worker.tick(T0 + 300)
    (after,) = convs(worker)
    assert after["status"] == "failed" and after["error_kind"] == "auth"
    (issue,) = failed_issues(client)
    assert issue["retryable"] is True and not issue.get("can_keep")


def test_a_keep_accepted_just_before_a_crash_is_still_carried_out(tmp_path):
    # the operation file was written, then the process died before the record got `retry`/`resolution`
    settings, client, worker, row, seen, llm = unseparated(tmp_path)
    rid = str(uuid.uuid4())
    write_op(settings, {"format": 1, "id": rid, "kind": "keep", "conversation_id": row["id"], "stage": "transcribing",
                        "failure_kind": "speakers_unknown", "failure_id": row["failure_id"], "record_sha": row["record_sha"],
                        "requested_at": T0 + 250, "state": "accepted"})  # fmt: skip
    for t in range(3):
        worker.tick(T0 + 300 + t)
    (after,) = convs(worker)
    assert after["status"] == "done" and record(worker, row["id"])["resolution"]["op"] == rid
    assert get(client, f"/v1/operations/{rid}")["operation"]["state"] == "done" and llm.calls == 0


def test_ordinary_records_are_unchanged_by_the_keep_support(client, worker):
    # a rebuild re-renders every note: records without the keep must stay byte-identical
    from .helpers import convs as rows

    replay(client, SPEECH)
    worker.tick(T0 + 400)
    (row,) = rows(worker)
    rec = record(worker, row["id"])
    assert "resolution" not in rec and "speakers_unknown" not in rec["render"]["index"]
