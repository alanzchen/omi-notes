"""`phone_status` events: the phone's own status, sent with no pendant involved (capture-format-v1.md).

Stored like any event (vault first, then the index); note processing never reads them. The fixture
is the one the phone's code writes (contracts/fixtures/swift/event_phone_status.json).
"""

from __future__ import annotations

import json
import uuid
from pathlib import Path

from .conftest import AUTH

FIXTURE = Path(__file__).parents[2] / "contracts/fixtures/swift/event_phone_status.json"


def test_the_phones_status_fixture_is_stored_with_its_build_and_times(client, settings, worker):
    body = json.loads(FIXTURE.read_text())
    event_id = str(uuid.uuid4())
    r = client.put(f"/v1/events/{event_id}", json=body, headers=AUTH)
    assert r.status_code == 201, r.text
    assert client.put(f"/v1/events/{event_id}", json=body, headers=AUTH).status_code == 200, "a resend is a duplicate"

    row = worker.db.one("SELECT device_id, type, at, received_at, body_json FROM events WHERE event_id=?", (event_id,))
    assert row["type"] == "phone_status" and row["device_id"] == body["device_id"]
    stored = json.loads(row["body_json"])["data"]
    assert stored["app_version"] == "0.1.0 (35)" and stored["launch_id"] == body["data"]["launch_id"]
    assert row["at"] != row["received_at"], "generated time kept apart from receipt"

    device = worker.db.one("SELECT last_seen, heartbeat_json FROM devices WHERE device_id=?", (body["device_id"],))
    assert device["last_seen"] == row["received_at"] and device["heartbeat_json"] is None, "not a heartbeat"
    events = [json.loads(line) for p in (settings.vault_dir / "_omi").rglob("*.jsonl") for line in p.read_text().splitlines()]
    assert any(e.get("event_id") == event_id and e["body"]["type"] == "phone_status" for e in events), "vault first"

    worker.tick(row["received_at"] + 3600)
    assert worker.db.one("SELECT count(*) AS n FROM conversations")["n"] == 0, "nothing in note processing reads it"
