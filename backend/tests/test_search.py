"""Search over titles, summaries, speaker names and transcripts (capture-format-v1.md, "Search")."""

from __future__ import annotations

from datetime import timedelta

import numpy as np

from omi_notes import search

from .conftest import AUTH
from .helpers import STARTED, convs, replay, silence
from omi_notes.devtools import synth_speech_like

SPEECH = np.concatenate([silence(1), synth_speech_like(12), silence(2)])


def find(client, query: str = "", **params) -> dict:
    r = client.get("/v1/conversations/search", params={"q": query, **params}, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()


def two_conversations(client, worker) -> list[dict]:
    starts = [STARTED, STARTED + timedelta(days=1)]
    for start in starts:
        replay(client, SPEECH, start=start)
    worker.tick(starts[-1].timestamp() + 400)
    return sorted(convs(worker), key=lambda r: r["start"])


def test_words_match_title_summary_and_transcript_case_insensitively(client, worker):
    rows = two_conversations(client, worker)
    assert search.pending(worker.db) == 0  # the worker indexed both after processing them
    hits = find(client, "QUARTERLY budget")  # the fake transcript's words, any case, any order
    assert {c["id"] for c in hits["conversations"]} == {r["id"] for r in rows} and hits["pending"] == 0
    assert find(client, "quarterly nonexistentword")["conversations"] == []
    assert find(client, "Deterministic")["conversations"]  # the fake summary's overview
    assert find(client, "%")["conversations"] == [] and find(client, "_")["conversations"] == []


def test_a_stale_entry_is_never_an_answer(client, worker):
    rows = two_conversations(client, worker)
    worker.db.execute("UPDATE conversations SET transcript_sha=? WHERE id=?", ("f" * 64, rows[0]["id"]))
    hits = find(client, "quarterly")
    assert [c["id"] for c in hits["conversations"]] == [rows[1]["id"]] and hits["pending"] == 1


def test_date_person_filters_and_paging(client, worker):
    rows = two_conversations(client, worker)
    day = STARTED.astimezone(worker.pipeline.tz).date()
    only_first = find(client, "", date_from=day.isoformat(), date_to=day.isoformat())
    assert [c["id"] for c in only_first["conversations"]] == [rows[0]["id"]]
    first = find(client, "quarterly", limit=1)
    assert [c["id"] for c in first["conversations"]] == [rows[1]["id"]] and first["next_cursor"]
    second = find(client, "quarterly", limit=1, before=first["next_cursor"])
    assert [c["id"] for c in second["conversations"]] == [rows[0]["id"]] and second["next_cursor"] is None
    assert find(client, "", person_id="00000000-0000-4000-8000-000000000000")["conversations"] == []
    assert client.get("/v1/conversations/search", params={"date_from": "yesterday"}, headers=AUTH).status_code == 422
    assert client.get("/v1/conversations/search", params={"before": "nan:x"}, headers=AUTH).status_code == 422


def test_a_bad_conversation_does_not_stall_indexing(client, worker):
    rows = two_conversations(client, worker)
    worker.db.execute("DELETE FROM search_index")
    (worker.pipeline.conv_dir(rows[0]["id"]) / "transcript.json").write_text("{broken")
    assert search.index_batch(worker.pipeline) == 1
    assert [c["id"] for c in find(client, "quarterly")["conversations"]] == [rows[1]["id"]]
