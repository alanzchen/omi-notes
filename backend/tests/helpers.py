"""Shared builders for worker/pipeline tests: uploads through the real HTTP API."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import numpy as np

from omi_notes.devtools import live_envelopes, pcm_envelopes
from omi_notes.envelope import iso_utc, parse_envelope

from .conftest import AUTH, DEVICE, upload_all

STARTED = datetime(2026, 9, 26, 19, 0, tzinfo=UTC)
T0 = STARTED.timestamp()
SR = 16000


def silence(seconds: float) -> np.ndarray:
    return np.zeros(int(round(seconds * SR)), np.int16)


def tone(seconds: float, level: int = 8000) -> np.ndarray:
    t = np.arange(int(round(seconds * SR))) / SR
    return (np.sin(2 * np.pi * 220 * t) * level).astype(np.int16)


def iso(epoch: float) -> str:
    return iso_utc(datetime.fromtimestamp(epoch, UTC))


def replay(client, pcm: np.ndarray, start: datetime = STARTED, chunk_seconds: float = 60.0) -> str:
    """Developer PCM replay: time outside the capture needs no evidence, so conversations close fast."""
    capture = str(uuid.uuid4())
    envs = pcm_envelopes(pcm, capture_id=capture, device_id=DEVICE, started_at=start, chunk_seconds=chunk_seconds)
    upload_all(client, capture, envs)
    end_us = parse_envelope(envs[-1]).header.chunk_end_offset_us
    seal = {"last_chunk_sequence": len(envs) - 1, "reason": "replay_complete", "ended_at": iso_utc(start),
            "end_offset_us": end_us, "device_id": DEVICE, "source": "wav_replay"}  # fmt: skip
    assert client.put(f"/v1/captures/{capture}/seal", json=seal, headers=AUTH).status_code == 200
    return capture


def live_seal(client, capture: str, envs: list[bytes], *, ended_at: float | None = None) -> None:
    end_us = parse_envelope(envs[-1]).header.chunk_end_offset_us
    ended = ended_at if ended_at is not None else T0 + end_us / 1e6
    body = {"last_chunk_sequence": len(envs) - 1, "reason": "ble_disconnected", "ended_at": iso(ended),
            "end_offset_us": end_us, "device_id": DEVICE, "source": "live_ble"}  # fmt: skip
    r = client.put(f"/v1/captures/{capture}/seal", json=body, headers=AUTH)
    assert r.status_code == 200, r.text


def live(client, pcm: np.ndarray, *, offline_storage: bool, seal: bool = True, chunk_seconds: float = 60.0) -> str:
    capture = str(uuid.uuid4())
    envs = live_envelopes(pcm, capture_id=capture, device_id=DEVICE, started_at=STARTED,
                          offline_storage=offline_storage, chunk_seconds=chunk_seconds)  # fmt: skip
    upload_all(client, capture, envs)
    if seal:
        live_seal(client, capture, envs)
    return capture


def ring_seal(client, capture: str, *, reason: str = "sync_complete", last_chunk_sequence: int = -1,
              covers_until: float | None = None, ended_at: float | None = None, info_read_seq: int | None = 0,
              ring: dict | None = None):  # fmt: skip
    body = {"last_chunk_sequence": last_chunk_sequence, "reason": reason,
            "ended_at": iso(ended_at if ended_at is not None else (covers_until or T0)),
            "device_id": DEVICE, "source": "device_ring"}  # fmt: skip
    if reason in ("sync_complete", "sync_interrupted"):
        body["ring"] = {"generation": 1} | (ring or {})
        if covers_until is not None:
            body["ring"]["covers_until"] = iso(covers_until)
        if info_read_seq is not None:
            body["ring"]["info_read_seq"] = info_read_seq
    return client.put(f"/v1/captures/{capture}/seal", json=body, headers=AUTH)


def ring_sync(client, covers_until: float, last_chunk_sequence: int = -1, capture: str | None = None,
              info_read_seq: int = 0) -> str:  # fmt: skip
    """A `sync_complete` seal (default: the device's first sync, nothing read before)."""
    capture = capture or str(uuid.uuid4())
    r = ring_seal(client, capture, last_chunk_sequence=last_chunk_sequence, covers_until=covers_until,
                  info_read_seq=info_read_seq)  # fmt: skip
    assert r.status_code == 200, r.text
    return capture


def event(client, type_: str, *, at: float, **extra) -> None:
    body = {"device_id": DEVICE, "type": type_, "at": iso(at)} | extra
    r = client.put(f"/v1/events/{uuid.uuid4()}", json=body, headers=AUTH)
    assert r.status_code == 201, r.text


def convs(worker) -> list[dict]:
    return [dict(r) for r in worker.db.query("SELECT * FROM conversations ORDER BY start")]


def note_text(settings, row) -> str:
    return (settings.notes_dir / row["note_path"]).read_text()


__all__ = ["STARTED", "T0", "SR", "silence", "tone", "iso", "replay", "live", "live_seal", "ring_seal",
           "ring_sync", "event", "convs", "note_text", "timedelta"]  # fmt: skip
