"""Worker + conversation pipeline behaviors through the real HTTP ingest."""

import json
import time
import uuid
from datetime import timedelta

import numpy as np
from fastapi.testclient import TestClient
from typer.testing import CliRunner

from omi_notes.api import create_app
from omi_notes.cli import app as cli
from omi_notes.db import Database
from omi_notes.devtools import ring_envelopes, synth_speech_like
from omi_notes.pipeline.worker import Worker
from omi_notes.providers import LlmResult, ProviderError
from omi_notes.providers.fake import FakeLlm, FakeStt

from .conftest import DEVICE, cli_env, make_settings, put_chunk, upload_all
from .helpers import STARTED, T0, convs, event, live, note_text, replay, ring_sync, silence


class RenamingLlm(FakeLlm):
    def summarize(self, request):
        result = super().summarize(request)
        return LlmResult(data=result.data | {"title": "A Completely Different Title"}, model=result.model)


class FailingLlm:
    name, model = "anthropic", "claude-opus-5"

    def summarize(self, request):
        raise ProviderError("Anthropic auth error: invalid x-api-key", terminal=True, kind="auth")


class FillerStt(FakeStt):
    def transcribe(self, request):
        response = super().transcribe(request)
        for utt in response["results"]["utterances"]:
            utt["transcript"] = "Mm-hmm."
        return response


# -- notes lifecycle -------------------------------------------------------------------------------


def test_filename_frozen_my_notes_preserved_revision_bumped(client, worker, settings):
    replay(client, np.concatenate([silence(2), synth_speech_like(15), silence(3)]))
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "done" and row["revision"] == 1
    path = settings.notes_dir / row["note_path"]
    text = path.read_text().replace("<!-- my-notes:start -->\n\n", "<!-- my-notes:start -->\nCall Priya back.\n")
    path.write_text(text)

    # The summary changes (new model output): same file, new title inside, notes kept, revision 2.
    worker.providers._llm = RenamingLlm()
    for cached in worker.pipeline.conv_dir(row["id"]).glob("llm-*.json"):
        cached.unlink()
    worker.db.execute("UPDATE conversations SET status='summarizing' WHERE id=?", (row["id"],))
    worker.tick(T0 + 300)
    (after,) = convs(worker)
    assert after["note_path"] == row["note_path"]
    text = path.read_text()
    assert "title: A Completely Different Title" in text and "# 🧪 A Completely Different Title" in text
    assert "<!-- my-notes:start -->\nCall Priya back.\n<!-- my-notes:end -->" in text
    assert after["revision"] == 2

    # Re-rendering with nothing new neither rewrites the file nor bumps the revision.
    mtime = path.stat().st_mtime_ns
    worker.db.execute("UPDATE conversations SET needs_render=1 WHERE id=?", (row["id"],))
    worker.tick(T0 + 400)
    assert path.stat().st_mtime_ns == mtime and convs(worker)[0]["revision"] == 2


def test_llm_none_writes_transcript_only_note(tmp_path):
    settings = make_settings(tmp_path, llm_provider="none")
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    replay(client, np.concatenate([silence(1), synth_speech_like(10), silence(2)]))
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "done" and row["note_path"].startswith("Conversations/")
    text = note_text(settings, row)
    assert "status: transcript_only" in text and "Summary unavailable (LLM_PROVIDER=none)" in text


def test_llm_auth_failure_publishes_transcript_then_retry_failed(client, worker, settings):
    worker.providers._llm = FailingLlm()
    replay(client, np.concatenate([silence(1), synth_speech_like(10), silence(2)]))
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "failed" and row["failed_stage"] == "summarizing" and row["error_kind"] == "auth"
    assert "status: transcript_only" in note_text(settings, row)
    status_md = (settings.notes_dir / "_status.md").read_text()
    assert "rejected our credentials" in status_md and "invalid x-api-key" in status_md

    result = CliRunner().invoke(cli, ["retry-failed"], env=cli_env(settings))
    assert result.exit_code == 0 and "Queued 1 conversation(s)" in result.output
    worker.providers._llm = FakeLlm()
    worker.tick(T0 + 300)
    (after,) = convs(worker)
    assert after["status"] == "done" and after["note_path"] == row["note_path"] and after["error"] is None
    assert "status: completed" in note_text(settings, after)


def test_stt_auth_failure_is_terminal_and_visible(tmp_path):
    settings = make_settings(tmp_path, stt_provider="deepgram")  # no DEEPGRAM_API_KEY
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    replay(client, np.concatenate([silence(1), synth_speech_like(10), silence(2)]))
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "failed" and row["failed_stage"] == "transcribing" and row["note_path"] is None
    stub = next((settings.notes_dir / "_in-progress").glob("*.md")).read_text()
    assert "Processing failed" in stub and "DEEPGRAM_API_KEY" in stub
    assert "rejected our credentials" in (settings.notes_dir / "_status.md").read_text()


def test_transient_failure_backs_off(client, worker):
    calls = []

    class Flaky(FakeLlm):
        def summarize(self, request):
            calls.append(1)
            if len(calls) == 1:
                raise ProviderError("overloaded", kind="transient")
            return super().summarize(request)

    worker.providers._llm = Flaky()
    replay(client, np.concatenate([silence(1), synth_speech_like(10), silence(2)]))
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "summarizing" and row["attempts"] == 1 and row["next_attempt_at"] == T0 + 230
    worker.tick(T0 + 210)
    assert len(calls) == 1
    worker.tick(T0 + 231)
    assert convs(worker)[0]["status"] == "done" and len(calls) == 2


def test_filler_is_discarded_by_rules_and_kept_in_discarded_folder(client, worker, settings):
    worker.providers._stt = FillerStt()
    replay(client, np.concatenate([silence(1), synth_speech_like(5), silence(2)]))
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "discarded" and row["note_path"].startswith("_discarded/")
    text = note_text(settings, row)
    assert "Discarded: only filler words" in text and "Mm-hmm." in text
    assert "## Discarded" in (settings.notes_dir / "Daily/2026-09-26.md").read_text()


# -- events ----------------------------------------------------------------------------------------


def test_double_tap_splits_and_single_tap_bookmarks(client, worker, settings):
    capture = live(client, np.concatenate([silence(1), synth_speech_like(60), silence(2)]), offline_storage=False)
    event(client, "button", at=T0 + 10, capture_id=capture, offset_us=10_000_000, data={"code": 1})
    event(client, "button", at=T0 + 31, capture_id=capture, offset_us=31_000_000, data={"code": 2})
    worker.tick(T0 + 300)
    rows = convs(worker)
    assert len(rows) == 2 and all(r["status"] == "done" for r in rows)
    assert rows[0]["end"] == rows[1]["start"] == T0 + 31
    first = note_text(settings, rows[0])
    assert "## Bookmarks" in first and "**14:00:10**" in first
    assert "## Bookmarks" not in note_text(settings, rows[1])


def test_late_bookmark_rerenders_finished_note(client, worker, settings):
    capture = live(client, np.concatenate([silence(1), synth_speech_like(20), silence(2)]), offline_storage=False)
    worker.tick(T0 + 300)
    (row,) = convs(worker)
    assert "## Bookmarks" not in note_text(settings, row)
    event(client, "button", at=T0 + 5, capture_id=capture, offset_us=5_000_000, data={"code": 1})
    worker.tick(T0 + 310)
    (after,) = convs(worker)
    assert "## Bookmarks" in note_text(settings, after) and after["revision"] == 2


def test_heartbeat_feeds_status(client, worker, settings):
    event(client, "heartbeat", at=T0, data={"battery": 83, "charging": True, "app_state": "background",
                                            "outbox_chunks": 3, "rtc_valid": False})  # fmt: skip
    worker.tick(T0 + 10)
    status_md = (settings.notes_dir / "_status.md").read_text()
    assert "Battery: 83% (charging)" in status_md and "Device clock not set" in status_md


# -- offline storage -------------------------------------------------------------------------------


def test_disconnect_provisional_then_late_ring_audio(client, worker, settings):
    ring_sync(client, T0)  # connected at T0 with nothing unread
    live(client, np.concatenate([silence(1), synth_speech_like(20), silence(4)]), offline_storage=True)
    worker.tick(T0 + 400)
    assert convs(worker)[0]["status"] == "open"  # waiting for the offline sync after the disconnect
    worker.tick(T0 + 25 + 120 + 1200 + 5)
    (first,) = convs(worker)
    assert first["status"] == "done" and first["provisional"] == 1
    assert "provisional: true" in note_text(settings, first)

    # The phone reconnects at T0+2000 and syncs what the pendant recorded while away.
    ring_capture = str(uuid.uuid4())
    envs, _ = ring_envelopes(synth_speech_like(15, seed=3), capture_id=ring_capture, device_id=DEVICE,
                             started_at=STARTED + timedelta(seconds=2000), audio_start_epoch=int(T0) + 60)  # fmt: skip
    upload_all(client, ring_capture, envs)
    ring_sync(client, T0 + 2000, last_chunk_sequence=len(envs) - 1, capture=ring_capture)
    worker.tick(T0 + 2010)
    rows = convs(worker)
    assert len(rows) == 2
    late = rows[1]
    assert late["status"] == "done" and late["late_audio"] == 1 and late["related_id"] == first["id"]
    text = note_text(settings, late)
    assert "late_audio: true" in text and f"[[{first['note_path'][:-3]}]]" in text
    assert "sources:\n- offline" in text


def test_ring_seal_waits_for_its_chunks(client, worker, settings):
    ring_sync(client, T0)
    live(client, np.concatenate([silence(1), synth_speech_like(20), silence(4)]), offline_storage=True)
    ring_capture = str(uuid.uuid4())
    ring_sync(client, T0 + 300, last_chunk_sequence=0, capture=ring_capture)  # seal arrives first
    worker.tick(T0 + 400)
    assert convs(worker)[0]["status"] == "open"
    envs, _ = ring_envelopes(silence(3), capture_id=ring_capture, device_id=DEVICE,
                             started_at=STARTED + timedelta(seconds=300), audio_start_epoch=int(T0) + 100)  # fmt: skip
    upload_all(client, ring_capture, envs)
    worker.tick(T0 + 410)
    (row,) = convs(worker)
    assert row["status"] == "done" and row["provisional"] == 0


def test_duplicate_ring_records_are_ignored(client, worker, settings):
    ring_sync(client, T0 - 10)
    pcm = synth_speech_like(10, seed=4)
    for _ in range(2):  # the firmware resent the same records in a second sync session
        capture = str(uuid.uuid4())
        envs, _ = ring_envelopes(pcm, capture_id=capture, device_id=DEVICE, started_at=STARTED,
                                 audio_start_epoch=int(T0) - 500, first_sequence=40)  # fmt: skip
        upload_all(client, capture, envs)
        ring_sync(client, T0, last_chunk_sequence=len(envs) - 1, capture=capture)
    worker.tick(T0 + 100)
    stats = [json.loads(r["stats_json"]) for r in worker.db.query("SELECT stats_json FROM chunks ORDER BY received_at")]
    assert stats[0]["ring_duplicates"] == 0 and stats[1]["ring_duplicates"] == stats[0]["ring_records"]
    (row,) = convs(worker)
    assert row["status"] == "done"


# -- robustness ------------------------------------------------------------------------------------


def test_restart_resumes_interrupted_stage(client, worker, settings):
    replay(client, np.concatenate([silence(1), synth_speech_like(10), silence(2)]))
    worker.pipeline.run = lambda now, limit=20: 0  # "crash" before any stage runs
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["status"] == "closed"
    worker.db.execute("UPDATE conversations SET status='transcribing' WHERE id=?", (row["id"],))
    fresh = Worker(settings, Database(settings.db_path))  # new process
    fresh.tick(T0 + 210)
    assert convs(fresh)[0]["status"] == "done"


def test_chunk_decode_failure_is_retryable_not_silence(client, worker, settings):
    capture = replay(client, np.concatenate([silence(1), synth_speech_like(10), silence(2)]))
    path = next(settings.raw_dir.rglob("0.omnc"))
    good = path.read_bytes()
    path.write_bytes(b"corrupted")
    worker.tick(T0 + 200)
    chunk = worker.db.one("SELECT * FROM chunks WHERE capture_id=?", (capture,))
    assert chunk["status"] == "pending" and chunk["attempts"] == 1 and convs(worker) == []
    path.write_bytes(good)
    worker.tick(T0 + 260)
    assert convs(worker)[0]["status"] == "done"


def test_retention_deletes_old_raw_audio_only_when_done(client, worker, settings):
    capture = replay(client, np.concatenate([silence(1), synth_speech_like(10), silence(2)]))
    worker.tick(T0 + 200)
    path = next(settings.raw_dir.rglob("0.omnc"))
    body = path.read_bytes()
    assert worker.retention(time.time() + 29 * 86400) == 0
    assert worker.retention(time.time() + 31 * 86400) == 1
    assert not path.exists()
    # the ledger still knows the chunk: a re-upload is an idempotent duplicate
    assert put_chunk(client, capture, 0, body).status_code == 200


def test_rebuild_makes_no_api_calls_and_reproduces_notes(client, worker, settings):
    replay(client, np.concatenate([silence(1), synth_speech_like(10), silence(2)]))
    worker.tick(T0 + 200)
    before = {p.relative_to(settings.notes_dir): p.read_bytes() for p in settings.notes_dir.rglob("*.md")}
    for p in settings.notes_dir.rglob("*.md"):
        p.unlink()
    env = cli_env(settings) | {"STT_PROVIDER": "deepgram", "LLM_PROVIDER": "anthropic"}  # no keys: any call would fail
    result = CliRunner().invoke(cli, ["rebuild"], env=env)
    assert result.exit_code == 0, result.output
    after = {p.relative_to(settings.notes_dir): p.read_bytes() for p in settings.notes_dir.rglob("*.md")}
    conversation = [p for p in before if p.parts[0] == "Conversations"]
    assert conversation and all(after[p] == before[p] for p in conversation)
    assert after[next(p for p in before if p.parts[0] == "Daily")] == before[next(p for p in before if p.parts[0] == "Daily")]
