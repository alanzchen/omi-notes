"""A double tap set to "star" (button event code 3) stars the whole conversation that moment belongs
to, as the Omi app's "star conversation" does: applied once the conversation is finished, through the
owner's priority (`priority.json`, later wins), with the pendant as its recorded source."""

from __future__ import annotations

import json
import shutil
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.devtools import synth_speech_like
from omi_notes.pipeline.worker import Worker

from .conftest import AUTH
from .helpers import T0, convs, event, live, silence


def value(client, conv_id):
    r = client.get(f"/v1/conversations/{conv_id}", headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()["value"]["user"]


def star(client, capture, second):
    event(client, "button", at=T0 + second, capture_id=capture, offset_us=second * 1_000_000, data={"code": 3})


def test_a_star_waits_for_the_conversation_then_marks_it_important_with_its_source(client, worker, settings):
    assert "pendant_star" in client.get("/v1/status", headers=AUTH).json()["features"]
    capture = live(client, np.concatenate([silence(1), synth_speech_like(40), silence(2)]), offline_storage=False)
    star(client, capture, 12)
    worker.tick(T0 + 30)  # still recording: nothing is decided yet
    assert worker.db.one("SELECT applied FROM events WHERE code=3")["applied"] == 0
    worker.tick(T0 + 300)
    worker.tick(T0 + 301)
    (row,) = convs(worker)
    assert row["status"] == "done" and row["start"] < T0 + 12 < row["end"], "a star never splits the conversation"
    user = value(client, row["id"])
    assert user["state"] == "important" and user["source"] == "pendant"
    stored = json.loads((worker.pipeline.conv_dir(row["id"]) / "priority.json").read_text())
    assert stored["source"] == "pendant" and stored["event_id"] and stored["requests"] == [f"pendant:{stored['event_id']}"]

    # the owner's later choice in the app wins over the earlier star; the source says so
    later = datetime.fromtimestamp(T0 + 3600, UTC).isoformat()
    r = client.put(f"/v1/conversations/{row['id']}/priority", json={"state": "less_useful", "request_id": "app-1", "set_at": later}, headers=AUTH)
    assert r.json()["state"] == "less_useful" and value(client, row["id"])["source"] == "app"

    # an index rebuild re-applies the event idempotently: the owner's later choice still stands
    shutil.rmtree(settings.index_dir)
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    for i in range(3):
        worker.tick(T0 + 400 + i)
    assert value(client, row["id"])["state"] == "less_useful"


def test_the_phones_star_event_fixture_is_accepted(client):
    body = json.loads((Path(__file__).parents[2] / "contracts/fixtures/swift/event_button_star.json").read_text())
    r = client.put("/v1/events/0193e1a2-0000-7000-8000-000000000003", json=body, headers=AUTH)
    assert r.status_code == 201, r.text


def test_a_second_star_in_the_same_conversation_unstars_it(client, worker):
    capture = live(client, np.concatenate([silence(1), synth_speech_like(40), silence(2)]), offline_storage=False)
    star(client, capture, 10)
    star(client, capture, 25)
    worker.tick(T0 + 300)
    worker.tick(T0 + 301)
    (row,) = convs(worker)
    assert value(client, row["id"])["state"] == "auto"
    assert worker.db.one("SELECT count(*) AS n FROM events WHERE code=3 AND applied=1")["n"] == 2
