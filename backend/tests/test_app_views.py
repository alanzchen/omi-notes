"""The phone's read-only views: conversation detail, paginated recent list, issues, status."""

from __future__ import annotations

import hashlib
import json
from datetime import timedelta

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes import views
from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.devtools import synth_speech_like
from omi_notes.pipeline.worker import Worker

from .conftest import AUTH, make_settings
from .helpers import STARTED, T0, convs, replay, silence
from .test_pipeline import FailingLlm

SPEECH = np.concatenate([silence(1), synth_speech_like(12), silence(2)])


class Exploding:
    name = model = "exploding"
    cache_tag = ""

    def __getattr__(self, attr):
        raise AssertionError(f"a read-only view used a provider ({attr})")


def get(client, path: str):
    r = client.get(path, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()


def finished(client, worker, start=STARTED) -> dict:
    replay(client, SPEECH, start=start)
    worker.tick(start.timestamp() + 400)
    return next(r for r in convs(worker) if abs(r["start"] - start.timestamp()) < 60)


def problems(client) -> list[dict]:
    """Issues other than the worker's absence (these tests drive the worker by hand)."""
    return [i for i in get(client, "/v1/issues")["issues"] if i["code"] != "worker_stopped"]


def vault_state(settings) -> dict[str, str]:
    return {
        p.relative_to(settings.vault_dir).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(settings.vault_dir.rglob("*"))
        if p.is_file()
    }


def index_state(settings) -> list[str]:
    return list(Database(settings.db_path).conn().iterdump())


def test_done_conversation_detail_without_touching_providers_vault_or_index(client, worker, settings):
    row = finished(client, worker)
    pipeline = client.app.state.speakers.pipeline
    pipeline.providers._stt = pipeline.providers._llm = Exploding()
    before = (vault_state(settings), index_state(settings))

    body = get(client, f"/v1/conversations/{row['id']}")
    (listed,) = get(client, "/v1/conversations/recent")["conversations"]
    get(client, "/v1/issues")
    get(client, "/v1/status")
    assert (vault_state(settings), index_state(settings)) == before

    assert body["state"] == {"code": "ready", "message": "Note ready"} and body["status"] == "done"
    assert body["summary_state"] == "ready" and body["summary"]["overview"]
    assert body["transcript_state"] == "ready" and body["transcript"]["segments"][0]["text"]
    assert body["transcript"]["total"] == len(body["transcript"]["segments"]) and body["transcript"]["next_from"] is None
    assert [s["label"] for s in body["speakers"]] == sorted({s["speaker"] for s in body["transcript"]["segments"]})
    assert body["note_state"] == "matches" and body["my_notes"] is None and body["issues"] == []
    assert body["transcript_sha"] == row["transcript_sha"] and body["duration_s"] > 0
    assert listed["id"] == row["id"] and listed["preview"] and listed["state"]["code"] == "ready"
    assert listed["preview"] == body["preview"] and body["summary"]["overview"].startswith(listed["preview"].rstrip("…"))
    assert get(client, "/v1/status")["last_note_at"] is not None


def test_summary_failure_is_transcript_only_with_a_sanitized_reason(client, worker):
    worker.providers._llm = FailingLlm()
    row = finished(client, worker)
    body = get(client, f"/v1/conversations/{row['id']}")
    assert body["state"]["code"] == "transcript_only" and body["summary_state"] == "failed"
    assert body["transcript_state"] == "ready" and body["summary"] is None
    assert body["summary_error"] == "The summary service rejected the server's credentials."
    (issue,) = problems(client)
    assert issue["code"] == "conversation_failed" and issue["conversation_id"] == row["id"]
    assert "x-api-key" not in json.dumps(issue) and "retry-failed" in issue["next_step"]
    queue = get(client, "/v1/status")["queue"]
    assert queue["conversations_failed"] == 1 and queue["chunks_failed"] == 0 and queue["failed"] == 1


def test_disabled_summaries_are_not_a_failure(tmp_path):
    settings = make_settings(tmp_path, llm_provider="none")
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    row = finished(client, worker)
    body = get(client, f"/v1/conversations/{row['id']}")
    assert body["state"] == {"code": "transcript_only", "message": "Transcript ready; summaries are turned off"}
    assert body["summary_state"] == "disabled" and body["transcript_state"] == "ready"
    assert problems(client) == [] and get(client, "/v1/status")["llm"]["model"] is None


def test_open_conversation_is_200_with_state_and_unknown_is_404(client, worker, new_id):
    replay(client, SPEECH)
    worker.tick(T0 + 15)
    (row,) = convs(worker)
    assert row["status"] == "open"
    body = get(client, f"/v1/conversations/{row['id']}")
    assert body["state"]["code"] == "listening" and body["transcript"] is None and body["transcript_state"] == "pending"
    assert body["summary_state"] == "pending" and body["speakers_ready"] is False
    assert client.get(f"/v1/conversations/{new_id()}", headers=AUTH).status_code == 404


def test_artifacts_of_another_generation_are_updating_not_mixed(client, worker):
    row = finished(client, worker)
    conv_dir = worker.pipeline.conv_dir(row["id"])
    transcript = json.loads((conv_dir / "transcript.json").read_text())
    transcript["segments"][0]["text"] = "a newer transcription, not yet in the index"
    (conv_dir / "transcript.json").write_text(json.dumps(transcript))
    body = get(client, f"/v1/conversations/{row['id']}")
    assert body["transcript_state"] == "updating" and body["transcript"] is None and body["speakers"] == []
    assert body["summary_state"] == "ready"  # still made from the transcript the index names

    worker.db.execute("UPDATE conversations SET transcript_sha=? WHERE id=?", ("f" * 64, row["id"]))
    body = get(client, f"/v1/conversations/{row['id']}")
    assert body["summary_state"] == "updating" and body["summary"] is None


def test_corrupt_summary_file_is_unavailable_and_the_list_still_loads(client, worker):
    row = finished(client, worker)
    (worker.pipeline.conv_dir(row["id"]) / row["llm_ref"]).write_text("{not json")
    body = get(client, f"/v1/conversations/{row['id']}")
    assert body["summary_state"] == "unavailable" and body["transcript_state"] == "ready"
    (listed,) = get(client, "/v1/conversations/recent")["conversations"]
    assert listed["preview"] is None and listed["state"]["code"] == "ready"


def test_note_edits_are_detected_without_a_render_attempt(client, worker, settings):
    row = finished(client, worker)
    path = settings.vault_dir / row["note_path"]
    text = path.read_text().replace("<!-- my-notes:start -->\n\n", "<!-- my-notes:start -->\nCall Priya back.\n")
    path.write_text(text)
    body = get(client, f"/v1/conversations/{row['id']}")
    assert body["note_state"] == "matches" and body["my_notes"] == "Call Priya back."

    path.write_text(text.replace("## Transcript", "## Transcript (edited)", 1))
    assert get(client, f"/v1/conversations/{row['id']}")["note_state"] == "differs"

    path.write_text(text + "\n<!-- my-notes:start -->\n")
    body = get(client, f"/v1/conversations/{row['id']}")
    assert body["my_notes"] is None and body["my_notes_unreadable"] is True

    path.unlink()
    assert get(client, f"/v1/conversations/{row['id']}")["note_state"] == "missing"


def test_a_failed_reprocess_keeps_the_earlier_note_readable(client, worker):
    row = finished(client, worker)
    worker.db.execute("UPDATE conversations SET status='failed', failed_stage='transcribing', error_kind='transient', "
                      "error='boom' WHERE id=?", (row["id"],))  # fmt: skip
    body = get(client, f"/v1/conversations/{row['id']}")
    assert body["state"]["code"] == "ready" and body["summary_state"] == "ready"
    assert [i["code"] for i in body["issues"]] == ["reprocess_failed"] and "boom" not in json.dumps(body)


def test_note_conflicts_failed_chunks_and_missing_worker_are_issues(client, worker):
    row = finished(client, worker)
    worker.db.execute("UPDATE conversations SET edited=1 WHERE id=?", (row["id"],))
    worker.db.execute("UPDATE chunks SET status='failed' WHERE rowid IN (SELECT rowid FROM chunks LIMIT 1)")
    codes = [i["code"] for i in get(client, "/v1/issues")["issues"]]
    assert codes == ["worker_stopped", "chunks_failed", "note_conflict"]
    body = get(client, f"/v1/conversations/{row['id']}")
    assert [i["code"] for i in body["issues"]] == ["note_conflict"] and body["transcript_state"] == "ready"
    queue = get(client, "/v1/status")["queue"]
    assert queue["notes_conflicted"] == 1 and queue["chunks_failed"] == 1


def test_worker_presence_is_the_worker_lock(client, worker):
    assert get(client, "/v1/status")["worker"] == {"present": False}
    assert worker.lock.acquire()
    try:
        assert get(client, "/v1/status")["worker"] == {"present": True}
        assert "worker_stopped" not in [i["code"] for i in get(client, "/v1/issues")["issues"]]
    finally:
        worker.lock.release()


def test_recent_pages_by_cursor_and_rejects_bad_cursors(client, worker):
    starts = [STARTED + timedelta(minutes=10 * i) for i in range(3)]
    for start in starts:
        replay(client, SPEECH, start=start)
    worker.tick(starts[-1].timestamp() + 400)
    ids = [r["id"] for r in sorted(convs(worker), key=lambda r: r["start"], reverse=True)]
    assert len(ids) == 3

    first = get(client, "/v1/conversations/recent?limit=2")
    assert [c["id"] for c in first["conversations"]] == ids[:2] and first["next_cursor"]
    second = get(client, f"/v1/conversations/recent?limit=2&before={first['next_cursor']}")
    assert [c["id"] for c in second["conversations"]] == ids[2:] and second["next_cursor"] is None
    for bad in ("nan:x", "inf:x", "12", "abc:def", ":x"):
        r = client.get(f"/v1/conversations/recent?before={bad}", headers=AUTH)
        assert r.status_code == 422 and r.json()["error"] == "invalid_cursor"


def test_transcript_pages(client, worker, monkeypatch):
    row = finished(client, worker)
    total = get(client, f"/v1/conversations/{row['id']}")["transcript"]["total"]
    monkeypatch.setattr(views, "SEGMENT_PAGE", 1)
    page = get(client, f"/v1/conversations/{row['id']}")["transcript"]
    assert len(page["segments"]) == 1 and page["next_from"] == (1 if total > 1 else None)
    if total > 1:
        rest = get(client, f"/v1/conversations/{row['id']}?segments_from=1")["transcript"]
        assert rest["from"] == 1 and rest["segments"][0]["text"]


@pytest.mark.parametrize("kind, stage, text", [
    ("auth", "transcribing", "The transcription service rejected the server's credentials."),
    ("transient", "summarizing", "The summary service is temporarily unavailable."),
    (None, None, "The processing service failed."),
])  # fmt: skip
def test_failure_messages_are_chosen_by_kind(kind, stage, text):
    assert views.failure_message(kind, stage) == text


def test_guidance_follows_whether_the_server_will_retry(client, worker):
    row = finished(client, worker)
    worker.db.execute("UPDATE conversations SET status='failed', failed_stage='transcribing', error_kind='transient', "
                      "note_path=NULL, error='x' WHERE id=?", (row["id"],))  # fmt: skip
    (issue,) = problems(client)
    assert "stopped retrying" in issue["next_step"] and "retry-failed" in issue["next_step"]
    assert "retries on its own" not in issue["next_step"]
    worker.db.execute("UPDATE conversations SET status='transcribing', next_attempt_at=? WHERE id=?", (T0 + 999, row["id"]))
    (issue,) = problems(client)
    assert issue["code"] == "conversation_retrying" and issue["next_step"].startswith("The server retries on its own.")


def test_commands_name_this_deployment_and_the_full_id(client, worker, monkeypatch):
    monkeypatch.setenv("OMI_NOTES_ENV_FILE", "/Users/me/.config/omi-notes/server.env")
    row = finished(client, worker)
    worker.db.execute("UPDATE conversations SET edited=1 WHERE id=?", (row["id"],))
    (issue,) = problems(client)
    assert row["id"] in issue["next_step"] and "OMI_NOTES_ENV_FILE=/Users/me/.config/omi-notes/server.env" in issue["next_step"]


@pytest.mark.parametrize("content", [b"{not json", b"[1, 2]", b"\xff\xfe"])
def test_an_unreadable_speakers_file_costs_names_not_the_list(client, worker, content):
    row = finished(client, worker)
    (worker.pipeline.conv_dir(row["id"]) / "speakers.json").write_bytes(content)
    (listed,) = get(client, "/v1/conversations/recent")["conversations"]
    assert listed["id"] == row["id"] and listed["speaker_names"] == []
    body = get(client, f"/v1/conversations/{row['id']}")
    assert body["transcript_state"] == "ready" and all(s["name"] is None for s in body["speakers"])


def test_action_owners_use_the_name_the_note_was_rendered_with(client, worker):
    row = finished(client, worker)
    worker.db.execute("UPDATE conversations SET settings_json=? WHERE id=?",
                      (json.dumps({"timezone": "America/Chicago", "owner_name": "Alan"}), row["id"]))  # fmt: skip
    cached = worker.pipeline.conv_dir(row["id"]) / row["llm_ref"]
    data = json.loads(cached.read_text())
    data["data"]["action_items"] = [{"description": "Send the budget", "owner": "me"}]
    cached.write_text(json.dumps(data))
    (item,) = get(client, f"/v1/conversations/{row['id']}")["summary"]["action_items"]
    assert item == {"description": "Send the budget", "owner": "me", "owner_name": "Alan", "due_date": None}


def test_activity_reports_waiting_work_and_real_provider_calls(client, worker, settings):
    replay(client, SPEECH)
    worker.tick(T0 + 15)
    activity = get(client, "/v1/status")["activity"]
    assert activity["waiting"] == 0 and activity["stt"] is None and activity["running"] == []

    from omi_notes.telemetry import RecordingProviders

    worker.providers = worker.pipeline.providers = RecordingProviders(settings, db=worker.db)
    worker.tick(T0 + 400)
    activity = get(client, "/v1/status")["activity"]
    assert activity["stt"]["last_ok_at"] and activity["stt"]["last_error_at"] is None
    assert activity["llm"]["last_ok_at"]
    before = activity["stt"]["last_ok_at"]
    row = convs(worker)[0]
    worker.db.execute("UPDATE conversations SET status='closed' WHERE id=?", (row["id"],))
    worker.tick(T0 + 500)  # the cached transcription is reused: no provider request
    assert get(client, "/v1/status")["activity"]["stt"]["last_ok_at"] == before

    worker.db.execute("UPDATE conversations SET status='summarizing', error='x', next_attempt_at=? WHERE id=?",
                      (1e12, row["id"]))  # fmt: skip
    activity = get(client, "/v1/status")["activity"]
    assert activity["backing_off"] == 1 and activity["waiting"] == 0
