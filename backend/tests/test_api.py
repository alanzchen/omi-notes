import hashlib
from datetime import UTC, datetime

import numpy as np

from omi_notes.devtools import live_envelopes
from omi_notes.envelope import MAX_BODY_BYTES, iso_utc

from .conftest import AUTH, DEVICE, put_chunk

STARTED = datetime(2026, 9, 26, 19, 0, tzinfo=UTC)


def envelopes(capture_id: str, seconds: float = 130.0, **kw) -> list[bytes]:
    pcm = (np.sin(np.arange(int(seconds * 16000)) / 7) * 3000).astype(np.int16)
    return live_envelopes(pcm, capture_id=capture_id, device_id=DEVICE, started_at=STARTED, **kw)


def seal_body(last: int, **overrides) -> dict:
    body = {"last_chunk_sequence": last, "reason": "ble_disconnected", "ended_at": iso_utc(STARTED),
            "end_offset_us": 130_000_000, "device_id": DEVICE, "source": "live_ble"}  # fmt: skip
    body.update(overrides)
    return body


def test_healthz_needs_no_auth(client):
    assert client.get("/healthz").json() == {"ok": True}


def test_auth_required(client, new_id):
    assert client.get("/v1/status").status_code == 401
    assert client.get("/v1/status", headers={"Authorization": "Bearer wrong"}).status_code == 401
    assert client.get("/v1/status", headers={"Authorization": "Basic test-token"}).status_code == 401
    r = client.put(f"/v1/captures/{new_id()}/chunks/0", content=b"x")
    assert r.status_code == 401 and r.json()["error"] == "unauthorized"


def test_status(client):
    body = client.get("/v1/status", headers=AUTH).json()
    assert body["ok"] and body["protocol_version"] == 1 and body["stt"] == {"provider": "fake", "ready": True}
    assert body["queue"] == {"chunks_pending": 0, "conversations_open": 0, "conversations_pending": 0, "failed": 0}


def test_chunk_idempotency_201_200_409(client, new_id):
    capture = new_id()
    first, second, *_ = envelopes(capture)
    r = put_chunk(client, capture, 0, first)
    assert r.status_code == 201 and r.json()["duplicate"] is False and r.json()["stored"] is True
    r = put_chunk(client, capture, 0, first)
    assert r.status_code == 200 and r.json()["duplicate"] is True
    other = envelopes(capture, seconds=20)[0]  # same identity, different content
    r = put_chunk(client, capture, 0, other)
    assert r.status_code == 409 and r.json()["error"] == "chunk_conflict"
    assert put_chunk(client, capture, 1, second).status_code == 201


def test_chunk_is_durable_before_ack(client, new_id, settings):
    capture = new_id()
    body = envelopes(capture)[0]
    assert put_chunk(client, capture, 0, body).status_code == 201
    stored = list(settings.raw_dir.rglob("0.omnc"))
    assert len(stored) == 1 and stored[0].read_bytes() == body


def test_checksum_and_length_errors(client, new_id):
    capture = new_id()
    body = envelopes(capture)[0]
    assert put_chunk(client, capture, 0, body, sha="0" * 64).status_code == 400
    r = client.put(f"/v1/captures/{capture}/chunks/0", content=body, headers=AUTH)
    assert r.status_code == 400 and r.json()["error"] == "missing_sha256"


def test_invalid_envelope_422(client, new_id):
    capture = new_id()
    r = put_chunk(client, capture, 0, b"OMINOTE1garbage")
    assert r.status_code == 422 and r.json()["error"] == "invalid_envelope"
    body = envelopes(capture)[0]
    r = put_chunk(client, capture, 1, body)  # header says chunk 0
    assert r.status_code == 422
    assert put_chunk(client, "NOT-A-UUID", 0, body).status_code == 422


def test_too_large_413(client, new_id):
    capture = new_id()
    body = b"x" * (MAX_BODY_BYTES + 1)
    r = client.put(
        f"/v1/captures/{capture}/chunks/0",
        content=body,
        headers=AUTH | {"X-Content-SHA256": hashlib.sha256(body).hexdigest()},
    )
    assert r.status_code == 413


def test_seal_immutability_and_beyond_seal(client, new_id):
    capture = new_id()
    envs = envelopes(capture)  # 3 chunks
    put_chunk(client, capture, 0, envs[0])
    r = client.put(f"/v1/captures/{capture}/seal", json=seal_body(1), headers=AUTH)
    assert r.status_code == 200 and r.json()["sealed"] and r.json()["last_chunk_sequence"] == 1
    assert client.put(f"/v1/captures/{capture}/seal", json=seal_body(1), headers=AUTH).status_code == 200
    r = client.put(f"/v1/captures/{capture}/seal", json=seal_body(2), headers=AUTH)
    assert r.status_code == 409 and r.json()["error"] == "seal_conflict"
    assert put_chunk(client, capture, 1, envs[1]).status_code == 201
    r = put_chunk(client, capture, 2, envs[2])
    assert r.status_code == 409 and r.json()["error"] == "beyond_seal"


def test_seal_below_existing_chunks_is_rejected(client, new_id):
    capture = new_id()
    envs = envelopes(capture)
    put_chunk(client, capture, 0, envs[0])
    put_chunk(client, capture, 1, envs[1])
    r = client.put(f"/v1/captures/{capture}/seal", json=seal_body(0), headers=AUTH)
    assert r.status_code == 409 and r.json()["error"] == "chunks_beyond_seal"


def test_seal_before_any_chunk_and_empty_ring_capture(client, new_id):
    capture = new_id()
    body = {"last_chunk_sequence": -1, "reason": "sync_complete", "ended_at": iso_utc(STARTED),
            "device_id": DEVICE, "source": "device_ring",
            "ring": {"covers_until": iso_utc(STARTED), "info_read_seq": 0, "generation": 1}}  # fmt: skip
    r = client.put(f"/v1/captures/{capture}/seal", json=body, headers=AUTH)
    assert r.status_code == 200
    assert r.json() == {"capture_id": capture, "source": "device_ring", "sealed": True, "last_chunk_sequence": -1,
                        "received_ranges": [], "processed_through": -1}  # fmt: skip


def test_seal_validation(client, new_id):
    capture = new_id()
    assert client.put(f"/v1/captures/{capture}/seal", json=seal_body(0, reason="nope"), headers=AUTH).status_code == 422
    assert client.put(f"/v1/captures/{capture}/seal", content=b"{", headers=AUTH).status_code == 422
    bad = seal_body(0, reason="sync_complete")  # only valid for ring captures
    assert client.put(f"/v1/captures/{capture}/seal", json=bad, headers=AUTH).status_code == 422


def test_capture_identity_conflict(client, new_id):
    capture = new_id()
    put_chunk(client, capture, 0, envelopes(capture)[0])
    r = client.put(f"/v1/captures/{capture}/seal", json=seal_body(0, device_id="someone-else"), headers=AUTH)
    assert r.status_code == 409


def test_capture_status_ranges(client, new_id):
    capture = new_id()
    envs = envelopes(capture, seconds=250)  # 5 chunks
    for seq in (0, 1, 3):
        put_chunk(client, capture, seq, envs[seq])
    body = client.get(f"/v1/captures/{capture}", headers=AUTH).json()
    assert body["received_ranges"] == [[0, 1], [3, 3]] and body["processed_through"] == -1 and not body["sealed"]
    assert client.get(f"/v1/captures/{new_id()}", headers=AUTH).status_code == 404


def test_events_idempotent(client, new_id, settings):
    event_id = new_id()
    body = {"device_id": DEVICE, "type": "heartbeat", "at": iso_utc(STARTED),
            "data": {"battery": 83, "charging": False, "coverage": {"capture_id": new_id(), "through_offset_us": 5,
                                                                    "through_chunk_sequence": 0}}}  # fmt: skip
    assert client.put(f"/v1/events/{event_id}", json=body, headers=AUTH).status_code == 201
    assert client.put(f"/v1/events/{event_id}", json=body, headers=AUTH).status_code == 200
    changed = body | {"data": {"battery": 12}}
    assert client.put(f"/v1/events/{event_id}", json=changed, headers=AUTH).status_code == 409
    button = {"device_id": DEVICE, "type": "button", "at": iso_utc(STARTED), "data": {"code": "two"}}
    assert client.put(f"/v1/events/{new_id()}", json=button, headers=AUTH).status_code == 422
    assert client.put(f"/v1/events/{new_id()}", json={"type": "button"}, headers=AUTH).status_code == 422


def test_recent_conversations_empty(client):
    assert client.get("/v1/conversations/recent?limit=5", headers=AUTH).json() == {"conversations": []}


def test_recent_conversations_only_offer_speakers_after_transcription(client, worker):
    from .helpers import T0, replay, tone

    replay(client, tone(10))
    worker.tick(T0 + 15)
    (recording,) = client.get("/v1/conversations/recent", headers=AUTH).json()["conversations"]
    assert recording["status"] == "open"
    assert recording["speakers_ready"] is False

    worker.tick(T0 + 400)
    (finished,) = client.get("/v1/conversations/recent", headers=AUTH).json()["conversations"]
    assert finished["id"] == recording["id"] and finished["speakers_ready"] is True
    assert client.get(f"/v1/conversations/{finished['id']}/speakers", headers=AUTH).status_code == 200
