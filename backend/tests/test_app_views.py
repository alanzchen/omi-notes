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
    assert "x-api-key" not in json.dumps(issue) and "retry-failed" in issue["server_step"]
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
    assert "stopped retrying" in issue["server_step"] and "retry-failed" in issue["server_step"]
    assert "retries on its own" not in issue["server_step"]
    worker.db.execute("UPDATE conversations SET status='transcribing', next_attempt_at=? WHERE id=?", (T0 + 999, row["id"]))
    (issue,) = problems(client)
    assert issue["code"] == "conversation_retrying" and issue["server_step"].startswith("The server retries on its own.")
    assert issue["next_step"].startswith("The server retries on its own") and issue["retryable"] is False


def test_commands_name_this_deployment_and_the_full_id(client, worker, monkeypatch):
    monkeypatch.setenv("OMI_NOTES_ENV_FILE", "/Users/me/.config/omi-notes/server.env")
    row = finished(client, worker)
    worker.db.execute("UPDATE conversations SET edited=1 WHERE id=?", (row["id"],))
    (issue,) = problems(client)
    assert row["id"] in issue["server_step"] and "OMI_NOTES_ENV_FILE=/Users/me/.config/omi-notes/server.env" in issue["server_step"]
    assert "`" not in issue["next_step"]


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


def test_stats_count_kept_conversations_per_local_day(client, worker, settings):
    from datetime import timedelta

    for i, start in enumerate([STARTED, STARTED + timedelta(days=1)]):
        replay(client, SPEECH, start=start)
    worker.tick(STARTED.timestamp() + 86400 + 400)
    rows = convs(worker)
    worker.db.execute("UPDATE conversations SET index_json=json_set(index_json, '$.kind', 'discarded') WHERE id=?",
                      (rows[0]["id"],))  # fmt: skip
    worker.db.execute("UPDATE conversations SET status='summarizing' WHERE id=?", (rows[1]["id"],))  # a retry keeps its note
    import omi_notes.views as v

    body = v.stats(worker.db, worker.pipeline.tz, 7, STARTED.timestamp() + 86400 * 2)
    assert len(body["days"]) == 7 and body["totals"]["conversations"] == 1
    (day,) = [d for d in body["days"] if d["conversations"]]
    assert day["date"] == (STARTED + timedelta(days=1)).astimezone(worker.pipeline.tz).date().isoformat()
    assert day["conversation_s"] > 0 and day["speech_s"] > 0 and day["people"] == 0
    assert get(client, "/v1/stats?days=500")["days"].__len__() == 90


def test_phone_guidance_is_plain_and_server_commands_are_separate(client, worker, monkeypatch):
    # The phone's owner usually can't run anything on the server: what the phone shows has no command
    # lines, and the operator's command (naming this deployment) travels separately.
    monkeypatch.setenv("OMI_NOTES_ENV_FILE", "/Users/me/.config/omi-notes/server.env")
    row = finished(client, worker)
    worker.db.execute("UPDATE conversations SET status='failed', failed_stage='transcribing', error_kind='transient', "
                      "note_path=NULL, error='x' WHERE id=?", (row["id"],))  # fmt: skip
    (issue,) = problems(client)
    assert "`" not in issue["next_step"] and "OMI_NOTES_ENV_FILE" not in issue["next_step"]
    assert "retry-failed" in issue["server_step"] and "/Users/me/.config/omi-notes/server.env" in issue["server_step"]
    assert issue["retryable"] is True


def test_no_speaker_failures_offer_keep_instead_of_a_futile_retry(client, worker):
    row = finished(client, worker)
    worker.db.execute("UPDATE conversations SET status='failed', failed_stage='transcribing', error_kind='speakers_unknown', "
                      "note_path=NULL, error='x' WHERE id=?", (row["id"],))  # fmt: skip
    (issue,) = problems(client)
    assert issue["code"] == "conversation_failed" and issue["retryable"] is False
    assert issue["can_keep"] is True and "kept" in issue["message"] and "short" not in issue["message"]
    assert "`" not in issue["next_step"] and "speaker unknown" in issue["next_step"]


def test_a_queued_retry_does_not_claim_the_server_is_down():
    from omi_notes import operations
    assert operations._MESSAGES["queued"] == "Queued on the server"


def _publish_transcript(worker, row, gaps, count=501):
    """Rewrites a finished conversation's transcript: `count` short segments 4 s apart, and these gaps."""
    import json as _json

    from omi_notes.util import canonical_json, sha256_hex

    path = worker.pipeline.conv_dir(row["id"]) / "transcript.json"
    doc = _json.loads(path.read_text())
    segments = [dict(doc["segments"][0], start=row["start"] + i * 4, end=row["start"] + i * 4 + 2) for i in range(count)]
    doc["segments"], doc["untranscribed"] = segments, gaps
    path.write_text(_json.dumps(doc))
    worker.db.execute("UPDATE conversations SET transcript_sha=? WHERE id=?", (sha256_hex(canonical_json(segments).encode()), row["id"]))


def test_each_transcript_page_carries_only_its_own_gaps_and_all_appear_once(client, worker):
    # ASTRA-20261115-IT2-02: every page carried the whole gap list (5,000 gaps on a one-segment page: 10,004 time
    # conversions, 416 KB). A page now carries the stretches it owns; across the pages each appears once
    row = finished(client, worker)
    s = row["start"]
    gaps = [[s - 3, s - 1, 2], [s + 6, s + 7, 1], [s + 1998, s + 1999, 1], [s + 2001, s + 2002, 1], [s + 2010, s + 2011, 1]]
    _publish_transcript(worker, row, gaps)  # pages: segments 0-499 (0-1996 s), then 500 (2000 s)
    first = get(client, f"/v1/conversations/{row['id']}")["transcript"]
    last = get(client, f"/v1/conversations/{row['id']}?segments_from=500")["transcript"]
    starts = lambda t: [g["start"] for g in t.get("untranscribed", [])]  # noqa: E731
    assert len(starts(first)) == 3 and len(starts(last)) == 2, "before, between, up to page 2's first segment | the tail"
    assert sorted(starts(first) + starts(last)) == sorted(set(starts(first) + starts(last))) and len(starts(first) + starts(last)) == 5
    assert "untranscribed_incomplete" not in first and "untranscribed_incomplete" not in last
    # many stretches after the last segment: the one-segment page carries a bounded number and says so
    _publish_transcript(worker, row, [[s + 2002 + i * 2, s + 2003 + i * 2, 1] for i in range(5000)])
    last = get(client, f"/v1/conversations/{row['id']}?segments_from=500")["transcript"]
    assert len(last["untranscribed"]) == 4 and last["untranscribed_incomplete"] is True


@pytest.mark.parametrize("bad", [[1e100, 1e100, 1], [None, 1800000001, 1], [1800000000, 1800000001, "x"], [5, 4, 1], [1, 2, 0]],
                         ids=["huge", "null", "speech_not_a_number", "reversed", "no_speech"])  # fmt: skip
def test_an_unreadable_gap_never_breaks_the_note_and_is_said_to_be_missing(client, worker, bad):
    # ASTRA-20261115-IT2-04: a malformed optional gap made the whole detail a 500
    row = finished(client, worker)
    s = row["start"]
    _publish_transcript(worker, row, [bad, [s + 6, s + 7, 1]], count=3)
    t = get(client, f"/v1/conversations/{row['id']}")["transcript"]
    assert t["segments"] and len(t["untranscribed"]) == 1 and t["untranscribed_incomplete"] is True


def _publish_starts(worker, row, starts, gaps):
    import json as _json

    from omi_notes.util import canonical_json, sha256_hex

    path = worker.pipeline.conv_dir(row["id"]) / "transcript.json"
    doc = _json.loads(path.read_text())
    doc["segments"] = [dict(doc["segments"][0], start=t, end=t + 1) for t in starts]
    doc["untranscribed"] = gaps
    path.write_text(_json.dumps(doc))
    worker.db.execute("UPDATE conversations SET transcript_sha=? WHERE id=?", (sha256_hex(canonical_json(doc["segments"]).encode()), row["id"]))
    return path, doc


def _page(client, row, offset=0):
    return get(client, f"/v1/conversations/{row['id']}?segments_from={offset}")["transcript"]


def test_every_gap_appears_once_across_pages_even_at_a_shared_start_time(client, worker):
    # Astra IT4: 1,001 segments, three with the same start straddling the page boundary, gaps before, between,
    # exactly at the boundary and after the last
    from omi_notes.util import iso_utc_epoch

    row = finished(client, worker)
    s = row["start"]
    starts = [s + i * 4 for i in range(1001)]
    starts[500] = starts[501] = starts[499]
    gaps = [[t, t + 0.5, 0.5] for t in [s - 3, s, s + 6, starts[499], s + 2002, starts[1000], s + 4010]]
    _publish_starts(worker, row, starts, gaps)
    seen, offset = [], 0
    while True:
        p = _page(client, row, offset)
        seen += [g["start"] for g in p.get("untranscribed", [])]
        if p["next_from"] is None:
            break
        offset = p["next_from"]
    assert seen == [iso_utc_epoch(g[0]) for g in gaps]


def test_a_page_past_the_end_replays_no_gaps(client, worker):
    # ASTRA-20261115-IT4-05: an empty continuation owned everything from minus infinity
    row = finished(client, worker)
    s = row["start"]
    _publish_starts(worker, row, [s, s + 4], [[s - 3, s - 2, 1], [s + 2, s + 3, 1]])
    assert len(_page(client, row)["untranscribed"]) == 2 and not _page(client, row, 2).get("untranscribed")


def test_a_page_never_copies_more_gaps_than_it_carries(client, worker, monkeypatch):
    # ASTRA-20261115-IT4-01: the page took all the gaps it owned (5,000) and only then cut them to its four
    from omi_notes import views

    row = finished(client, worker)
    s = row["start"]
    _publish_starts(worker, row, [s + i * 4 for i in range(501)], [[s + 2002 + i * 2, s + 2003 + i * 2, 1] for i in range(5000)])
    copies = []

    class Counted(list):
        def __getitem__(self, key):
            if isinstance(key, slice):
                copies.append(len(range(*key.indices(len(self)))))
            return super().__getitem__(key)

    real = views.gap_list
    monkeypatch.setattr(views, "gap_list", lambda *a: (lambda st, va, bad: (st, Counted(va), bad))(*real(*a)))
    p = _page(client, row, 500)
    assert len(p["untranscribed"]) == 4 and p["untranscribed_incomplete"] is True and max(copies) <= 4


def test_gaps_always_come_from_the_transcript_file_just_read(client, worker, monkeypatch):
    # ASTRA-20261115-IT4-02: a cache keyed by the file's mtime and size, stat'ed after the read, bound old gaps to a new
    # file (replaced between read and stat, or rewritten at the same size with its mtime kept)
    import json as _json
    import os
    from pathlib import Path

    from omi_notes.util import iso_utc_epoch

    row = finished(client, worker)
    s = row["start"]
    path, doc = _publish_starts(worker, row, [s, s + 20], [[s + 4, s + 5, 1]])
    real, done = Path.read_text, []

    def replace_after_read(p, *a, **k):
        text = real(p, *a, **k)
        if p == path and not done:
            done.append(1)
            changed = _json.loads(text)
            changed["untranscribed"] = [[s + 8, s + 9, 1]]
            tmp = path.with_suffix(".replacement")
            tmp.write_text(_json.dumps(changed))
            os.replace(tmp, path)
        return text

    monkeypatch.setattr(Path, "read_text", replace_after_read)
    _page(client, row)
    assert _page(client, row)["untranscribed"][0]["start"] == iso_utc_epoch(s + 8)
    monkeypatch.undo()
    st, old = path.stat(), path.read_bytes()
    doc = _json.loads(old)
    doc["untranscribed"] = [[s + 6, s + 7, 1]]
    new = _json.dumps(doc).encode()
    assert len(new) == len(old)
    path.write_bytes(new)
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
    assert _page(client, row)["untranscribed"][0]["start"] == iso_utc_epoch(s + 6)


def test_more_reconciled_gaps_than_a_page_carries_are_said_to_be_incomplete(client, worker):
    from omi_notes.providers.local_asr import _reconciled_gaps

    row = finished(client, worker)
    s = row["start"]
    gaps = _reconciled_gaps([{"start": s + 90 + i * 5, "end": s + 91 + i * 5, "speech_seconds": 1, "reason": "no_words"} for i in range(6)],
                            [{"start": s, "end": s + 80, "transcript": "long kept utterance"}])  # fmt: skip
    _publish_starts(worker, row, [s], [[g["start"], g["end"], g["speech_seconds"]] for g in gaps])
    p = _page(client, row)
    assert len(p["untranscribed"]) == 4 and p["untranscribed_incomplete"] is True
