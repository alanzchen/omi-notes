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


def test_an_old_dismiss_request_never_dismisses_a_newer_failure(client, worker, settings):
    """ASTRA-IT1-04: dismiss F1 with A, then B; a retry fails as F2; replaying A must answer A's
    original decision (about F1) and leave F2 listed, also after a rebuild."""
    row = failed_summary(client, worker)
    a, b = str(uuid.uuid4()), str(uuid.uuid4())
    assert dismiss(client, row["id"], a).status_code == 200
    assert dismiss(client, row["id"], b).status_code == 200
    assert retry(client, row["id"]).status_code == 202
    worker.tick(T0 + 500)
    (after,) = convs(worker)
    assert after["failure_id"] != row["failure_id"]
    replay = dismiss(client, row["id"], a)
    assert replay.status_code == 200 and replay.json()["dismissed"]["failure_id"] == row["failure_id"]
    assert [i["conversation_id"] for i in failed_issues(client)] == [row["id"]], "F2 stays listed"
    client, worker = reopen(settings)
    assert dismiss(client, row["id"], b).json()["dismissed"]["failure_id"] == row["failure_id"]
    assert [i["conversation_id"] for i in failed_issues(client)] == [row["id"]], "and after a rebuild"



def test_an_evicted_or_unknown_request_never_dismisses_a_different_failure(client, worker, settings):
    """ASTRA-IT3-02: 51 dismiss requests for F1 pushed the first one out of a 50-entry history; after a
    retry failed as F2 and a rebuild, replaying it dismissed F2. Every request is now remembered, and a
    request naming the failure it saw acts only on that failure."""
    row = failed_summary(client, worker)
    ids = [f"00000000-0000-4000-8000-{i:012d}" for i in range(51)]
    for rid in ids:
        assert dismiss(client, row["id"], rid).status_code == 200
    assert retry(client, row["id"]).status_code == 202
    worker.tick(T0 + 500)
    (after,) = convs(worker)
    assert after["failure_id"] != row["failure_id"]
    client, worker = reopen(settings)
    replay = dismiss(client, row["id"], ids[0])
    assert replay.status_code == 200 and replay.json()["dismissed"]["failure_id"] == row["failure_id"]
    assert [i["conversation_id"] for i in failed_issues(client)] == [row["id"]], "F2 stays listed"
    # a new request naming the old failure is refused; naming the current one works
    stale = client.post(f"/v1/conversations/{row['id']}/dismiss", headers=AUTH,
                        json={"request_id": str(uuid.uuid4()), "failure_id": row["failure_id"]})
    assert stale.status_code == 409 and stale.json()["error"] == "failure_changed"
    (issue,) = failed_issues(client)
    assert issue["failure_id"] == after["failure_id"]
    fresh = client.post(f"/v1/conversations/{row['id']}/dismiss", headers=AUTH,
                        json={"request_id": str(uuid.uuid4()), "failure_id": issue["failure_id"]})
    assert fresh.status_code == 200 and failed_issues(client) == []


def test_malformed_dismiss_bodies_are_422(client, worker):
    row = failed_summary(client, worker)
    url = f"/v1/conversations/{row['id']}/dismiss"
    for body in [[], {}, {"request_id": None}, {"request_id": 12}, {"request_id": "invalid"},
                 {"request_id": str(uuid.uuid4()), "failure_id": 5}, {"request_id": str(uuid.uuid4()), "failure_id": ""}]:
        assert client.post(url, json=body, headers=AUTH).status_code == 422, body


def test_past_the_history_cap_only_requests_naming_their_failure_are_taken(client, worker, monkeypatch):
    from omi_notes import operations

    monkeypatch.setattr(operations, "DISMISS_HISTORY", 3)
    row = failed_summary(client, worker)
    url = f"/v1/conversations/{row['id']}/dismiss"
    for _ in range(3):
        assert dismiss(client, row["id"]).status_code == 200
    refused = dismiss(client, row["id"])
    assert refused.status_code == 409 and refused.json()["error"] == "failure_id_required"
    for _ in range(3):  # named requests are taken, and only they are ever forgotten
        named = client.post(url, headers=AUTH, json={"request_id": str(uuid.uuid4()), "failure_id": row["failure_id"]})
        assert named.status_code == 200
    kept = record(worker, row["id"])["resolution"]["requests"]
    assert sum(1 for v in kept.values() if not v.get("bound")) == 3, "every unnamed request is still remembered"


def test_a_keep_never_erases_what_earlier_dismissals_were_for(tmp_path, monkeypatch):
    """ASTRA-IT5-01: Keep replaced `resolution` and with it the dismiss ledger. Unnamed request A
    dismissed F1; Retry failed as F2; Keep; the kept attempt failed as F3; after a rebuild, replaying A
    answered for F3 and hid it. The ledger now survives every resolution rewrite and rebuild."""
    from omi_notes import operations

    from .test_keep_unknown_speakers import keep, unseparated
    from .test_retry import reopen as reopen_vault

    settings, client, worker, row, _, _ = unseparated(tmp_path)
    a = str(uuid.uuid4())
    assert dismiss(client, row["id"], a).status_code == 200
    assert retry(client, row["id"]).status_code == 202
    worker.tick(T0 + 300)
    (f2,) = convs(worker)
    assert f2["status"] == "failed" and f2["failure_id"] != row["failure_id"]
    assert keep(client, row["id"]).status_code == 202
    from omi_notes.providers import ProviderError

    def gone(r):
        raise ProviderError("synthetic: raw audio unavailable", terminal=True, kind="audio")
    monkeypatch.setattr(worker.pipeline, "conversation_audio", gone)
    worker.tick(T0 + 400)
    (f3,) = convs(worker)
    assert f3["status"] == "failed" and f3["failure_id"] not in (row["failure_id"], f2["failure_id"])
    assert record(worker, row["id"])["resolution"]["requests"][a]["failure_id"] == row["failure_id"], "kept through Keep"
    client, worker = reopen_vault(settings)
    replay_a = dismiss(client, row["id"], a)
    assert replay_a.status_code == 200 and replay_a.json()["dismissed"]["failure_id"] == row["failure_id"]
    assert row["id"] in [i["conversation_id"] for i in failed_issues(client)], "F3 stays listed"
    # the cap on unnamed requests counts the same history across the Keep
    monkeypatch.setattr(operations, "DISMISS_HISTORY", 1)
    refused = dismiss(client, row["id"])
    assert refused.status_code == 409 and refused.json()["error"] == "failure_id_required"
