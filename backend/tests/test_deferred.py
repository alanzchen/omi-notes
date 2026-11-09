"""Short sessions deferred (docs/architecture.md, "Deferred short sessions"): under 60 s of speech, a finalized
conversation waits in the lowest lane, transcribed only when nothing else is runnable or when the owner asks
(`POST /v1/conversations/{id}/transcribe`, a durable operation). Fakes only."""

from __future__ import annotations

import json
import shutil
import time
import uuid
from datetime import timedelta

import numpy as np
from fastapi.testclient import TestClient

from omi_notes import deferral
from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.pipeline import sources
from omi_notes.pipeline.conversations import IDLE_FAIR_EVERY, queue_counts
from omi_notes.pipeline.worker import Worker
from omi_notes.providers import ProviderError
from omi_notes.providers.fake import FakeLlm, FakeStt

from .conftest import AUTH
from .helpers import STARTED, T0, convs, live, replay, silence
from .test_speaker_learning import ALAN, voice

SR = 16000


class CountingStt(FakeStt):
    def __init__(self):
        self.seconds: list[float] = []
        self.during = None
        self.fail: ProviderError | None = None

    def transcribe(self, request):
        self.seconds.append(round(request.duration, 1))
        if self.fail:
            raise self.fail
        if self.during:
            during, self.during = self.during, None
            during()
        return super().transcribe(request)


class CountingLlm(FakeLlm):
    def __init__(self):
        self.calls = 0

    def summarize(self, request):
        self.calls += 1
        return super().summarize(request)


def fakes(worker) -> tuple[CountingStt, CountingLlm]:
    worker.providers._stt, worker.providers._llm = stt, llm = CountingStt(), CountingLlm()
    return stt, llm


def short(client, seconds: float = 8.0, at=STARTED):
    replay(client, np.concatenate([silence(1), voice(seconds, ALAN, 7), silence(3)]), start=at)


def busy(worker, monkeypatch):
    """A server that always has other work pending: deferred sessions are never claimed by the idle lane."""
    real = worker.pipeline.run
    monkeypatch.setattr(worker.pipeline, "run", lambda now, **kw: real(now, **(kw | {"idle": False})))
    return real


def record(worker, conv_id: str) -> dict:
    return json.loads((worker.pipeline.conv_dir(conv_id) / "conversation.json").read_text())


def listed(client) -> list[dict]:
    return client.get("/v1/conversations/recent", headers=AUTH).json()["conversations"]


def transcribe(client, conv_id: str, rid: str | None = None):
    return client.post(f"/v1/conversations/{conv_id}/transcribe", json={"request_id": rid or str(uuid.uuid4())}, headers=AUTH)


def op_file(settings, op_id: str) -> dict:
    return json.loads((settings.vault_dir / "_omi" / "operations" / f"{op_id}.json").read_text())


# -- the policy -------------------------------------------------------------------------------------------------------


def test_a_short_session_is_deferred_at_closure_and_shown_as_such_everywhere(client, worker, settings, monkeypatch):
    stt, llm = fakes(worker)
    busy(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "closed" and stt.seconds == [] and llm.calls == 0, "not transcribed by default"
    block = record(worker, row["id"])["deferral"]
    assert block["policy"] == "short_speech" and block["threshold_s"] == 60.0 and 7 < block["speech_s"] < 10
    assert block["provisional"] == {"class": "undetermined", "confidence": None, "rule_id": "none-v1", "model": None}
    assert "requested" not in block
    stub = next((settings.vault_dir / "_in-progress").glob("*.md")).read_text()
    assert "stage: deferred" in stub and "Deferred" in stub and "audio is kept" in stub
    (shown,) = listed(client)
    assert shown["state"]["code"] == "deferred" and shown["deferred"]["state"] == "waiting"
    assert 7 < shown["speech_s"] < 10 and shown["duration_s"] >= shown["speech_s"]
    assert shown["recording_class"]["class"] == "undetermined" and shown["recording_class"]["provisional"] is True
    queue = queue_counts(worker.db)
    assert queue["conversations_pending"] == 0 and queue["conversations_deferred"] == 1
    days = client.get("/v1/conversations/recent", headers=AUTH).json()["days"]
    assert days == {"2026-09-26": {"short": 1, "deferred": 1, "requested": 0, "issues": 0}}
    daily = (settings.vault_dir / "Daily" / "2026-09-26.md").read_text()
    assert "short, not transcribed yet" in daily
    assert "deferred_transcription" in client.get("/v1/status", headers=AUTH).json()["features"]


def test_the_idle_lane_transcribes_a_deferred_session_when_nothing_else_is_runnable(client, worker, settings):
    stt, llm = fakes(worker)
    short(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "done" and row["note_path"] and len(stt.seconds) == 1 and llm.calls == 1
    assert record(worker, row["id"])["deferral"]["policy"] == "short_speech", "kept as history"
    assert not list((settings.vault_dir / "_in-progress").glob("*.md"))
    assert listed(client)[0]["deferred"] is None and listed(client)[0]["state"]["code"] == "ready"
    detail = client.get(f"/v1/conversations/{row['id']}", headers=AUTH).json()
    assert listed(client)[0]["revision"] == detail["revision"] == row["revision"] >= 1


def test_long_sessions_enrollment_and_too_short_ones_are_never_deferred(client, worker, monkeypatch):
    fakes(worker)
    busy(worker, monkeypatch)
    replay(client, np.concatenate([silence(1), voice(0.8, ALAN, 7), silence(3)]))
    worker.tick(T0 + 400)
    (tiny,) = convs(worker)
    assert tiny["status"] == "discarded" and tiny["relevance"] == "too_short" and tiny["deferral"] is None
    assert deferral.decide(60, 60.0, 0, too_short_s=1.5) is None and deferral.decide(0, 10, 0, too_short_s=1.5) is None
    assert deferral.decide(60, 1.5, 0, too_short_s=1.5) is not None


def test_new_work_goes_first_and_the_deferred_session_runs_once_idle(client, worker, monkeypatch):
    stt, _ = fakes(worker)
    real = busy(worker, monkeypatch)
    short(client)  # older, short
    replay(client, np.concatenate([silence(1), voice(65, 300, 3), silence(3)]), start=STARTED + timedelta(hours=1))
    worker.tick(T0 + 3600 + 500)
    deferred, long_one = convs(worker)
    assert long_one["status"] == "done" and deferred["status"] == "closed" and len(stt.seconds) == 1
    real(T0 + 3600 + 600)  # the queue is otherwise idle now
    assert convs(worker)[0]["status"] == "done" and len(stt.seconds) == 2


def test_a_deferred_job_yields_to_new_work_between_transcription_and_summary(client, worker, monkeypatch):
    stt, llm = fakes(worker)
    real = busy(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    (deferred,) = convs(worker)
    insert(worker, "new-work", T0 + 3600, next_attempt_at=T0 + 10**6, error="waiting")
    # new work becomes runnable while the deferred session is being transcribed
    stt.during = lambda: worker.db.execute("UPDATE conversations SET next_attempt_at=NULL WHERE id='new-work'")
    assert worker.pipeline.next_claim(T0 + 500)["id"] == deferred["id"]
    worker.pipeline.advance(deferred["id"], T0 + 500)
    row = worker.db.one("SELECT * FROM conversations WHERE id=?", (deferred["id"],))
    assert row["status"] == "summarizing" and len(stt.seconds) == 1 and llm.calls == 0, "its summary waits"
    assert worker.pipeline.lane(deferred["id"], T0 + 501) == 2, "the summary keeps background priority"
    assert worker.pipeline.next_claim(T0 + 501)["id"] == "new-work"
    worker.db.execute("DELETE FROM conversations WHERE id='new-work'")
    real(T0 + 510)
    assert convs(worker)[0]["status"] == "done" and len(stt.seconds) == 1 and llm.calls == 1


# -- the owner's request ---------------------------------------------------------------------------------------------


def test_a_transcription_request_is_durable_shared_and_runs_with_ordinary_work(client, worker, settings, monkeypatch):
    stt, _ = fakes(worker)
    busy(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    r = transcribe(client, row["id"], rid := str(uuid.uuid4()))
    assert r.status_code == 202 and r.json()["operation"]["kind"] == "transcribe", r.text
    assert op_file(settings, rid)["state"] == "accepted"
    assert record(worker, row["id"])["deferral"]["requested"]["op"] == rid, "committed into the vault record"
    again = transcribe(client, row["id"], rid)
    other = transcribe(client, row["id"])
    assert again.status_code == 200 and other.status_code == 200 and other.json()["operation"]["id"] == rid
    (shown,) = listed(client)
    assert shown["deferred"]["state"] == "requested" and shown["state"]["code"] == "processing"
    assert client.get("/v1/conversations/recent", headers=AUTH).json()["days"]["2026-09-26"]["requested"] == 1
    worker.tick(T0 + 410)  # still a busy server: the request runs with ordinary work
    (row,) = convs(worker)
    assert row["status"] == "done" and len(stt.seconds) == 1
    assert op_file(settings, rid)["state"] == "done"
    assert client.get(f"/v1/operations/{rid}", headers=AUTH).json()["operation"]["state"] == "done"
    late = transcribe(client, row["id"])
    assert late.status_code == 200 and late.json()["operation"]["state"] == "done" and len(stt.seconds) == 1, \
        "already finished: no fresh inference"


def test_a_request_while_the_idle_lane_holds_the_conversation_shares_its_work(client, worker, settings, monkeypatch):
    fakes(worker)
    busy(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    token = worker.pipeline.claim(row["id"])  # an idle claim is running
    r = transcribe(client, row["id"], rid := str(uuid.uuid4()))
    assert r.status_code == 202 and r.json()["operation"]["state"] == "running", r.text
    assert op_file(settings, rid)["state"] == "accepted", "acceptance is durable before the answer"
    assert worker.db.one("SELECT transcribe_op FROM conversations")["transcribe_op"] == rid
    assert "requested" not in record(worker, row["id"])["deferral"]
    assert worker.pipeline.lane(row["id"], T0 + 401) == 0, "the running job sees the request (summary not deferred)"
    worker.pipeline.release(row["id"], token)
    worker.tick(T0 + 410)
    (row,) = convs(worker)
    assert row["status"] == "done" and record(worker, row["id"])["deferral"]["requested"]["op"] == rid
    assert op_file(settings, rid)["state"] == "done"


def reopen(settings, monkeypatch):
    shutil.rmtree(settings.index_dir)
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    stt, _ = fakes(worker)
    busy(worker, monkeypatch)
    return client, worker, stt


def test_a_request_bypasses_deferral_after_a_rebuild(client, worker, settings, monkeypatch):
    fakes(worker)
    busy(worker, monkeypatch)
    short(client)
    short(client, at=STARTED + timedelta(hours=1))
    worker.tick(T0 + 3600 + 400)
    committed, pending = convs(worker)
    transcribe(client, committed["id"], rid1 := str(uuid.uuid4()))
    token = worker.pipeline.claim(pending["id"])
    transcribe(client, pending["id"], rid2 := str(uuid.uuid4()))  # only in its operation file (and the old index)
    worker.pipeline.release(pending["id"], token)
    client, worker, stt = reopen(settings, monkeypatch)
    for t in range(4):  # the replay after a rebuild, then normal (busy) ticks
        worker.tick(T0 + 3600 + 1000 + t)
    rows = {r["id"]: r for r in convs(worker)}
    assert rows[committed["id"]]["status"] == "done" and rows[pending["id"]]["status"] == "done"
    assert op_file(settings, rid1)["state"] == "done" and op_file(settings, rid2)["state"] == "done"


def test_a_request_never_forces_fresh_inference(client, worker, settings, monkeypatch):
    stt, llm = fakes(worker)
    busy(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    worker.pipeline.transcribe(row["id"], T0 + 450)  # the idle lane transcribed it and yielded before its summary
    assert len(stt.seconds) == 1 and convs(worker)[0]["status"] == "summarizing"
    transcribe(client, row["id"])
    worker.tick(T0 + 500)
    assert convs(worker)[0]["status"] == "done" and len(stt.seconds) == 1 and llm.calls == 1, "its transcript was used"


def test_a_requested_session_that_fails_is_retried_without_being_deferred_again(client, worker, settings, monkeypatch):
    stt, _ = fakes(worker)
    busy(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    stt.fail = ProviderError("bad key", terminal=True, kind="auth")
    transcribe(client, row["id"], rid := str(uuid.uuid4()))
    worker.tick(T0 + 410)
    (row,) = convs(worker)
    assert row["status"] == "failed" and op_file(settings, rid)["state"] == "failed"
    assert transcribe(client, row["id"]).status_code == 409, "a failure is retried, not requested again"
    stt.fail = None
    r = client.post(f"/v1/conversations/{row['id']}/retry", json={"request_id": str(uuid.uuid4())}, headers=AUTH)
    assert r.status_code == 202, r.text
    worker.tick(T0 + 420)
    assert convs(worker)[0]["status"] == "done"


def test_requests_are_validated(client, worker, monkeypatch):
    fakes(worker)
    busy(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert transcribe(client, row["id"], "not-a-uuid").status_code == 422
    assert transcribe(client, str(uuid.uuid4())).status_code == 404
    rid = str(uuid.uuid4())
    assert transcribe(client, row["id"], rid).status_code == 202
    replay(client, np.concatenate([silence(1), voice(8, ALAN, 7), silence(3)]), start=STARTED + timedelta(hours=2))
    worker.tick(T0 + 7200 + 400)
    other = convs(worker)[-1]
    assert transcribe(client, other["id"], rid).status_code == 409, "a request id belongs to one conversation"


def test_changing_a_deferred_sessions_kind_updates_it_and_schedules_nothing(client, worker, monkeypatch):
    stt, llm = fakes(worker)
    real = busy(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    r = client.put(f"/v1/conversations/{row['id']}/class",
                   json={"class": "monologue", "request_id": "r1", "set_at": "2026-11-08T20:00:00Z"}, headers=AUTH)  # fmt: skip
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["class"] == "monologue" and body["overridden"] is True and body["provisional"] is True
    assert listed(client)[0]["recording_class"]["class"] == "monologue"
    worker.tick(T0 + 500)
    worker.pipeline.reconcile_classes(T0 + 510)
    worker.tick(T0 + 520)
    assert convs(worker)[0]["status"] == "closed" and stt.seconds == [] and llm.calls == 0, "nothing scheduled"
    real(T0 + 600)
    (row,) = convs(worker)
    applied = json.loads(row["index_json"])["recording_class"]
    assert row["status"] == "done" and applied["class"] == "monologue" and applied["revision"] == 1
    assert worker.pipeline.reconcile_classes(T0 + 700) == 0


# -- Watch and pendant -------------------------------------------------------------------------------------------------


def test_a_deferred_pendant_sibling_never_makes_a_watch_recording_wait(client, worker, monkeypatch):
    from .test_watch_sources import WATCH, heard_by_watch, talk

    fakes(worker)
    real = busy(worker, monkeypatch)
    speech = np.concatenate([silence(1), talk(20, 1), silence(2)])
    live(client, speech, offline_storage=False)
    replay(client, heard_by_watch(speech), start=STARTED + timedelta(seconds=4), source="watch_mic", device=WATCH)
    for t in range(int(T0) + 300, int(T0) + 700, 60):
        worker.tick(t)
    rows = convs(worker)
    pendant = next(r for r in rows if r["device_id"] != WATCH)
    watch = next(r for r in rows if r["device_id"] == WATCH)
    assert deferral.waiting(pendant) and deferral.waiting(watch)
    assert sources.ready(worker.pipeline, watch, T0 + 700), "settled: no 30-minute wait for a deferred sibling"
    real(T0 + 710)
    watch = next(r for r in convs(worker) if r["device_id"] == WATCH)
    decision = sources.read(worker.pipeline, watch["id"])
    assert decision["decision"] == "alternate" and decision["of"] == [pendant["id"]], decision


# -- the one claim decision ------------------------------------------------------------------------------------------


def insert(worker, conv_id: str, start: float, status: str = "closed", **cols) -> None:
    now = time.time()
    worker.db.execute("INSERT INTO conversations (id, device_id, start, end, status, created_at, updated_at, finalized_at) "
                      "VALUES (?,?,?,?,?,?,?,?)", (conv_id, "d", start, start + 10, status, now, now, start + 200))  # fmt: skip
    if cols:
        worker.db.execute(f"UPDATE conversations SET {', '.join(f'{k}=?' for k in cols)} WHERE id=?", (*cols.values(), conv_id))


DEFERRED = json.dumps({"policy": "short_speech", "threshold_s": 60.0, "speech_s": 9.0, "decided_at": 0,
                       "provisional": {"class": "undetermined", "confidence": None, "rule_id": "none-v1"}})  # fmt: skip


def test_a_class_never_lifts_a_rerun_or_a_deferred_session_above_new_work(client, worker):
    insert(worker, "rerun", 100, "summarizing", reprocess_request=1)
    insert(worker, "deferred", 50, "summarizing", deferral=DEFERRED)
    insert(worker, "new", 300)
    worker.pipeline._class_rank.update(rerun=0, deferred=0)  # monologues
    assert worker.pipeline.next_claim(1000)["id"] == "new"
    assert worker.pipeline.next_claim(1000, exclude={"new"})["id"] == "rerun"


def test_retries_waiting_for_their_backoff_leave_the_slot_idle(client, worker):
    insert(worker, "waiting", 100, next_attempt_at=5000, error="overloaded")
    insert(worker, "deferred", 200, deferral=DEFERRED)
    assert worker.pipeline.next_claim(1000)["id"] == "deferred"
    assert worker.pipeline.next_claim(1000, idle=False) is None, "pending chunks: deferred work waits"
    assert worker.pipeline.next_claim(6000)["id"] == "waiting"


def test_idle_slots_periodically_take_the_oldest_deferred_session(client, worker):
    insert(worker, "rerun", 100, stt_ref="stt-old.json")
    insert(worker, "deferred", 50, deferral=DEFERRED)
    picks = [worker.pipeline.next_claim(1000)["id"] for _ in range(2 * IDLE_FAIR_EVERY)]
    assert picks.count("deferred") == 2 and picks[IDLE_FAIR_EVERY - 1] == "deferred"
    assert all(p == "rerun" for i, p in enumerate(picks) if (i + 1) % IDLE_FAIR_EVERY)


def test_a_requested_or_retried_deferred_session_is_ordinary_work(client, worker):
    insert(worker, "asked", 100, deferral=DEFERRED, transcribe_op=str(uuid.uuid4()))
    insert(worker, "retried", 110, deferral=DEFERRED, retry_op=str(uuid.uuid4()))
    insert(worker, "rerun", 50, stt_ref="stt-old.json")
    assert [worker.pipeline.next_claim(1000, exclude=set(x))["id"] for x in ([], ["asked"])] == ["asked", "retried"]


# -- Astra review of e1e7576..ce07e32 -----------------------------------------------------------------------------------


def vault_format(settings) -> int:
    return json.loads((settings.vault_dir / "_omi" / "VAULT.json").read_text())["format"]


def test_the_first_deferral_raises_the_vault_format_so_older_writers_refuse_it(client, worker, settings, monkeypatch):
    from omi_notes import records
    from omi_notes.vault import FORMAT, Vault, VaultError

    fakes(worker)
    busy(worker, monkeypatch)
    assert vault_format(settings) < 5
    seen = []
    real = records.write_record

    def spy(vault, record):
        if record.get("deferral"):
            seen.append(vault_format(settings))
        return real(vault, record)

    monkeypatch.setattr("omi_notes.pipeline.worker.write_record", spy)
    short(client)
    worker.tick(T0 + 400)
    assert seen == [5], "raised before the first record with a deferral block is written"
    assert FORMAT >= 5
    monkeypatch.setattr("omi_notes.vault.FORMAT", 4)  # a release from before deferral
    try:
        Vault.open(settings)
    except VaultError as exc:
        assert "newer" in str(exc)
    else:
        raise AssertionError("an older release opened a vault with deferral state")


def test_a_stale_vault_handle_never_lowers_the_format(client, worker, settings):
    from omi_notes.vault import Vault

    stale = Vault.open(settings)
    worker.vault.raise_format(5)
    stale.raise_format(3)
    assert vault_format(settings) == 5


def test_a_transcription_request_raises_the_vault_format_before_its_operation_file(client, worker, settings, monkeypatch):
    fakes(worker)
    worker.settings.defer_speech_seconds = 0  # a closed conversation without a deferral block
    busy(worker, monkeypatch)
    short(client)
    worker.db.execute("UPDATE conversations SET next_attempt_at=? WHERE 1", (T0 + 10**6,))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    worker.db.execute("UPDATE conversations SET status='closed', next_attempt_at=? WHERE id=?", (T0 + 10**6, row["id"]))
    (settings.vault_dir / "_omi" / "VAULT.json").write_text(json.dumps(
        json.loads((settings.vault_dir / "_omi" / "VAULT.json").read_text()) | {"format": 2}))
    worker.pipeline.vault.info["format"] = 2
    client.app.state.speakers.pipeline.vault.info["format"] = 2
    assert transcribe(client, row["id"]).status_code in (200, 202)
    assert vault_format(settings) == 5


def test_deferred_claims_stop_as_soon_as_chunks_arrive(client, worker):
    for i in range(3):
        insert(worker, f"d{i}", 100 + i, deferral=DEFERRED)
    advanced = []
    worker.pipeline.advance = lambda conv_id, now: advanced.append(conv_id)
    ready = iter([True, False, False])
    assert worker.pipeline.run(1000, idle=lambda: next(ready)) == 1 and advanced == ["d0"]


def test_a_reprocess_keeps_its_lane_through_its_summary(client, worker):
    insert(worker, "rerun", 100, "done", note_path="Conversations/x.md", reprocess_request=1)
    worker.pipeline._consume_reprocess(worker.pipeline._row("rerun"))
    worker.pipeline._set("rerun", status="summarizing")  # its transcription ran
    worker.pipeline._class_rank["rerun"] = 0  # a monologue
    insert(worker, "new", 300)
    assert worker.pipeline.lane("rerun", 1000) == 1
    assert worker.pipeline.next_claim(1000)["id"] == "new"


def test_hundreds_of_reruns_never_hide_the_deferred_lane(client, worker):
    for i in range(205):
        insert(worker, f"r{i:03d}", 10 + i, stt_ref="stt-old.json")
    insert(worker, "deferred", 5000, deferral=DEFERRED)
    picks = [worker.pipeline.next_claim(10**6)["id"] for _ in range(IDLE_FAIR_EVERY)]
    assert picks[-1] == "deferred", picks
    excluded = {f"r{i:03d}" for i in range(205)}
    assert worker.pipeline.next_claim(10**6, exclude=excluded)["id"] == "deferred"
