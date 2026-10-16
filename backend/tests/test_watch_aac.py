"""Apple Watch audio relayed as the Watch's own AAC (`aac_m4a_v1`, servers with `watch_aac`): stored
unchanged, decoded here, refused when damaged, and mixable with PCM parts in one recording. Synthetic
audio; ffmpeg encodes the test files locally (the Apple-encoded fixture comes from the phone's tests)."""

from __future__ import annotations

import hashlib
import json
import uuid
from pathlib import Path

import numpy as np

from omi_notes.audio import aac
from omi_notes.audio.timeline import CaptureTimeline
from omi_notes.devtools import aac_envelopes, build_envelope, pcm_envelopes
from omi_notes.envelope import parse_envelope

from .conftest import AUTH, put_chunk, upload_all
from .helpers import STARTED, T0, convs, silence
from .test_watch_sources import WATCH, run, talk

FIXTURE = Path(__file__).parents[2] / "contracts/fixtures/swift/watch_aac_sample.omnc"


def stored_payload(worker, capture: str, seq: int) -> bytes:
    path = worker.db.one("SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture, seq))["path"]
    return parse_envelope((worker.pipeline.settings.vault_dir / path).read_bytes()).payload


def test_the_server_advertises_watch_aac_when_it_can_decode(client):
    assert ("watch_aac" in client.get("/v1/status", headers=AUTH).json()["features"]) == aac.available()


def test_an_aac_recording_is_kept_as_sent_and_becomes_a_note(client, worker):
    capture = str(uuid.uuid4())
    pcm = np.concatenate([silence(1), talk(30, 3), silence(150)])
    envs = aac_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED)
    upload_all(client, capture, envs)
    assert put_chunk(client, capture, 0, envs[0]).json()["duplicate"] is True, "a resend is stored once"
    for seq, body in enumerate(envs):  # the original AAC file, byte for byte
        assert hashlib.sha256(stored_payload(worker, capture, seq)).digest() == hashlib.sha256(parse_envelope(body).payload).digest()
    run(worker, T0 + 900)
    (row,) = convs(worker)
    assert row["status"] == "done" and row["note_path"]


def test_a_damaged_aac_file_is_refused_and_not_stored(client, worker):
    capture = str(uuid.uuid4())
    env = parse_envelope(aac_envelopes(talk(5, 1), capture_id=capture, device_id=WATCH, started_at=STARTED)[0])
    header = json.loads(env.header.model_dump_json())
    bad = bytearray(env.payload)
    bad[len(bad) // 2:] = bytes(len(bad) - len(bad) // 2)  # second half zeroed
    r = put_chunk(client, capture, 0, build_envelope(header, bytes(bad)))
    assert r.status_code == 422 and r.json()["error"] in ("invalid_audio", "invalid_envelope"), r.text
    assert worker.db.one("SELECT count(*) AS n FROM chunks WHERE capture_id=?", (capture,))["n"] == 0


def test_pcm_and_aac_parts_of_one_recording_join_without_a_gap(client, worker):
    """A recording converted partly by an older phone (PCM) and partly relayed as AAC."""
    capture = str(uuid.uuid4())
    first = talk(60, 4)
    rest = np.concatenate([talk(20, 5), silence(160)])
    pcm_env = pcm_envelopes(first, capture_id=capture, device_id=WATCH, started_at=STARTED, source="watch_mic")
    aac_env = aac_envelopes(rest, capture_id=capture, device_id=WATCH, started_at=STARTED, first_seq=1, first_sample=len(first))
    upload_all(client, capture, pcm_env + aac_env)
    timeline, pieces = CaptureTimeline(0), []
    for body in pcm_env + aac_env:
        pieces += timeline.decode_chunk(parse_envelope(body)).pieces
    assert sum(len(p.pcm) for p in pieces) == len(first) + len(rest), "every sample once"
    assert all(b.continues for b in pieces[1:]), "one continuous run across the PCM → AAC switch"
    assert abs(pieces[0].start - T0) < 1e-6
    run(worker, T0 + 900)
    rows = convs(worker)
    assert rows and all(r["status"] == "done" for r in rows)


def test_the_phones_apple_encoded_aac_fixture_decodes_to_its_frame_count(client, worker):
    body = FIXTURE.read_bytes()
    env = parse_envelope(body)
    expected = json.loads(FIXTURE.with_suffix(".aac.json").read_text())
    assert env.header.payload_format == "aac_m4a_v1" and env.header.source == "watch_mic"
    assert hashlib.sha256(env.payload).hexdigest() == expected["aac_sha256"]
    assert len(aac.decode(env.payload, env.header.record_count)) == env.header.record_count == int(expected["frames"])
    r = put_chunk(client, env.header.capture_id, env.header.chunk_sequence, body)
    assert r.status_code == 201, r.text
    assert hashlib.sha256(stored_payload(worker, env.header.capture_id, env.header.chunk_sequence)).hexdigest() == expected["aac_sha256"]
