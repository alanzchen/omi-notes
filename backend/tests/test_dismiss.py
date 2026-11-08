"""Dismissing a failed conversation from the phone (`POST /v1/conversations/{id}/dismiss`).

A failure that keeps failing (the only permanent transcription failure, transcribe502-20261108,
stayed on the phone with nothing to do but Retry) can be set aside: the owner's decision is recorded
in conversation.json as `resolution: {kind: "dismissed", failure: …}`. The conversation stays failed,
its audio stays (failed conversations pin their chunks), Retry stays possible, and a later failure
of a retry shows up again. Nothing is deleted."""

from __future__ import annotations

import uuid

from .conftest import AUTH
from .helpers import T0, convs
from .test_keep_unknown_speakers import failed_issues, get
from .test_retry import failed_summary, record, reopen, retry


def dismiss(client, conv_id: str, request_id: str | None = None):
    return client.post(f"/v1/conversations/{conv_id}/dismiss", json={"request_id": request_id or str(uuid.uuid4())}, headers=AUTH)


def test_the_server_offers_dismiss_on_a_failed_conversation(client, worker):
    assert "dismiss" in get(client, "/v1/status")["features"]
    row = failed_summary(client, worker)
    (issue,) = failed_issues(client)
    assert issue["conversation_id"] == row["id"] and issue["can_dismiss"] is True


def test_dismissing_hides_the_failure_keeps_everything_and_survives_a_rebuild(client, worker, settings):
    row = failed_summary(client, worker)
    chunk_files = sorted(p.name for p in (settings.vault_dir / "_omi" / "raw").rglob("*.omnc"))
    r = dismiss(client, row["id"], rid := str(uuid.uuid4()))
    assert r.status_code == 200, r.text
    assert r.json()["dismissed"]["conversation_id"] == row["id"]
    assert failed_issues(client) == []
    assert get(client, "/v1/status")["queue"]["conversations_failed"] == 0, "the phone's count agrees"
    (after,) = convs(worker)
    assert after["status"] == "failed", "still failed: dismissed is not done"
    res = record(worker, row["id"])["resolution"]
    assert res["kind"] == "dismissed" and res["op"] == rid and res["failure"]["id"] == row["failure_id"]
    assert sorted(p.name for p in (settings.vault_dir / "_omi" / "raw").rglob("*.omnc")) == chunk_files, "audio kept"
    assert get(client, f"/v1/conversations/{row['id']}")["id"] == row["id"]
    again = dismiss(client, row["id"], rid)
    assert again.status_code == 200, "the same request is answered again"

    client, worker = reopen(settings)
    assert failed_issues(client) == [], "the decision is in the vault, not only the index"


def test_only_a_failed_conversation_without_a_queued_retry_can_be_dismissed(client, worker):
    row = failed_summary(client, worker)
    assert dismiss(client, row["id"], "not-a-uuid").status_code == 422
    assert dismiss(client, str(uuid.uuid4())).status_code == 404
    assert retry(client, row["id"]).status_code == 202
    assert dismiss(client, row["id"]).json()["error"] == "retry_in_progress"


def test_a_retry_after_dismissing_that_fails_again_is_shown_again(client, worker):
    row = failed_summary(client, worker)
    assert dismiss(client, row["id"]).status_code == 200
    assert retry(client, row["id"]).status_code == 202, "Retry stays possible"
    worker.tick(T0 + 500)  # the provider still refuses
    (after,) = convs(worker)
    assert after["status"] == "failed" and after["failure_id"] != row["failure_id"]
    assert [i["conversation_id"] for i in failed_issues(client)] == [row["id"]], "a new failure isn't hidden"
