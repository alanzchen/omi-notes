"""Apple Watch audio relayed as the Watch's own AAC (`aac_m4a_v1`, servers with `watch_aac`): stored
unchanged, decoded here, refused when damaged, and mixable with PCM parts in one recording. Synthetic
audio; ffmpeg encodes the test files locally (the Apple-encoded fixture comes from the phone's tests)."""

from __future__ import annotations

import hashlib
import json
import uuid
from pathlib import Path

import numpy as np
import pytest

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


def test_a_part_stored_as_pcm_and_relayed_again_as_aac_is_the_same_audio_kept_twice(client, worker):
    # field case (2026-11-08): an October Watch part stored as PCM by an old phone build came back as the
    # Watch's AAC after its acknowledgement was lost; the same audio, other bytes, same identity
    capture = str(uuid.uuid4())
    pcm = np.concatenate([talk(20, 3), silence(10)])
    as_pcm = pcm_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED, source="watch_mic")
    as_aac = aac_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED)
    assert put_chunk(client, capture, 0, as_pcm[0]).status_code == 201
    stored = worker.db.one("SELECT sha256, path FROM chunks WHERE capture_id=? AND chunk_sequence=0", (capture,))
    r = put_chunk(client, capture, 0, as_aac[0])
    assert r.status_code == 200 and r.json()["duplicate"] is True, r.json()
    again = worker.db.one("SELECT sha256, path FROM chunks WHERE capture_id=? AND chunk_sequence=0", (capture,))
    assert dict(again) == dict(stored), "the stored (lossless) copy stays the chunk"
    cap_dir = (worker.pipeline.settings.vault_dir / stored["path"]).parent
    kept = list((cap_dir / "alternates").glob("0-*.omnc"))
    assert len(kept) == 1 and kept[0].read_bytes() == as_aac[0], "the relayed copy is kept too, never dropped"
    assert put_chunk(client, capture, 0, as_aac[0]).status_code == 200, "and again: still the same"


def test_different_audio_under_a_stored_identity_is_still_a_conflict_but_its_bytes_are_kept(client, worker):
    capture = str(uuid.uuid4())
    first = pcm_envelopes(np.concatenate([talk(20, 3), silence(10)]), capture_id=capture, device_id=WATCH,
                          started_at=STARTED, source="watch_mic")  # fmt: skip
    other = aac_envelopes(np.concatenate([silence(10), talk(20, 9)]), capture_id=capture, device_id=WATCH, started_at=STARTED)
    assert put_chunk(client, capture, 0, first[0]).status_code == 201
    assert put_chunk(client, capture, 0, other[0]).status_code == 409
    path = worker.db.one("SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=0", (capture,))["path"]
    kept = list(((worker.pipeline.settings.vault_dir / path).parent / "alternates").glob("0-*.omnc"))
    assert len(kept) == 1 and kept[0].read_bytes() == other[0]


def test_a_copy_whose_last_seconds_differ_is_not_the_same_audio():
    # Astra's probe: a 60 s chunk with its last two seconds replaced correlated 0.97 as a whole
    from omi_notes.ingest import same_audio

    capture = str(uuid.uuid4())
    pcm = talk(60, 3)
    changed = pcm.copy()
    changed[-2 * 16000 :] = talk(2, 11)
    a = parse_envelope(pcm_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED, source="watch_mic")[0])
    b = parse_envelope(aac_envelopes(changed, capture_id=capture, device_id=WATCH, started_at=STARTED)[0])
    same = parse_envelope(aac_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED)[0])
    assert same_audio(a, same) is True
    assert same_audio(a, b) is False


def test_a_damaged_alternate_copy_is_rewritten_before_the_resend_is_acknowledged(client, worker):
    capture = str(uuid.uuid4())
    pcm = np.concatenate([talk(20, 3), silence(10)])
    as_pcm = pcm_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED, source="watch_mic")
    as_aac = aac_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED)
    assert put_chunk(client, capture, 0, as_pcm[0]).status_code == 201
    assert put_chunk(client, capture, 0, as_aac[0]).status_code == 200
    path = worker.db.one("SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=0", (capture,))["path"]
    (alternate,) = ((worker.pipeline.settings.vault_dir / path).parent / "alternates").glob("0-*.omnc")
    alternate.write_bytes(as_aac[0][:100])  # truncated on disk
    assert put_chunk(client, capture, 0, as_aac[0]).status_code == 200
    assert alternate.read_bytes() == as_aac[0], "the sent bytes are durably there again before the 200"


def test_a_different_last_half_second_is_not_the_same_audio():
    # Astra's probe: 30.5 s with the final 0.5 s replaced slipped past the whole-second windows
    from omi_notes.ingest import same_audio

    capture = str(uuid.uuid4())
    pcm = talk(30.5, 3)
    changed = pcm.copy()
    t = np.arange(8000) / 16000  # other speech: a different voice (talk() shares one carrier across seeds)
    changed[-8000:] = (8000 * np.sin(2 * np.pi * 237 * t) * np.sin(2 * np.pi * 3 * t)).astype(np.int16)
    a = parse_envelope(pcm_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED, source="watch_mic")[0])
    b = parse_envelope(aac_envelopes(changed, capture_id=capture, device_id=WATCH, started_at=STARTED)[0])
    assert same_audio(a, b) is False
    assert same_audio(a, parse_envelope(aac_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED)[0])) is True


def test_a_copy_with_extra_sound_past_the_shorter_end_is_not_the_same_audio():
    # Astra's probe: the identical 30 s plus 80 ms of loud audio passed, since both were cut to the shorter
    # length before any check; the same holds when everything before it is silent
    from omi_notes.ingest import same_audio

    capture = str(uuid.uuid4())
    t = np.arange(1280) / 16000
    loud = (8000 * np.sin(2 * np.pi * 237 * t)).astype(np.int16)
    for pcm in (talk(30, 3), silence(30)):
        a, b = (
            parse_envelope(pcm_envelopes(p, capture_id=capture, device_id=WATCH, started_at=STARTED, source="watch_mic")[0])
            for p in (pcm, np.concatenate([pcm, loud]))
        )
        assert same_audio(a, b) is False
        assert same_audio(b, a) is False
    pcm = talk(30, 3)
    padded = np.concatenate([pcm, np.zeros(1280, dtype=np.int16)])
    a, b = (
        parse_envelope(pcm_envelopes(p, capture_id=capture, device_id=WATCH, started_at=STARTED, source="watch_mic")[0])
        for p in (pcm, padded)
    )
    assert same_audio(a, b) is True, "quiet padding past the end is still the same recording"


def test_the_server_advertises_that_it_takes_the_same_audio_sent_again(client):
    assert "same_audio_resend" in client.get("/v1/status", headers=AUTH).json()["features"]


def _resend_setup(client, worker):
    capture = str(uuid.uuid4())
    pcm = np.concatenate([talk(20, 3), silence(10)])
    as_pcm = pcm_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED, source="watch_mic")
    as_aac = aac_envelopes(pcm, capture_id=capture, device_id=WATCH, started_at=STARTED)
    assert put_chunk(client, capture, 0, as_pcm[0]).status_code == 201
    return capture, as_aac[0]


def test_comparing_a_resend_does_not_hold_up_other_uploads(client, worker, monkeypatch):
    # 2026-11-10 17:28 CST: ~130 Watch parts sent again as other bytes, each compared (two ffmpeg decodes,
    # 0.15-0.3 s for a 60 s part) inside the one ingest lock; every other upload waited, and the proxy dropped
    # 418 of them unanswered. The comparison now runs outside the lock.
    import threading

    from omi_notes import ingest as ingest_module

    capture, resend = _resend_setup(client, worker)
    comparing, release = threading.Event(), threading.Event()
    real = ingest_module.same_audio

    def slow(a, b):
        comparing.set()
        assert release.wait(10)
        return real(a, b)

    monkeypatch.setattr(ingest_module, "same_audio", slow)
    ingest = client.app.state.ingest
    result = {}
    t = threading.Thread(target=lambda: result.update(r=ingest.put_chunk(capture, 0, resend, hashlib.sha256(resend).hexdigest())))
    t.start()
    assert comparing.wait(10)
    other = str(uuid.uuid4())
    new = pcm_envelopes(talk(10, 5), capture_id=other, device_id=WATCH, started_at=STARTED, source="watch_mic")[0]
    assert put_chunk(client, other, 0, new).status_code == 201, "a new upload is stored while the comparison runs"
    release.set()
    t.join(10)
    assert result["r"][0] == 200 and result["r"][1]["duplicate"] is True


def test_the_same_resend_again_is_not_decoded_again(client, worker, monkeypatch):
    from omi_notes import ingest as ingest_module

    capture, resend = _resend_setup(client, worker)
    calls = []
    real = ingest_module.same_audio
    monkeypatch.setattr(ingest_module, "same_audio", lambda a, b: calls.append(1) or real(a, b))
    for _ in range(3):
        r = put_chunk(client, capture, 0, resend)
        assert r.status_code == 200 and r.json()["duplicate"] is True
    assert len(calls) == 1, "one comparison per stored identity and sent bytes; repeats are a lookup"
    path = worker.db.one("SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=0", (capture,))["path"]
    kept = list(((worker.pipeline.settings.vault_dir / path).parent / "alternates").glob("0-*.omnc"))
    assert len(kept) == 1 and kept[0].read_bytes() == resend, "the second copy is still kept"


def test_a_different_resend_stays_a_conflict_when_sent_again(client, worker, monkeypatch):
    from omi_notes import ingest as ingest_module

    capture = str(uuid.uuid4())
    first = pcm_envelopes(np.concatenate([talk(20, 3), silence(10)]), capture_id=capture, device_id=WATCH,
                          started_at=STARTED, source="watch_mic")  # fmt: skip
    other = aac_envelopes(np.concatenate([silence(10), talk(20, 9)]), capture_id=capture, device_id=WATCH, started_at=STARTED)[0]
    assert put_chunk(client, capture, 0, first[0]).status_code == 201
    calls = []
    real = ingest_module.same_audio
    monkeypatch.setattr(ingest_module, "same_audio", lambda a, b: calls.append(1) or real(a, b))
    assert [put_chunk(client, capture, 0, other).status_code for _ in range(2)] == [409, 409]
    assert len(calls) == 1


def test_a_new_aac_part_is_decoded_outside_the_ingest_lock(client, worker, monkeypatch):
    import threading

    from omi_notes import ingest as ingest_module

    decoding, release = threading.Event(), threading.Event()
    real = ingest_module.aac.decode

    def slow(payload, expected, **kw):
        decoding.set()
        assert release.wait(10)
        return real(payload, expected, **kw)

    capture = str(uuid.uuid4())
    body = aac_envelopes(np.concatenate([talk(20, 3), silence(10)]), capture_id=capture, device_id=WATCH, started_at=STARTED)[0]
    monkeypatch.setattr(ingest_module.aac, "decode", slow)
    ingest = client.app.state.ingest
    result = {}
    t = threading.Thread(target=lambda: result.update(r=ingest.put_chunk(capture, 0, body, hashlib.sha256(body).hexdigest())))
    t.start()
    assert decoding.wait(10)
    other = str(uuid.uuid4())
    new = pcm_envelopes(talk(10, 5), capture_id=other, device_id=WATCH, started_at=STARTED, source="watch_mic")[0]
    assert put_chunk(client, other, 0, new).status_code == 201, "stored while the AAC part is checked"
    release.set()
    t.join(10)
    assert result["r"][0] == 201


def _asgi(client):
    import httpx

    return httpx.AsyncClient(transport=httpx.ASGITransport(app=client.app), base_url="http://test")


def test_decode_bound_uploads_never_hold_the_shared_workers_others_need(client, monkeypatch):
    # ASTRA-20261111-IT1-02: 40 AAC uploads borrowed all 40 shared AnyIO workers (4 decoding, 36 waiting on the
    # decode semaphore), so a PCM upload and every other threaded request waited for the decoder
    import asyncio
    import json as _json
    import threading
    import time

    import anyio.to_thread

    from omi_notes import ingest as ingest_module
    from omi_notes.devtools import build_envelope

    capture = str(uuid.uuid4())
    samples = talk(2, 3)
    pcm = pcm_envelopes(samples, capture_id=capture, device_id=WATCH, started_at=STARTED, source="watch_mic")[0]
    env = parse_envelope(aac_envelopes(samples, capture_id=capture, device_id=WATCH, started_at=STARTED)[0])
    inputs = []
    for _ in range(40):
        ident = str(uuid.uuid4())
        header = _json.loads(env.header.model_dump_json()) | {"capture_id": ident}
        inputs.append((ident, build_envelope(header, env.payload)))
    entered, guard, release = [0], threading.Lock(), threading.Event()

    def held(payload, expected, **kw):
        with guard:
            entered[0] += 1
        assert release.wait(10)
        return np.zeros(expected, dtype=np.int16)

    monkeypatch.setattr(ingest_module.aac, "decode", held)

    async def exercise():
        async with _asgi(client) as ac:
            async def put(ident, body):
                return await ac.put(f"/v1/captures/{ident}/chunks/0", content=body,
                                    headers=AUTH | {"X-Content-SHA256": hashlib.sha256(body).hexdigest()})  # fmt: skip

            jobs = [asyncio.create_task(put(i, b)) for i, b in inputs]
            try:
                end = time.monotonic() + 5
                while entered[0] < 4 and time.monotonic() < end:
                    await asyncio.sleep(0.01)
                await asyncio.sleep(0.2)
                assert entered[0] == 4, "four decodes at once, the rest wait"
                assert anyio.to_thread.current_default_thread_limiter().borrowed_tokens == 0
                probe = await asyncio.wait_for(put(capture, pcm), 2)
                status = await asyncio.wait_for(ac.get("/v1/status", headers=AUTH), 2)
                assert probe.status_code == 201 and status.status_code == 200
            finally:
                release.set()
            assert all(r.status_code == 201 for r in await asyncio.gather(*jobs))

    asyncio.run(exercise())


def test_identical_resends_arriving_together_are_compared_once(client, worker, monkeypatch):
    import asyncio

    from omi_notes import ingest as ingest_module

    capture, resend = _resend_setup(client, worker)
    calls = []
    real = ingest_module.same_audio

    def slow(a, b):
        calls.append(1)
        import time

        time.sleep(0.3)
        return real(a, b)

    monkeypatch.setattr(ingest_module, "same_audio", slow)

    async def exercise():
        async with _asgi(client) as ac:
            headers = AUTH | {"X-Content-SHA256": hashlib.sha256(resend).hexdigest()}
            return await asyncio.gather(*[ac.put(f"/v1/captures/{capture}/chunks/0", content=resend, headers=headers) for _ in range(4)])

    codes = [r.status_code for r in asyncio.run(exercise())]
    assert codes == [200] * 4 and len(calls) == 1
    path = worker.db.one("SELECT path FROM chunks WHERE capture_id=? AND chunk_sequence=0", (capture,))["path"]
    assert len(list(((worker.pipeline.settings.vault_dir / path).parent / "alternates").glob("0-*.omnc"))) == 1


def _route_put(c, ident, body):
    return c.put(f"/v1/captures/{ident}/chunks/0", content=body, headers=AUTH | {"X-Content-SHA256": hashlib.sha256(body).hexdigest()})


async def _until(check, timeout=5.0):
    import asyncio
    import time

    end = time.monotonic() + timeout
    while not check() and time.monotonic() < end:
        await asyncio.sleep(0.01)
    assert check(), "test coordination deadline"


def _two_seconds(capture):
    samples = talk(2, 3)
    return (pcm_envelopes(samples, capture_id=capture, device_id=WATCH, started_at=STARTED, source="watch_mic")[0],
            aac_envelopes(samples, capture_id=capture, device_id=WATCH, started_at=STARTED)[0])  # fmt: skip


def test_a_comparison_that_fails_now_answers_every_waiting_resend_503_without_shared_workers(client, monkeypatch):
    # ASTRA-20261111-IT2-02: the first comparison of 41 identical resends failed (AacError, not remembered); the 40
    # waiters woke without its result and each compared again on a shared worker: a PCM upload and /v1/status
    # waited. ASTRA-20261111-IT3-01: that failure answered 409, which the phone quarantines. Now every waiter takes
    # the failed comparison's answer, a retryable 503, nothing decodes on shared workers, and a later resend is
    # compared again and acknowledged.
    import asyncio
    import threading

    from omi_notes import ingest as ingest_module

    capture, probe_id = str(uuid.uuid4()), str(uuid.uuid4())
    pcm, aac_copy = _two_seconds(capture)
    probe_pcm, _ = _two_seconds(probe_id)
    assert put_chunk(client, capture, 0, pcm).status_code == 201
    calls, guard, release = [0], threading.Lock(), threading.Event()
    real = ingest_module.same_audio

    def failing(a, b):
        with guard:
            calls[0] += 1
        assert release.wait(10)
        raise ingest_module.aac.AacError("AAC decode took longer than 30 s")

    monkeypatch.setattr(ingest_module, "same_audio", failing)

    async def exercise():
        async with _asgi(client) as c:
            jobs = [asyncio.create_task(_route_put(c, capture, aac_copy)) for _ in range(41)]
            await _until(lambda: calls[0] == 1)
            await asyncio.sleep(0.2)
            probe = await asyncio.wait_for(_route_put(c, probe_id, probe_pcm), 2)
            status = await asyncio.wait_for(c.get("/v1/status", headers=AUTH), 2)
            release.set()
            return await asyncio.gather(*jobs), probe, status

    answers, probe, status = asyncio.run(exercise())
    assert [r.status_code for r in answers] == [503] * 41 and calls[0] == 1
    assert {r.json()["error"] for r in answers} == {"comparison_unavailable"}
    assert probe.status_code == 201 and status.status_code == 200
    row = client.app.state.db.one("SELECT path FROM chunks WHERE capture_id=?", (capture,))
    path = client.app.state.vault.root / row["path"]
    alternates = list((path.parent / "alternates").glob("*.omnc"))
    assert path.read_bytes() == pcm and len(alternates) == 1 and alternates[0].read_bytes() == aac_copy
    monkeypatch.setattr(ingest_module, "same_audio", real)  # not remembered: compared again, and the same audio
    assert put_chunk(client, capture, 0, aac_copy).status_code == 200


def test_a_comparison_that_fails_now_is_retryable_not_a_conflict(client, monkeypatch):
    # ASTRA-20261111-IT3-01, one resend (no coalescing): 503, both copies kept, then 200 once a comparison is made;
    # different audio is still a conflict (409) with both copies kept
    from omi_notes import ingest as ingest_module

    capture = str(uuid.uuid4())
    pcm, aac_copy = _two_seconds(capture)
    assert put_chunk(client, capture, 0, pcm).status_code == 201
    real = ingest_module.same_audio

    def timeout(a, b):
        raise ingest_module.aac.AacError("AAC decode took longer than 30 s")

    monkeypatch.setattr(ingest_module, "same_audio", timeout)
    r = put_chunk(client, capture, 0, aac_copy)
    assert r.status_code == 503 and r.json()["error"] == "comparison_unavailable"
    monkeypatch.setattr(ingest_module, "same_audio", real)
    assert put_chunk(client, capture, 0, aac_copy).status_code == 200
    other = aac_envelopes(np.concatenate([silence(1), talk(1, 9)]), capture_id=capture, device_id=WATCH, started_at=STARTED)[0]
    assert put_chunk(client, capture, 0, other).status_code == 409
    path = client.app.state.vault.root / client.app.state.db.one("SELECT path FROM chunks WHERE capture_id=?", (capture,))["path"]
    assert path.read_bytes() == pcm
    assert {f.read_bytes() for f in (path.parent / "alternates").glob("*.omnc")} == {aac_copy, other}


def test_a_cancelled_upload_leading_a_comparison_leaves_its_followers_off_the_shared_workers(client, monkeypatch):
    # ASTRA-20261111-IT2-02: four held decodes fill the decode pool; a comparison's first upload is cancelled before
    # it is admitted, and its 40 followers then compared on shared workers, blocking a PCM upload and /v1/status
    import asyncio
    import json as _json
    import threading

    import anyio.to_thread

    from omi_notes import ingest as ingest_module
    from omi_notes.devtools import build_envelope

    capture, probe_id = str(uuid.uuid4()), str(uuid.uuid4())
    pcm, aac_copy = _two_seconds(capture)
    probe_pcm, _ = _two_seconds(probe_id)
    assert put_chunk(client, capture, 0, pcm).status_code == 201
    env = parse_envelope(aac_copy)
    holders = []
    for _ in range(4):
        ident = str(uuid.uuid4())
        holders.append((ident, build_envelope(_json.loads(env.header.model_dump_json()) | {"capture_id": ident}, env.payload)))
    decoding, guard, release = [0], threading.Lock(), threading.Event()
    real = ingest_module.aac.decode

    def held(payload, expected, **kw):
        with guard:
            decoding[0] += 1
        assert release.wait(10)
        return real(payload, expected, **kw)

    monkeypatch.setattr(ingest_module.aac, "decode", held)

    async def exercise():
        async with _asgi(client) as c:
            held_jobs = [asyncio.create_task(_route_put(c, i, b)) for i, b in holders]
            try:
                await _until(lambda: decoding[0] == 4)
                leader = asyncio.create_task(_route_put(c, capture, aac_copy))
                await asyncio.sleep(0.2)
                followers = [asyncio.create_task(_route_put(c, capture, aac_copy)) for _ in range(40)]
                await asyncio.sleep(0.2)
                leader.cancel()
                await asyncio.gather(leader, return_exceptions=True)
                await asyncio.sleep(0.1)
                assert anyio.to_thread.current_default_thread_limiter().borrowed_tokens == 0
                probe = await asyncio.wait_for(_route_put(c, probe_id, probe_pcm), 2)
                status = await asyncio.wait_for(c.get("/v1/status", headers=AUTH), 2)
            finally:
                release.set()
            return await asyncio.gather(*held_jobs), await asyncio.gather(*followers), probe, status

    held_answers, answers, probe, status = asyncio.run(exercise())
    assert probe.status_code == 201 and status.status_code == 200
    assert [r.status_code for r in held_answers] == [201] * 4 and [r.status_code for r in answers] == [200] * 40
    row = client.app.state.db.one("SELECT path FROM chunks WHERE capture_id=?", (capture,))
    path = client.app.state.vault.root / row["path"]
    alternates = list((path.parent / "alternates").glob("*.omnc"))
    assert path.read_bytes() == pcm and len(alternates) == 1 and alternates[0].read_bytes() == aac_copy


def test_a_resend_stored_by_another_writer_after_planning_is_compared_in_the_decode_pool(client, monkeypatch):
    # put_chunk with a plan never decodes on a shared worker: other bytes the plan didn't compare (stored by another
    # writer after planning) go back to the route, which plans again and compares in its decode pool
    import pytest as _pytest

    from omi_notes.ingest import ChunkPlan, NeedsComparison

    capture = str(uuid.uuid4())
    pcm, aac_copy = _two_seconds(capture)
    ingest = client.app.state.ingest
    assert ingest.put_chunk(capture, 0, pcm, hashlib.sha256(pcm).hexdigest())[0] == 201
    with _pytest.raises(NeedsComparison):
        ingest.put_chunk(capture, 0, aac_copy, hashlib.sha256(aac_copy).hexdigest(), ChunkPlan())
    r = put_chunk(client, capture, 0, aac_copy)
    assert r.status_code == 200 and r.json()["duplicate"] is True


@pytest.mark.parametrize("kind", ["identical", "equivalent", "different"])
def test_two_first_writers_through_the_route_keep_the_original_and_one_alternate(client, monkeypatch, kind):
    # both plan before either commits; the second then finds the first's bytes, plans again and compares in the
    # decode pool (ASTRA-20261111-IT2-02's replanning path), never on a shared worker
    import asyncio
    import threading

    cid = str(uuid.uuid4())
    p, a = _two_seconds(cid)
    b = a if kind == "identical" else p if kind == "equivalent" else aac_envelopes(talk(2, 19), capture_id=cid, device_id=WATCH, started_at=STARTED)[0]
    barrier = threading.Barrier(2); real = client.app.state.ingest.plan_chunk; n = [0]; lock = threading.Lock()
    def plan(*args):
        r = real(*args)
        with lock:
            n[0] += 1; first_two = n[0] <= 2
        if first_two: barrier.wait(timeout=5)
        return r
    monkeypatch.setattr(client.app.state.ingest, "plan_chunk", plan)
    async def go():
        async with _asgi(client) as c:
            return await asyncio.gather(*[c.put(f"/v1/captures/{cid}/chunks/0", content=x, headers=AUTH | {"X-Content-SHA256": hashlib.sha256(x).hexdigest()}) for x in (a, b)])
    codes = sorted(r.status_code for r in asyncio.run(go()))
    row = client.app.state.db.one("SELECT path, sha256 FROM chunks WHERE capture_id=?", (cid,))
    path = client.app.state.vault.root / row["path"]; kept = path.read_bytes()
    alts = list((path.parent / "alternates").glob("*.omnc"))
    assert codes == ([201, 409] if kind == "different" else [200, 201]), (codes, n)
    assert hashlib.sha256(kept).hexdigest() == row["sha256"] and len(alts) == (0 if kind == "identical" else 1)
    if alts: assert {kept, alts[0].read_bytes()} == {a, b}
