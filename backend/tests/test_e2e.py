"""End-to-end: synthesized audio → firmware-like Opus BLE notifications → HTTP upload → worker
ticks with an injected clock → markdown notes (fake STT/LLM, energy VAD)."""

import uuid
from datetime import UTC, datetime, timedelta

import numpy as np

from omi_notes.devtools import live_envelopes, synth_speech_like
from omi_notes.envelope import iso_utc, parse_envelope

from .conftest import AUTH, DEVICE, upload_all

STARTED = datetime(2026, 9, 26, 19, 0, tzinfo=UTC)
T0 = STARTED.timestamp()


def snapshot(settings):
    return {p.relative_to(settings.vault_dir).as_posix(): (p.read_bytes(), p.stat().st_mtime_ns)
            for p in settings.vault_dir.rglob("*.md")}  # fmt: skip


def ring_sync_seal(client, covers_until: datetime) -> None:
    """What the phone does on every connect: sync offline storage (here: nothing unread)."""
    body = {"last_chunk_sequence": -1, "reason": "sync_complete", "ended_at": iso_utc(covers_until),
            "device_id": DEVICE, "source": "device_ring",
            "ring": {"covers_until": iso_utc(covers_until), "info_read_seq": 0, "generation": 1}}  # fmt: skip
    assert client.put(f"/v1/captures/{uuid.uuid4()}/seal", json=body, headers=AUTH).status_code == 200


def test_two_conversations_end_to_end(client, worker, settings):
    ring_sync_seal(client, STARTED)  # connect at T0: nothing was recorded offline before
    # 20 s of speech, 150 s of silence (the mic sleeps: no notifications), 20 s of speech
    pcm = np.concatenate([synth_speech_like(20, seed=1), np.zeros(150 * 16000, np.int16),
                          synth_speech_like(20, seed=2), np.zeros(5 * 16000, np.int16)])  # fmt: skip
    capture = str(uuid.uuid4())
    envs = live_envelopes(pcm, capture_id=capture, device_id=DEVICE, started_at=STARTED, offline_storage=True, drop_rate=0.01)
    assert len(envs) == 4
    upload_all(client, capture, envs)
    end_us = parse_envelope(envs[-1]).header.chunk_end_offset_us
    seal = {"last_chunk_sequence": len(envs) - 1, "reason": "ble_disconnected",
            "ended_at": iso_utc(STARTED + timedelta(microseconds=end_us)), "end_offset_us": end_us,
            "device_id": DEVICE, "source": "live_ble"}  # fmt: skip
    assert client.put(f"/v1/captures/{capture}/seal", json=seal, headers=AUTH).status_code == 200

    # While audio is still recent both conversations are in progress.
    worker.tick(T0 + 100)
    assert client.get(f"/v1/captures/{capture}", headers=AUTH).json()["processed_through"] == 3
    notes = snapshot(settings)
    assert len([p for p in notes if p.startswith("_in-progress/")]) == 2

    # The first closes on live chunk coverage; the second ends at the disconnect and waits for
    # the offline-storage sync to prove the device recorded nothing afterwards.
    worker.tick(T0 + 400)
    notes = snapshot(settings)
    assert len([p for p in notes if p.startswith("Conversations/")]) == 1
    assert len([p for p in notes if p.startswith("_in-progress/")]) == 1

    ring_sync_seal(client, STARTED + timedelta(seconds=390))  # reconnect at T0+390: nothing offline
    worker.tick(T0 + 420)

    notes = snapshot(settings)
    conversations = sorted(p for p in notes if p.startswith("Conversations/"))
    assert conversations == [
        "Conversations/2026/2026-09/2026-09-26 1400 Fake Conversation With 1 Segments.md",
        "Conversations/2026/2026-09/2026-09-26 1402 Fake Conversation With 1 Segments.md",
    ]
    assert not [p for p in notes if p.startswith("_in-progress/")]
    daily = notes["Daily/2026-09-26.md"][0].decode()
    for path in conversations:
        assert f"[[{path[:-3]}\\|" in daily
    first = notes[conversations[0]][0].decode()
    assert "status: completed" in first and "provisional: false" in first and "## Transcript" in first
    assert "**14:00:" in first  # transcript timestamps are wall clock in TIMEZONE

    recent = client.get("/v1/conversations/recent", headers=AUTH).json()["conversations"]
    assert [c["status"] for c in recent] == ["done", "done"]
    assert {c["note_path"] for c in recent} == set(conversations)

    # Re-running is a no-op: same bytes, untouched files, unchanged state (_status.md is rewritten
    # at most once a minute, so it catches up first).
    worker.tick(T0 + 500)
    notes = snapshot(settings)
    rows = [dict(r) for r in worker.db.query("SELECT * FROM conversations ORDER BY id")]
    worker.tick(T0 + 600)
    worker.tick(T0 + 5000)
    assert snapshot(settings) == notes
    assert [dict(r) for r in worker.db.query("SELECT * FROM conversations ORDER BY id")] == rows
