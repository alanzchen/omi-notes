"""Value-aware Notes: the summary's own assessment and highlights (new summaries only) next to the
owner's explicit, durable choice (`<conversation dir>/priority.json`)."""

from __future__ import annotations

import json
import shutil
import uuid
from datetime import UTC, datetime, timedelta

import numpy as np
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.devtools import synth_speech_like
from omi_notes.pipeline.worker import Worker
from omi_notes.providers.fake import FakeLlm

from .conftest import AUTH
from .helpers import STARTED, T0, convs, note_text, replay, silence

SPEECH = np.concatenate([silence(1), synth_speech_like(12), silence(2), synth_speech_like(8), silence(2)])


class ValueLlm(FakeLlm):
    """A prompt-v3 answer: an assessment, one grounded highlight, one invalid one, an AI-directed item."""

    def __init__(self, level="high", first=0, last=0):
        self.calls, self.level, self.first, self.last = 0, level, first, last

    def summarize(self, request):
        self.calls += 1
        result = super().summarize(request)
        result.data |= {
            "interaction": "dictation",
            "value": {"level": self.level, "reasons": ["A plan worth keeping"]},
            "highlights": [{"title": "The weekend plan", "why": "What was decided", "first_segment": self.first,
                            "last_segment": self.last},
                           {"title": "A miscounted span", "why": "", "first_segment": 40, "last_segment": 41}],
            "action_items": result.data["action_items"] + [
                {"description": "Draft an email to the landlord", "owner": "me", "owner_name": None, "due_date": None,
                 "context": None, "directed_at_ai": True}],
        }  # fmt: skip
        return result


def get(client, path):
    r = client.get(path, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()


def choose(client, conv_id, state, *, at: datetime, request_id: str | None = None):
    body = {"state": state, "request_id": request_id or str(uuid.uuid4()), "set_at": at.isoformat()}
    return client.put(f"/v1/conversations/{conv_id}/priority", json=body, headers=AUTH)


def one(client, worker, llm=None):
    if llm is not None:
        worker.providers._llm = llm
    before = {r["id"] for r in convs(worker)}
    replay(client, SPEECH, start=STARTED + timedelta(minutes=10 * len(before)))
    worker.tick(T0 + 400 + 600 * len(before))
    (row,) = [r for r in convs(worker) if r["id"] not in before]
    return row


def test_a_new_summary_says_what_is_worth_revisiting_and_where(client, worker, settings):
    llm = ValueLlm(first=0, last=0)
    row = one(client, worker, llm)
    entry = next(c for c in get(client, "/v1/conversations/recent")["conversations"] if c["id"] == row["id"])
    v = entry["value"]
    assert v["assessment"] == "high" and v["recommended"] is True and v["interaction"] == "dictation"
    assert v["highlight"] == "The weekend plan" and v["user"]["state"] == "auto"
    d = get(client, f"/v1/conversations/{row['id']}")
    assert d["value_reasons"] == ["A plan worth keeping"]
    good, bad = d["highlights"]
    segments = d["transcript"]["segments"]
    assert good["target"]["first_segment"] == 0 and good["target"]["last_segment"] == 0
    assert good["target"]["start_at"] == segments[0]["start"] and good["target"]["timing"] == "segment"
    assert bad["target"] is None  # indices outside the transcript: no seek target, the note opens whole
    # a draft dictated to an assistant is not the owner's task
    note = note_text(settings, worker.db.one("SELECT * FROM conversations WHERE id=?", (row["id"],)))
    tasks = note.split("## Action Items", 1)[1].split("## ", 1)[0]
    assert "landlord" not in tasks and "## Asked of an Assistant" in note and "Draft an email to the landlord" in note
    assert all("landlord" not in t for t in json.loads(worker.db.one("SELECT index_json FROM conversations WHERE id=?",
                                                                     (row["id"],))["index_json"])["action_items"])  # fmt: skip


def test_older_summaries_stay_legacy_and_nothing_is_reanalysed(client, worker, settings):
    old = one(client, worker)  # summarized by a pre-v3 answer (no assessment)
    assert get(client, f"/v1/conversations/{old['id']}")["value"]["assessment"] == "legacy"
    note_before = note_text(settings, old)
    # the index is rebuilt (as a schema bump would) with a v3-capable model configured
    shutil.rmtree(settings.index_dir)
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    worker.providers._llm = llm = ValueLlm()
    for t in range(4):
        worker.tick(T0 + 5000 + t)
    assert llm.calls == 0, "no historical inference"
    assert get(client, f"/v1/conversations/{old['id']}")["value"]["assessment"] == "legacy"
    assert note_text(settings, old) == note_before
    # and the owner can still mark it, without any analysis
    assert choose(client, old["id"], "important", at=datetime.now(UTC)).json()["state"] == "important"


def test_the_owners_choice_is_durable_deduplicated_and_later_wins(client, worker, settings):
    row = one(client, worker, ValueLlm(level="normal"))
    t = datetime(2026, 10, 10, 9, 0, tzinfo=UTC)
    rid = str(uuid.uuid4())
    first = choose(client, row["id"], "less_useful", at=t, request_id=rid).json()
    assert first == {"state": "less_useful", "revision": 1, "set_at": "2026-10-10T09:00:00.000Z", "applied": True}
    assert choose(client, row["id"], "less_useful", at=t, request_id=rid).json()["revision"] == 1  # a repeat
    newer = choose(client, row["id"], "important", at=t + timedelta(minutes=5)).json()
    assert newer["state"] == "important" and newer["revision"] == 2
    late = choose(client, row["id"], "auto", at=t + timedelta(minutes=1)).json()  # an old restore arriving late
    assert late["applied"] is False and late["state"] == "important"
    stored = json.loads((worker.pipeline.conv_dir(row["id"]) / "priority.json").read_text())
    assert stored["state"] == "important" and stored["revision"] == 2  # in the vault, not only the index

    # re-analysis (a forced re-summary that now says "low") never overrides the owner
    worker.providers._llm = ValueLlm(level="low")
    assert client.post(f"/v1/conversations/{row['id']}/resummarize", headers=AUTH).status_code == 202
    worker.tick(T0 + 9000)
    v = get(client, f"/v1/conversations/{row['id']}")["value"]
    assert v["assessment"] == "low" and v["user"]["state"] == "important"

    # an index rebuild keeps it too
    shutil.rmtree(settings.index_dir)
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    for i in range(3):
        worker.tick(T0 + 10000 + i)
    assert get(client, f"/v1/conversations/{row['id']}")["value"]["user"] == {
        "state": "important", "revision": 2, "set_at": "2026-10-10T09:05:00.000Z"}
    # restore automatic, later than every earlier choice
    back = choose(client, row["id"], "auto", at=t + timedelta(minutes=10)).json()
    assert back["state"] == "auto" and back["revision"] == 3


def test_every_row_stays_listed_whatever_its_value_or_choice(client, worker):
    legacy = one(client, worker)
    low = one(client, worker, ValueLlm(level="low"))
    unknown = one(client, worker, ValueLlm(level="unknown"))
    choose(client, low["id"], "less_useful", at=datetime.now(UTC))
    rows = {c["id"]: c["value"] for c in get(client, "/v1/conversations/recent")["conversations"]}
    assert {legacy["id"], low["id"], unknown["id"]} <= set(rows)  # nothing hidden by the overlay
    assert rows[legacy["id"]]["assessment"] == "legacy" and rows[unknown["id"]]["assessment"] == "unknown"
    assert rows[low["id"]]["user"]["state"] == "less_useful" and rows[low["id"]]["recommended"] is False
    assert not any(v["recommended"] for v in rows.values())  # only "high" is recommended


def test_open_and_unknown_conversations(client, worker):
    assert choose(client, "01a0aaaa-0000-7000-8000-000000000000", "important", at=datetime.now(UTC)).status_code == 404
    bad = client.put("/v1/conversations/x/priority", json={"state": "starred", "request_id": "r", "set_at": "2026-10-10T09:00:00Z"},
                     headers=AUTH)  # fmt: skip
    assert bad.status_code == 422
