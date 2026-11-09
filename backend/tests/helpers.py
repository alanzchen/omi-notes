"""Shared builders for worker/pipeline tests: uploads through the real HTTP API."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import numpy as np

from omi_notes.devtools import live_envelopes, pcm_envelopes
import json
import logging

from omi_notes.envelope import iso_utc, parse_envelope
from omi_notes.notes.writer import remove
from omi_notes.pipeline.conversations import PENDING
from omi_notes.vault import Vault

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


def replay(client, pcm: np.ndarray, start: datetime = STARTED, chunk_seconds: float = 60.0, *,
           source: str = "wav_replay", device: str = DEVICE) -> str:
    """Developer PCM replay (or an Apple Watch recording relayed by the phone, `watch_mic`): time
    outside the capture needs no evidence, so conversations close fast."""
    capture = str(uuid.uuid4())
    envs = pcm_envelopes(pcm, capture_id=capture, device_id=device, started_at=start, chunk_seconds=chunk_seconds, source=source)
    upload_all(client, capture, envs)
    end_us = parse_envelope(envs[-1]).header.chunk_end_offset_us
    seal = {"last_chunk_sequence": len(envs) - 1, "reason": "replay_complete" if source == "wav_replay" else "user_stopped",
            "ended_at": iso_utc(start), "end_offset_us": end_us, "device_id": device, "source": source}  # fmt: skip
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
    return (settings.vault_dir / row["note_path"]).read_text()


__all__ = ["STARTED", "T0", "SR", "silence", "tone", "iso", "replay", "live", "live_seal", "ring_seal",
           "ring_sync", "event", "convs", "note_text", "timedelta"]  # fmt: skip


# -- raw audio deletion as it was before 2026-11-08 (production keeps all raw audio now) ------------------
# Vaults still hold tombstones of audio deleted by the old 30-day retention (243 conversations in Alan's);
# tests build such vaults with this copy of the old algorithm. `self` is the Worker.


def historical_retention(self, now: float, days: float = 30.0) -> int:
    """Delete raw chunk files older than `days`, except any chunk inside the decode
    range (first..last chunk of each capture, empty ones included) of a conversation that is
    unfinished, finished within the retention period, or still being assembled."""
    cutoff = now - days * 86400
    protected: set[tuple[str, int]] = set()
    placeholders = ",".join("?" * (len(PENDING) + 1))
    needed = self.db.query(
        f"""SELECT device_id, start, end FROM conversations
            WHERE status IN ({placeholders}) OR COALESCE(done_at, 0) > ?""",
        (*PENDING, "failed", cutoff),
    )
    spans = [(r["device_id"], r["start"], r["end"]) for r in needed]
    spans += [
        (r["device_id"], r["start"], r["end"])
        for r in self.db.query("SELECT device_id, start, end FROM speech WHERE claimed_by IS NULL")
    ]
    # an undecided voice enrollment keeps its window's audio until the result is written
    spans += [(w.device_id, w.start, w.end if w.end is not None else now) for w in self.enrollments.undecided()]
    for device, start, end in spans:
        for r in self.db.query(
            """SELECT capture_id, MIN(chunk_sequence) AS lo, MAX(chunk_sequence) AS hi FROM chunks
               WHERE device_id=? AND audio_start IS NOT NULL AND audio_start <= ? AND audio_end >= ?
               GROUP BY capture_id""",
            (device, end + 2, start - 2),
        ):
            protected.update((r["capture_id"], s) for s in range(r["lo"], r["hi"] + 1))
    by_capture: dict[str, list] = {}
    for chunk in self.db.query(
        "SELECT * FROM chunks WHERE status='processed' AND raw_deleted=0 AND received_at < ? ORDER BY capture_id, chunk_sequence",
        (cutoff,),
    ):
        if (chunk["capture_id"], chunk["chunk_sequence"]) not in protected:
            by_capture.setdefault(chunk["capture_id"], []).append(chunk)
    deleted = 0
    for capture_id, chunks in by_capture.items():
        try:
            deleted += _historical_expire(self, capture_id, chunks, now)
        except Exception:  # one capture's problem must not stop the others
            log.exception("retention: could not expire raw audio of capture %s", capture_id)
    if deleted:
        log.info("retention: deleted %d raw chunks", deleted)
    try:  # every pass, so a cleanup a crash interrupted is finished
        self.pipeline.speakers.reconcile_vectors()
    except Exception:
        log.exception("retention: could not reconcile stored voice vectors")
    return deleted

def _historical_expire(self, capture_id: str, chunks: list, now: float) -> int:
    """Delete raw chunks of one capture: first `capture.json` (what they contributed: chunk
    facts, coverage, losses, ring ownership, tentative speech, continuation checkpoints), then
    a `<seq>.gone` tombstone per chunk, then the `.omnc` files, then the index."""
    capture = self.db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
    device = capture["device_id"]
    already = {r["chunk_sequence"] for r in self.db.query(
        "SELECT chunk_sequence FROM chunks WHERE capture_id=? AND raw_deleted=1", (capture_id,))}  # fmt: skip
    seqs = sorted(already | {c["chunk_sequence"] for c in chunks})
    Vault.write_json(self.vault.capture_json_path(device, capture_id), self._evidence_for(capture, set(seqs)))
    for chunk in chunks:
        tomb_path = self.vault.tombstone_path(device, capture_id, chunk["chunk_sequence"])
        if tomb_path.exists():  # an earlier pass got this far (its .omnc may be gone): resume
            continue
        path = self.vault.root / chunk["path"]
        header = parse_envelope(path.read_bytes()).header.model_dump(mode="json")
        tomb = {"sha256": chunk["sha256"], "size": chunk["size"], "header": header, "deleted_at": now}
        Vault.write_json(tomb_path, tomb, pretty=False)
    for chunk in chunks:
        remove(self.vault.root / chunk["path"])
    with self.db.tx() as conn:
        conn.executemany("UPDATE chunks SET raw_deleted=1 WHERE capture_id=? AND chunk_sequence=?",
                         [(capture_id, c["chunk_sequence"]) for c in chunks])  # fmt: skip
    self._prune_voices(device, chunks)
    return len(chunks)


log = logging.getLogger(__name__)
