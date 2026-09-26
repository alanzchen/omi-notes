"""Regenerate contracts/fixtures/python/ (deterministic: fixed ids, clock and seeds).

    uv run python scripts/make_contract_fixtures.py
"""

from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

from omi_notes.audio.timeline import CaptureTimeline
from omi_notes.devtools import live_envelopes, pcm_envelopes, ring_envelopes, synth_speech_like
from omi_notes.envelope import parse_envelope

OUT = Path(__file__).resolve().parents[2] / "contracts" / "fixtures" / "python"
STARTED = datetime(2026, 9, 26, 19, 32, 5, 123000, tzinfo=UTC)
DEVICE = "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f"


def describe(name: str, body: bytes) -> dict:
    env = parse_envelope(body)
    result = CaptureTimeline(env.header.frame_samples).decode_chunk(env, final=True)
    t0 = env.header.capture_started_at.timestamp()
    return {
        "file": name,
        "sha256": hashlib.sha256(body).hexdigest(),
        "bytes": len(body),
        "source": env.header.source,
        "payload_format": env.header.payload_format,
        "record_count": env.header.record_count,
        "decoded_pieces": [{"start_offset_s": round(p.start - t0, 3), "samples": len(p.pcm)} for p in result.pieces],
    }


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    speech = synth_speech_like(3.0, seed=7)
    gap = np.zeros(16000 * 12, dtype=np.int16)  # > 10 s of quiet: the mic sleeps, then wakes
    live_pcm = np.concatenate([speech, gap, synth_speech_like(2.0, seed=8)])
    fixtures = {
        "live_ble_opus21.omnc": live_envelopes(
            live_pcm, capture_id="3d1f0c9e-2b4a-4e6f-9a1b-5c7d9e1f2a3b", device_id=DEVICE, started_at=STARTED,
            chunk_seconds=60, drop_rate=0.02, seq_start=65500, offline_storage=True, seed=3,
        )[0],
        "device_ring.omnc": ring_envelopes(
            synth_speech_like(4.0, seed=9), capture_id="7a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", device_id=DEVICE,
            started_at=STARTED, audio_start_epoch=int(STARTED.timestamp()) - 3600, first_sequence=1200,
        )[0][0],
        "wav_replay_pcm.omnc": pcm_envelopes(
            speech[:16000], capture_id="9c8b7a6f-5e4d-4c3b-8a29-1f0e9d8c7b6a", device_id=DEVICE, started_at=STARTED,
        )[0],
    }
    manifest = []
    for name, body in fixtures.items():
        (OUT / name).write_bytes(body)
        manifest.append(describe(name, body))
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {len(fixtures)} fixtures to {OUT}")


if __name__ == "__main__":
    main()
