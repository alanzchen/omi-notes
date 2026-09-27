"""Regression tests for the backend code review (one per finding, numbered like the review)."""

from __future__ import annotations

import json
import threading
import time
import uuid
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from typer.testing import CliRunner

from omi_notes import spool
from omi_notes.api import create_app
from omi_notes.audio.timeline import CaptureTimeline
from omi_notes.cli import app as cli
from omi_notes.db import Database
from omi_notes.device.ble_frames import BleFrameAssembler, encode_notification
from omi_notes.device.ring_records import RECORD_SIZE, pack_records
from omi_notes.devtools import base_header, encode_frames, live_envelopes, ring_envelopes, synth_speech_like
from omi_notes.envelope import FLAG_SESSION_START, build_envelope, encode_ble_record, parse_envelope
from omi_notes.pipeline import conversations as conv_mod
from omi_notes.pipeline import prompt
from omi_notes.pipeline.worker import Worker
from omi_notes.providers import LlmResult, ProviderError
from omi_notes.providers.fake import FakeLlm, FakeStt

from .conftest import AUTH, DEVICE, cli_env, make_settings, put_chunk, upload_all
from .helpers import (
    STARTED,
    T0,
    convs,
    event,
    iso,
    live,
    live_seal,
    note_text,
    replay,
    ring_seal,
    ring_sync,
    silence,
    tone,
)

SPEECH = np.concatenate([silence(1), synth_speech_like(10), silence(2)])


def envelope(header: dict, payload: bytes) -> bytes:
    return build_envelope(header, payload)


def ring_header(capture: str, seq: int, first_sequence: int, n: int, **ring) -> dict:
    h = base_header(capture_id=capture, seq=seq, device_id=DEVICE, source="device_ring", payload_format="ring_records_v1",
                    codec_id=21, started_at=STARTED, start_us=seq * 1_000_000, end_us=(seq + 1) * 1_000_000,
                    record_count=n, clock_quality="device_seconds")  # fmt: skip
    h["ring"] = {"first_sequence": first_sequence, "record_size": RECORD_SIZE} | ring
    return h


def ring_records_at(pcm: np.ndarray, start_ts: int) -> list[bytes]:
    return pack_records([(start_ts + (i * 320) // 16000, packet) for i, packet, _ in encode_frames(pcm)])


# 1 -----------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "mutation",
    [
        {"end_offset_us": "13025000"},
        {"last_chunk_sequence": "0"},
        {"ended_at": 1790000000},
        {"device_id": 12345},
        {"ring": {"covers_until": 1790000000}},
        {"ring": {"generation": "1"}},
    ],
)
def test_f01_seal_rejects_coerced_values(client, new_id, mutation):
    body = {"last_chunk_sequence": 0, "reason": "ble_disconnected", "ended_at": iso(T0 + 13),
            "end_offset_us": 13_025_000, "device_id": DEVICE, "source": "live_ble"} | mutation  # fmt: skip
    r = client.put(f"/v1/captures/{new_id()}/seal", json=body, headers=AUTH)
    assert r.status_code == 422, r.text


def test_f01_seal_is_persisted_normalized(client, worker, new_id):
    capture = new_id()
    body = {"last_chunk_sequence": 0, "reason": "ble_disconnected", "ended_at": "2026-09-26T19:00:13.025+00:00",
            "end_offset_us": 13_025_000, "device_id": DEVICE, "source": "live_ble"}  # fmt: skip
    assert client.put(f"/v1/captures/{capture}/seal", json=body, headers=AUTH).status_code == 200
    row = worker.db.one("SELECT * FROM captures WHERE capture_id=?", (capture,))
    assert row["seal_end_offset_us"] == 13_025_000 and isinstance(row["seal_end_offset_us"], int)
    assert row["ended_at"] == pytest.approx(T0 + 13.025)
    worker.tick(T0 + 100)  # must not raise


# 2 -----------------------------------------------------------------------------------------------


class AlwaysBusyStt(FakeStt):
    def transcribe(self, request):
        raise ProviderError("overloaded", kind="transient")


def test_f02_retention_keeps_empty_chunks_inside_a_pending_decode_range(client, worker, settings):
    # speech 0-15 s and 75-80 s (one conversation); the mic sleeps in between, chunk 2 (40-60 s) is empty
    pcm = np.concatenate([synth_speech_like(15), silence(60), synth_speech_like(5), silence(3)])
    live(client, pcm, offline_storage=False, chunk_seconds=20)
    empty = worker.db.one("SELECT * FROM chunks WHERE chunk_sequence=2")
    assert parse_envelope((settings.vault_dir / empty["path"]).read_bytes()).header.record_count == 0
    worker.providers._stt = AlwaysBusyStt()
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "transcribing"
    worker.retention(time.time() + 31 * 86400)
    assert (settings.vault_dir / empty["path"]).exists()
    audio = worker.pipeline.conversation_audio(worker.db.one("SELECT * FROM conversations"))
    assert len(audio.pcm) > 0


# 3 -----------------------------------------------------------------------------------------------


class DiscardingLlm(FakeLlm):
    def summarize(self, request):
        result = super().summarize(request)
        return LlmResult(data=result.data | {"keep": False, "discard_reason": "small talk"}, model=result.model)


def add_my_notes(path: Path, text: str) -> None:
    content = path.read_text()
    marker = "## My Notes\n\n<!-- my-notes:start -->\n"
    assert marker in content
    path.write_text(content.replace(marker, marker + text + "\n", 1))


def test_f03_moving_a_note_keeps_my_notes_and_survives_a_failed_write(client, worker, settings, monkeypatch):
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    old = settings.vault_dir / row["note_path"]
    add_my_notes(old, "Remember to call Priya.")
    worker.providers._llm = DiscardingLlm()
    for cached in worker.pipeline.conv_dir(row["id"]).glob("llm-*.json"):
        cached.unlink()
    worker.db.execute("UPDATE conversations SET status='summarizing' WHERE id=?", (row["id"],))

    real = conv_mod.write_if_changed

    def failing(path, content):
        if "_discarded" in str(path):
            raise OSError("disk unavailable")
        return real(path, content)

    monkeypatch.setattr(conv_mod, "write_if_changed", failing)
    worker.tick(T0 + 300)
    assert old.exists() and "Remember to call Priya." in old.read_text()

    monkeypatch.setattr(conv_mod, "write_if_changed", real)
    worker.tick(T0 + 400)
    (after,) = convs(worker)
    assert after["status"] == "discarded" and after["note_path"].startswith("_discarded/")
    assert "Remember to call Priya." in note_text(settings, after)
    assert not old.exists()


# 4 -----------------------------------------------------------------------------------------------

SPOOF = "Plan <!-- my-notes:start -->ATTACKER TEXT<!-- my-notes:end -->"


class SpoofingLlm(FakeLlm):
    def summarize(self, request):
        result = super().summarize(request)
        data = result.data | {"title": SPOOF, "sections": [{"heading": SPOOF, "bullets": [SPOOF]}]}
        return LlmResult(data=data, model=result.model)


class SpoofingStt(FakeStt):
    def transcribe(self, request):
        response = super().transcribe(request)
        for utt in response["results"]["utterances"]:
            utt["transcript"] = "Hello there. " + SPOOF + "\n## My Notes\n"
        return response


def test_f04_generated_text_cannot_impersonate_the_my_notes_region(client, worker, settings):
    worker.providers._llm = SpoofingLlm()
    worker.providers._stt = SpoofingStt()
    capture = live(client, SPEECH, offline_storage=False)
    event(client, "button", at=T0 + 5, capture_id=capture, offset_us=5_000_000, data={"code": 1})
    worker.tick(T0 + 300)
    (row,) = convs(worker)
    path = settings.vault_dir / row["note_path"]
    text = path.read_text()
    assert text.count("<!-- my-notes:start -->") == 1 and text.count("<!-- my-notes:end -->") == 1
    add_my_notes(path, "Real user text")
    worker.db.execute("UPDATE conversations SET needs_render=1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 400)
    text = path.read_text()
    region = text.split("<!-- my-notes:start -->", 1)[1].split("<!-- my-notes:end -->", 1)[0]
    assert region.strip() == "Real user text"


def test_f04_ambiguous_markers_leave_the_file_untouched(client, worker, settings):
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    path = settings.vault_dir / row["note_path"]
    add_my_notes(path, "mine\n<!-- my-notes:start -->\nconfusing")
    before = path.read_bytes()
    worker.db.execute("UPDATE conversations SET needs_render=1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 300)
    assert path.read_bytes() == before
    assert "My Notes" in (settings.vault_dir / "_status.md").read_text()


# 5 -----------------------------------------------------------------------------------------------


def test_f05_ring_only_device_waits_for_sync_evidence(client, worker):
    capture = str(uuid.uuid4())
    envs, _ = ring_envelopes(synth_speech_like(10), capture_id=capture, device_id=DEVICE, started_at=STARTED,
                             audio_start_epoch=int(T0), records_per_chunk=20)  # fmt: skip
    assert len(envs) > 2
    put_chunk(client, capture, 0, envs[0])  # the rest is still in the phone's outbox
    worker.tick(T0 + 400)
    assert convs(worker) and all(c["status"] == "open" for c in convs(worker))


# 6 -----------------------------------------------------------------------------------------------


def test_f06_newer_sync_does_not_resolve_over_an_unfinished_older_ring_capture(client, worker):
    older = str(uuid.uuid4())
    assert ring_seal(client, older, last_chunk_sequence=0, covers_until=T0 - 100).status_code == 200  # chunk 0 pending
    ring_sync(client, T0)
    live(client, np.concatenate([silence(1), synth_speech_like(20), silence(4)]), offline_storage=True)
    ring_sync(client, T0 + 300)
    worker.tick(T0 + 400)
    assert [c["status"] for c in convs(worker)] == ["open"]
    envs, _ = ring_envelopes(silence(2), capture_id=older, device_id=DEVICE, started_at=STARTED,
                             audio_start_epoch=int(T0) - 600)  # fmt: skip
    upload_all(client, older, envs)
    worker.tick(T0 + 410)
    assert [(c["status"], c["provisional"]) for c in convs(worker)] == [("done", 0)]


def test_f06_sync_after_records_the_server_never_saw_is_not_trusted(client, worker):
    # an earlier sync delivered records 1000..; the connect-time sync continued contiguously
    earlier = str(uuid.uuid4())
    envs, n = ring_envelopes(synth_speech_like(3), capture_id=earlier, device_id=DEVICE, started_at=STARTED,
                             audio_start_epoch=int(T0) - 3000, first_sequence=1000)  # fmt: skip
    upload_all(client, earlier, envs)
    ring_sync(client, T0 - 2000, last_chunk_sequence=len(envs) - 1, capture=earlier, info_read_seq=1000)
    ring_sync(client, T0, info_read_seq=1000 + n)
    live(client, np.concatenate([silence(1), synth_speech_like(20), silence(4)]), offline_storage=True)
    # after the disconnect the phone reports a sync starting at 1520: records 1000+n..1519 never arrived
    ring_sync(client, T0 + 300, info_read_seq=1520)
    worker.tick(T0 + 400)
    assert [c["status"] for c in convs(worker) if c["start"] > T0 - 10] == ["open"]
    ring_sync(client, T0 + 350, info_read_seq=1000 + n)  # a contiguous sync does resolve it
    worker.tick(T0 + 410)
    assert [(c["status"], c["provisional"]) for c in convs(worker) if c["start"] > T0 - 10] == [("done", 0)]


def test_app_recovered_ring_seal_does_not_resolve_coverage(client, worker):
    ring_sync(client, T0)
    live(client, np.concatenate([silence(1), synth_speech_like(20), silence(4)]), offline_storage=True)
    assert ring_seal(client, str(uuid.uuid4()), reason="app_recovered", ended_at=T0 + 300).status_code == 200
    worker.tick(T0 + 400)
    assert [c["status"] for c in convs(worker)] == ["open"]


# 7 -----------------------------------------------------------------------------------------------


def test_f07_speech_straddling_a_chunk_boundary_is_kept(client, worker):
    replay(client, np.concatenate([silence(59.8), tone(0.4), silence(5)]))
    worker.tick(T0 + 400)
    rows = convs(worker)
    assert len(rows) == 1 and rows[0]["start"] == pytest.approx(T0 + 59.8, abs=0.05)


# 8 -----------------------------------------------------------------------------------------------


def test_f08_backward_wall_clock_jump_in_seal_keeps_the_live_span(client, worker):
    ring_sync(client, T0)
    ring_sync(client, T0 + 1000)
    capture = str(uuid.uuid4())
    pcm = np.concatenate([silence(1), synth_speech_like(20), silence(100)])
    envs = live_envelopes(pcm, capture_id=capture, device_id=DEVICE, started_at=STARTED, offline_storage=True,
                          chunk_seconds=30)  # fmt: skip
    put_chunk(client, capture, 0, envs[0])  # later chunks still uploading
    end_us = parse_envelope(envs[-1]).header.chunk_end_offset_us
    live_seal(client, capture, envs, ended_at=T0 + end_us / 1e6 - 7200)  # phone clock stepped back 2 h
    worker.tick(T0 + 400)
    assert [c["status"] for c in convs(worker)] == ["open"]


def test_f08_forward_wall_clock_jump_in_button_event_still_splits(client, worker):
    capture = live(client, np.concatenate([silence(1), synth_speech_like(60), silence(2)]), offline_storage=False)
    event(client, "button", at=T0 + 31 + 7200, capture_id=capture, offset_us=31_000_000, data={"code": 2})
    worker.tick(T0 + 300)
    rows = convs(worker)
    assert len(rows) == 2 and rows[0]["end"] == pytest.approx(T0 + 31)


# 9 -----------------------------------------------------------------------------------------------


def test_f09_new_directories_are_fsynced_before_the_ack(tmp_path, monkeypatch):
    synced: list[Path] = []
    monkeypatch.setattr(spool, "fsync_dir", lambda p: synced.append(Path(p)))
    raw = tmp_path / "data" / "raw"
    spool.store_chunk(raw, "dev", "cap", 0, b"body")
    for created in (tmp_path / "data", raw, raw / "dev", raw / "dev" / "cap"):
        assert created.parent in synced, created
    assert synced[-1] == raw / "dev" / "cap"  # the rename itself


# 10 ----------------------------------------------------------------------------------------------


def test_f10_maintenance_only_queues_work_while_a_worker_runs(client, worker, settings):
    from omi_notes.lock import WorkerLock

    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    lock = WorkerLock(settings.db_path.parent)
    assert lock.acquire()
    try:
        result = CliRunner().invoke(cli, ["reprocess", row["id"], "--force-llm"], env=cli_env(settings))
        assert result.exit_code == 0, result.output
        assert "queued" in result.output
        queued = worker.db.one("SELECT * FROM conversations WHERE id=?", (row["id"],))
        # the request is recorded apart from the execution status (review round 2, #5)
        assert queued["status"] == "done" and queued["force_llm"] == 1
        assert queued["reprocess_request"] == queued["reprocess_handled"] + 1
        assert list(worker.pipeline.conv_dir(row["id"]).glob("llm-*.json"))  # deleted by the worker, not the CLI
        worker.tick(T0 + 300)
        done = worker.db.one("SELECT * FROM conversations WHERE id=?", (row["id"],))
        assert done["status"] == "done" and done["force_llm"] == 0
        assert done["reprocess_request"] == done["reprocess_handled"]
    finally:
        lock.release()
    assert lock.acquire()  # released locks can be taken again
    lock.release()


class SlowCountingStt(FakeStt):
    calls = 0
    guard = threading.Lock()

    def transcribe(self, request):
        with self.guard:
            SlowCountingStt.calls += 1
        time.sleep(0.3)
        return super().transcribe(request)


def test_f10_two_workers_never_advance_the_same_conversation(client, worker, settings):
    replay(client, SPEECH)
    run = worker.pipeline.run
    worker.pipeline.run = lambda now, limit=20: 0
    worker.tick(T0 + 200)
    worker.pipeline.run = run
    (row,) = convs(worker)
    assert row["status"] == "closed"
    other = Worker(settings, Database(settings.db_path))
    SlowCountingStt.calls = 0
    worker.providers._stt = SlowCountingStt()
    other.providers._stt = SlowCountingStt()
    threads = [threading.Thread(target=w.pipeline.advance, args=(row["id"], T0 + 210)) for w in (worker, other)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert SlowCountingStt.calls == 1


# 11 ----------------------------------------------------------------------------------------------


def test_f11_republishing_after_a_crash_reuses_the_existing_file(client, worker, settings):
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    # crash between writing the note and recording it
    worker.db.execute(
        "UPDATE conversations SET note_path=NULL, status='summarizing', content_sha=NULL, revision=0 WHERE id=?", (row["id"],)
    )
    worker.tick(T0 + 300)
    files = sorted(p.name for p in (settings.vault_dir / "Conversations").rglob("*.md"))
    assert len(files) == 1 and convs(worker)[0]["note_path"] == row["note_path"]


# 12 ----------------------------------------------------------------------------------------------


def test_f12_seal_after_the_last_chunk_was_processed_flushes_the_pending_frame(client, worker):
    capture = str(uuid.uuid4())
    envs = live_envelopes(synth_speech_like(2.0), capture_id=capture, device_id=DEVICE, started_at=STARTED,
                          offline_storage=False)  # fmt: skip
    upload_all(client, capture, envs)
    worker.tick(T0 + 100)
    chunk = worker.db.one("SELECT * FROM chunks WHERE capture_id=?", (capture,))
    assert sum(n for _, n in json.loads(chunk["runs_json"])) == 99 * 320
    live_seal(client, capture, envs)
    worker.tick(T0 + 200)
    chunk = worker.db.one("SELECT * FROM chunks WHERE capture_id=?", (capture,))
    assert json.loads(chunk["stats_json"])["final"] is True
    assert sum(n for _, n in json.loads(chunk["runs_json"])) == 100 * 320


# 13 ----------------------------------------------------------------------------------------------


def test_f13_speech_exactly_120s_apart_splits(client, worker):
    replay(client, np.concatenate([silence(10), tone(1), silence(120), tone(1), silence(3)]))
    worker.tick(T0 + 600)
    assert len(convs(worker)) == 2


def test_f13_speech_119s_apart_joins(client, worker):
    replay(client, np.concatenate([silence(10), tone(1), silence(119), tone(1), silence(3)]))
    worker.tick(T0 + 600)
    assert len(convs(worker)) == 1


# 14 ----------------------------------------------------------------------------------------------


def test_f14_ring_sequence_gap_and_dropped_records_are_reported(client, worker, settings):
    capture = str(uuid.uuid4())
    part_a = ring_records_at(synth_speech_like(3, seed=1), int(T0) + 60)
    part_b = ring_records_at(synth_speech_like(3, seed=2), int(T0) + 93)  # 30 s later, 10 records missing
    c0 = envelope(ring_header(capture, 0, 40, len(part_a), dropped=100), b"".join(part_a))
    c1 = envelope(ring_header(capture, 1, 40 + len(part_a) + 10, len(part_b), dropped=100), b"".join(part_b))
    upload_all(client, capture, [c0, c1])
    ring_sync(client, T0 + 400, last_chunk_sequence=1, capture=capture)
    worker.tick(T0 + 700)
    (row,) = convs(worker)
    gaps = json.loads(row["gaps_json"])
    assert any(a <= T0 + 64 and b >= T0 + 92 for a, b in gaps)  # the sequence gap
    text = note_text(settings, row)
    assert "Audio missing" in text and "audio_gaps: []" not in text


def test_f14_dropped_counter_is_reported_once(client, worker):
    for offset, first_sequence in ((-5000, 0), (0, 200)):
        capture = str(uuid.uuid4())
        records = ring_records_at(synth_speech_like(2, seed=offset % 7), int(T0) + offset)
        body = envelope(ring_header(capture, 0, first_sequence, len(records), dropped=100), b"".join(records))
        header = parse_envelope(body).header.model_dump(mode="json")
        header["capture_started_at"] = iso(T0 + offset + 100)  # sync sessions happen in order
        upload_all(client, capture, [build_envelope(header, b"".join(records))])
        ring_sync(client, T0 + offset + 100, last_chunk_sequence=0, capture=capture, info_read_seq=first_sequence)
        worker.tick(T0 + offset + 200)
    kinds = [r["kind"] for r in worker.db.query("SELECT kind FROM losses ORDER BY start")]
    assert kinds == ["ring_dropped"]  # the second sync reports the same cumulative 100: nothing new


def test_f14_live_notification_loss_is_reported(client, worker, settings):
    capture = str(uuid.uuid4())
    frames = encode_frames(np.concatenate([synth_speech_like(10), silence(1)]))
    records = []
    for index, packet, _ in frames:
        if 200 <= index < 300:
            continue  # 100 notifications (2 s) lost over the air
        flags = FLAG_SESSION_START if index == 0 else 0
        records.append(encode_ble_record((index + 1) * 20_000, encode_notification(index, 0, packet), flags))
    header = base_header(capture_id=capture, seq=0, device_id=DEVICE, source="live_ble", payload_format="ble_notifications_v1",
                         codec_id=21, started_at=STARTED, start_us=0, end_us=12_000_000, record_count=len(records),
                         offline_storage=False)  # fmt: skip
    body = envelope(header, b"".join(records))
    upload_all(client, capture, [body])
    live_seal(client, capture, [body])
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert any(b - a >= 1.5 and a >= T0 + 3.9 and b <= T0 + 6.2 for a, b in json.loads(row["gaps_json"]))
    assert "Audio missing" in note_text(settings, row)


# 15 ----------------------------------------------------------------------------------------------


def test_f15_backward_rtc_jump_starts_a_marked_run():
    packets = [p for _, p, _ in encode_frames(synth_speech_like(2))]
    records = pack_records([(int(T0), p) for p in packets[:50]]) + pack_records([(int(T0) - 3600, p) for p in packets[50:]])
    env = parse_envelope(envelope(ring_header(str(uuid.uuid4()), 0, 7, len(records)), b"".join(records)))
    result = CaptureTimeline(320).decode_chunk(env)
    assert [round(p.start - T0) for p in result.pieces] == [0, -3600]
    assert result.stats["clock_suspect"] == 1


# 16 ----------------------------------------------------------------------------------------------


def test_f16_large_forward_sequence_jump_resynchronizes():
    asm = BleFrameAssembler()
    events = asm.feed(0, FLAG_SESSION_START, encode_notification(0, 0, b"a"))
    for i in range(100):
        events += asm.feed(1_000_000 + i * 20_000, 0, encode_notification(40000 + i, 0, bytes([i])))
    events += asm.flush()
    # the frame pending at the jump is unprovable and dropped (like any gap); everything after is kept
    assert len([e for e in events if e.kind == "frame"]) == 100
    assert asm.last_seq == 40099
    assert any(e.kind == "reset" and e.reason == "resync" for e in events)


def test_f16_nearby_stale_redelivery_is_still_dropped():
    asm = BleFrameAssembler()
    events = asm.feed(0, FLAG_SESSION_START, encode_notification(500, 0, b"a"))
    events += asm.feed(20_000, 0, encode_notification(501, 0, b"b"))
    events += asm.feed(40_000, 0, encode_notification(498, 0, b"x"))
    events += asm.flush()
    assert [e.data for e in events if e.kind == "frame"] == [b"a", b"b"]


# 17 ----------------------------------------------------------------------------------------------


def test_f17_failed_rerender_is_retried(client, worker, settings, monkeypatch):
    capture = live(client, SPEECH, offline_storage=False)
    worker.tick(T0 + 300)
    event(client, "button", at=T0 + 5, capture_id=capture, offset_us=5_000_000, data={"code": 1})
    real = conv_mod.write_if_changed
    failures = []

    def flaky(path, content):
        if "Conversations" in str(path) and not failures:
            failures.append(path)
            raise OSError("notes volume unavailable")
        return real(path, content)

    monkeypatch.setattr(conv_mod, "write_if_changed", flaky)
    worker.tick(T0 + 310)
    assert failures and "## Bookmarks" not in note_text(settings, convs(worker)[0])
    worker.tick(T0 + 400)
    assert "## Bookmarks" in note_text(settings, convs(worker)[0])


# 18 ----------------------------------------------------------------------------------------------


def test_f18_daily_index_is_rebuilt_after_a_crash(client, worker, settings, monkeypatch):
    replay(client, SPEECH)

    def crash(*args, **kwargs):
        raise RuntimeError("killed")

    monkeypatch.setattr(worker.pipeline, "render_dailies", crash)
    with pytest.raises(RuntimeError):
        worker.tick(T0 + 200)
    assert convs(worker)[0]["status"] == "done"
    assert not (settings.vault_dir / "Daily").exists()
    Worker(settings, Database(settings.db_path)).tick(T0 + 300)
    assert (settings.vault_dir / "Daily" / "2026-09-26.md").exists()


# 19 ----------------------------------------------------------------------------------------------


def test_f19_rebuild_uses_the_summary_a_note_was_made_with(client, worker, settings, monkeypatch):
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    path = settings.vault_dir / row["note_path"]
    before = path.read_bytes()
    path.unlink()
    monkeypatch.setattr(prompt, "PROMPT_VERSION", prompt.PROMPT_VERSION + 1)
    result = CliRunner().invoke(cli, ["rebuild"], env=cli_env(settings))
    assert result.exit_code == 0 and "skipped 0" in result.output, result.output
    assert path.read_bytes() == before


# 20 ----------------------------------------------------------------------------------------------


def test_f20_late_double_tap_annotates_the_finalized_note(client, worker, settings):
    capture = live(client, np.concatenate([silence(1), synth_speech_like(40), silence(2)]), offline_storage=False)
    worker.tick(T0 + 300)
    event(client, "button", at=T0 + 20, capture_id=capture, offset_us=20_000_000, data={"code": 2})
    worker.tick(T0 + 310)
    rows = convs(worker)
    assert len(rows) == 1
    assert "Double tap at 14:00:20" in note_text(settings, rows[0])
    assert worker.db.one("SELECT applied FROM events WHERE code=2")["applied"] == 1


# 21 ----------------------------------------------------------------------------------------------


def test_f21_ble_record_offsets_must_fit_the_declared_chunk(client, new_id):
    frames = encode_frames(synth_speech_like(1))
    def body(times, end_us):
        records = [encode_ble_record(t, encode_notification(i, 0, p), FLAG_SESSION_START if i == 0 else 0)
                   for (i, p, _), t in zip(frames, times, strict=True)]  # fmt: skip
        capture = new_id()
        h = base_header(capture_id=capture, seq=0, device_id=DEVICE, source="live_ble", payload_format="ble_notifications_v1",
                        codec_id=21, started_at=STARTED, start_us=0, end_us=end_us, record_count=len(records))  # fmt: skip
        return capture, envelope(h, b"".join(records))

    capture, b = body([(i + 1) * 20_000 for i in range(len(frames))], 1)
    assert put_chunk(client, capture, 0, b).status_code == 422
    times = [(i + 1) * 20_000 for i in range(len(frames))]
    times[10], times[11] = times[11], times[10]
    capture, b = body(times, 2_000_000)
    assert put_chunk(client, capture, 0, b).status_code == 422
    capture, b = body([(i + 1) * 20_000 for i in range(len(frames))], 1_000_000)
    assert put_chunk(client, capture, 0, b).status_code == 201


# 22 ----------------------------------------------------------------------------------------------


class GermanStt(FakeStt):
    def transcribe(self, request):
        response = super().transcribe(request)
        response["results"]["channels"][0]["detected_language"] = "de"
        response["results"]["channels"][0]["language_confidence"] = 0.97
        return response


class RecordingLlm(FakeLlm):
    requests: list = []

    def summarize(self, request):
        RecordingLlm.requests.append(request)
        return super().summarize(request)


def test_f22_multi_language_uses_the_detected_language(tmp_path):
    settings = make_settings(tmp_path, stt_language="multi")
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    worker.providers._stt = GermanStt()
    worker.providers._llm = RecordingLlm()
    RecordingLlm.requests = []
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert "Respond entirely in German." in RecordingLlm.requests[0].user
    assert "language: de" in note_text(settings, row)
