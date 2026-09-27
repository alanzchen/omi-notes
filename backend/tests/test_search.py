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
    assert search.pending(worker.db, worker.pipeline.speakers.names_digest()) == 0  # the worker indexed both after processing them
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


def test_renaming_a_person_reindexes_their_conversations(client, worker):
    rows = two_conversations(client, worker)
    store = worker.pipeline.speakers
    pid = "11111111-1111-4111-8111-111111111111"
    assert client.put(f"/v1/people/{pid}", json={"name": "Alice", "me": True}, headers=AUTH).status_code in (200, 201)
    label = worker.db.one("SELECT speaker FROM (SELECT 'S1' AS speaker)")["speaker"]
    store.write_labels(rows[0]["id"], {label: {"person_id": pid, "source": "confirmed"}}, transcript_sha=rows[0]["transcript_sha"])
    worker.tick(STARTED.timestamp() + 90000)
    assert [c["id"] for c in find(client, "alice")["conversations"]] == [rows[0]["id"]]
    assert client.put(f"/v1/people/{pid}", json={"name": "Bob", "me": True}, headers=AUTH).status_code == 200
    assert find(client, "alice")["conversations"] == []  # the old entry is no longer current
    worker.tick(STARTED.timestamp() + 90001)
    assert [c["id"] for c in find(client, "bob")["conversations"]] == [rows[0]["id"]] and find(client, "alice")["conversations"] == []


def test_a_summary_that_cant_be_read_is_not_indexed_partially(client, worker):
    rows = two_conversations(client, worker)
    worker.db.execute("DELETE FROM search_index")
    cached = worker.pipeline.conv_dir(rows[0]["id"]) / rows[0]["llm_ref"]
    good = cached.read_bytes()
    cached.write_text("{broken")
    indexer = search.Indexer()
    assert indexer.run(worker.pipeline, now=0) == 1  # the other one; this one waits
    assert find(client, "deterministic")["pending"] == 1
    cached.write_bytes(good)
    assert indexer.run(worker.pipeline, now=10) == 0  # set aside for a while, not retried every tick
    assert indexer.run(worker.pipeline, now=10 + search.RETRY_AFTER + 1) == 1
    assert len(find(client, "deterministic")["conversations"]) == 2


def test_rows_that_cant_be_indexed_dont_starve_the_rest(client, worker, monkeypatch):
    rows = two_conversations(client, worker)
    worker.db.execute("DELETE FROM search_index")
    (worker.pipeline.conv_dir(rows[1]["id"]) / "transcript.json").write_text("{broken")  # the newest one
    indexer = search.Indexer()
    assert indexer.run(worker.pipeline, now=0, limit=1) == 0  # the newest fails and is set aside
    assert indexer.run(worker.pipeline, now=1, limit=1) == 1  # the next batch reaches the older one
