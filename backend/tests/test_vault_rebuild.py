"""Rebuilding the index from the vault (docs/vault.md, "Rebuild" proofs (a)–(h))."""

from __future__ import annotations

import hashlib
import json
import random
import shutil
import sqlite3
import time
import uuid
from datetime import UTC, datetime, timedelta

import numpy as np
import pytest
from fastapi.testclient import TestClient
from typer.testing import CliRunner

from omi_notes.api import create_app
from omi_notes.cli import app as cli
from omi_notes.db import COLUMN_SOURCES, SCHEMA
from omi_notes.devtools import live_envelopes, pcm_envelopes, ring_envelopes, synth_speech_like
from omi_notes.envelope import iso_utc, parse_envelope
from omi_notes.migrate import migrate
from omi_notes.pipeline.conversations import Providers
from omi_notes.pipeline.worker import Worker
from omi_notes.providers import ProviderError
from omi_notes.providers.fake import FakeLlm, FakeStt
from omi_notes.vault import Vault

from .conftest import AUTH, DEVICE, FIXTURES, cli_env, make_settings

STARTED = datetime(2026, 9, 26, 19, 0, tzinfo=UTC)
T0 = STARTED.timestamp()
SR = 16000


def silence(seconds: float) -> np.ndarray:
    return np.zeros(int(round(seconds * SR)), np.int16)


def iso(epoch: float) -> str:
    return iso_utc(datetime.fromtimestamp(epoch, UTC))


# -- providers -------------------------------------------------------------------------------------


class ScriptedStt(FakeStt):
    """Fake STT whose short conversations are filler (so they are discarded by the rules)."""

    def transcribe(self, request):
        response = super().transcribe(request)
        if request.duration < 6:
            for utt in response["results"]["utterances"]:
                utt["transcript"] = "Mm-hmm."
        return response


class ScriptedLlm(FakeLlm):
    """Fake LLM that fails for good on three-segment conversations (a transcript-only note)."""

    def summarize(self, request):
        if len(request.segments) == 3:
            raise ProviderError("Anthropic auth error: invalid x-api-key", terminal=True, kind="auth")
        return super().summarize(request)


class Exploding:
    def __getattr__(self, name):
        raise AssertionError(f"a provider was called after the rebuild ({name})")


def scripted(settings) -> Providers:
    providers = Providers(settings)
    providers._stt, providers._llm = ScriptedStt(), ScriptedLlm()
    return providers


def exploding(settings) -> Providers:
    providers = Providers(settings)
    providers._stt = providers._llm = Exploding()  # type: ignore[assignment]
    providers._diarizer = False
    return providers


# -- a backend process -----------------------------------------------------------------------------


class Clock:
    def __init__(self, now: float) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class Backend:
    """One server process on a vault (a fresh one rebuilds or reuses the index)."""

    def __init__(self, settings, clock: Clock, providers) -> None:
        self.settings = settings
        self.app = create_app(settings, start_worker=False)
        self.app.state.ingest.clock = clock
        self.client = TestClient(self.app)
        self.worker = Worker(settings, self.app.state.db, providers=providers(settings))
        self.clock = clock

    def put_chunk(self, capture: str, seq: int, body: bytes) -> int:
        headers = AUTH | {"X-Content-SHA256": hashlib.sha256(body).hexdigest()}
        return self.client.put(f"/v1/captures/{capture}/chunks/{seq}", content=body, headers=headers).status_code

    def put_seal(self, capture: str, body: dict) -> int:
        return self.client.put(f"/v1/captures/{capture}/seal", json=body, headers=AUTH).status_code

    def put_event(self, event_id: str, body: dict) -> int:
        return self.client.put(f"/v1/events/{event_id}", json=body, headers=AUTH).status_code

    def tick(self, now: float) -> None:
        self.clock.now = now
        self.worker.tick(now)


def snapshot(settings) -> dict[str, bytes]:
    root = settings.vault_dir
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in sorted(root.rglob("*"))
            if p.is_file() and p.name != "writer.json"}  # fmt: skip


def diff(a: dict[str, bytes], b: dict[str, bytes]) -> list[str]:
    out = [f"only before: {k}" for k in sorted(set(a) - set(b))] + [f"only after: {k}" for k in sorted(set(b) - set(a))]
    out += [f"differs: {k}" for k in sorted(set(a) & set(b)) if a[k] != b[k]]
    return out


# -- the scenario ------------------------------------------------------------------------------------


def scenario_inputs() -> list[tuple]:
    """Uploads (in a natural order) with the clock value each is received at.

    Live talk with a double tap and a bookmark; a three-block talk whose summary fails; a
    disconnect resolved by an offline-storage sync; late offline audio next to a finalized
    conversation; a discarded replay the day before; an unsealed live capture that closes
    provisionally."""
    steps: list[tuple] = []
    sync0 = str(uuid.uuid5(uuid.NAMESPACE_URL, "sync0"))
    steps.append(("seal", T0, sync0, {"last_chunk_sequence": -1, "reason": "sync_complete", "ended_at": iso(T0),
                                      "device_id": DEVICE, "source": "device_ring",
                                      "ring": {"covers_until": iso(T0), "info_read_seq": 0, "generation": 1}}))  # fmt: skip

    live = str(uuid.uuid5(uuid.NAMESPACE_URL, "live"))
    three = np.concatenate([synth_speech_like(4, seed=5), silence(5), synth_speech_like(4, seed=6), silence(5),
                            synth_speech_like(4, seed=7)])  # fmt: skip
    pcm = np.concatenate([silence(2), synth_speech_like(20, seed=1), silence(150), three, silence(5)])
    envs = live_envelopes(pcm, capture_id=live, device_id=DEVICE, started_at=STARTED, offline_storage=True,
                          chunk_seconds=60, drop_rate=0.01)  # fmt: skip
    for seq, body in enumerate(envs):
        end = parse_envelope(body).header.chunk_end_offset_us
        steps.append(("chunk", T0 + end / 1e6 + 1, live, seq, body))
        beat = {"device_id": DEVICE, "type": "heartbeat", "at": iso(T0 + end / 1e6),
                "data": {"battery": 80, "app_state": "foreground",
                         "coverage": {"capture_id": live, "through_offset_us": end, "through_chunk_sequence": seq}}}  # fmt: skip
        steps.append(("event", T0 + end / 1e6 + 1.5, str(uuid.uuid5(uuid.NAMESPACE_URL, f"beat{seq}")), beat))
    steps.append(("event", T0 + 13, str(uuid.uuid5(uuid.NAMESPACE_URL, "tap")),
                  {"device_id": DEVICE, "type": "button", "at": iso(T0 + 12), "capture_id": live, "offset_us": 12_000_000,
                   "data": {"code": 2}}))  # fmt: skip
    steps.append(("event", T0 + 17, str(uuid.uuid5(uuid.NAMESPACE_URL, "mark")),
                  {"device_id": DEVICE, "type": "button", "at": iso(T0 + 16), "capture_id": live, "offset_us": 16_000_000,
                   "data": {"code": 1}}))  # fmt: skip
    live_end = parse_envelope(envs[-1]).header.chunk_end_offset_us
    steps.append(("seal", T0 + live_end / 1e6 + 2, live,
                  {"last_chunk_sequence": len(envs) - 1, "reason": "ble_disconnected", "ended_at": iso(T0 + live_end / 1e6),
                   "end_offset_us": live_end, "device_id": DEVICE, "source": "live_ble"}))  # fmt: skip

    reconnect = T0 + live_end / 1e6 + 200
    sync1 = str(uuid.uuid5(uuid.NAMESPACE_URL, "sync1"))
    steps.append(("seal", reconnect, sync1, {"last_chunk_sequence": -1, "reason": "sync_complete", "ended_at": iso(reconnect),
                                             "device_id": DEVICE, "source": "device_ring",
                                             "ring": {"covers_until": iso(reconnect), "info_read_seq": 0, "generation": 1}}))  # fmt: skip

    late = str(uuid.uuid5(uuid.NAMESPACE_URL, "late"))
    late_pcm = synth_speech_like(6, seed=8)
    renvs, n = ring_envelopes(late_pcm, capture_id=late, device_id=DEVICE, started_at=STARTED + timedelta(seconds=900),
                              audio_start_epoch=int(T0) + 40, records_per_chunk=120)  # fmt: skip
    for seq, body in enumerate(renvs):
        steps.append(("chunk", T0 + 901 + seq, late, seq, body))
    # An interrupted sync read the same first records earlier (the device re-sends them).
    cut = str(uuid.uuid5(uuid.NAMESPACE_URL, "interrupted"))
    cenvs, _ = ring_envelopes(late_pcm, capture_id=cut, device_id=DEVICE, started_at=STARTED + timedelta(seconds=850),
                              audio_start_epoch=int(T0) + 40, records_per_chunk=120)  # fmt: skip
    steps.append(("chunk", T0 + 851, cut, 0, cenvs[0]))
    steps.append(("seal", T0 + 852, cut, {"last_chunk_sequence": 0, "reason": "sync_interrupted", "ended_at": iso(T0 + 852),
                                          "device_id": DEVICE, "source": "device_ring", "ring": {"generation": 1}}))  # fmt: skip
    steps.append(("seal", T0 + 905, late, {"last_chunk_sequence": len(renvs) - 1, "reason": "sync_complete",
                                           "ended_at": iso(T0 + 905), "device_id": DEVICE, "source": "device_ring",
                                           "ring": {"covers_until": iso(T0 + 900), "info_read_seq": 0, "generation": 1}}))  # fmt: skip

    replay = str(uuid.uuid5(uuid.NAMESPACE_URL, "replay"))
    before = STARTED - timedelta(days=1)
    penvs = pcm_envelopes(np.concatenate([silence(1), synth_speech_like(4, seed=9), silence(2)]), capture_id=replay,
                          device_id=DEVICE, started_at=before, chunk_seconds=20)  # fmt: skip
    for seq, body in enumerate(penvs):
        steps.append(("chunk", T0 + 950 + seq, replay, seq, body))
    pend = parse_envelope(penvs[-1]).header.chunk_end_offset_us
    steps.append(("seal", T0 + 960, replay, {"last_chunk_sequence": len(penvs) - 1, "reason": "replay_complete",
                                             "ended_at": iso(before.timestamp() + pend / 1e6), "end_offset_us": pend,
                                             "device_id": DEVICE, "source": "wav_replay"}))  # fmt: skip

    open_live = str(uuid.uuid5(uuid.NAMESPACE_URL, "open-live"))
    later = STARTED + timedelta(seconds=3000)
    oenvs = live_envelopes(np.concatenate([silence(1), synth_speech_like(10, seed=10), silence(2)]), capture_id=open_live,
                           device_id=DEVICE, started_at=later, offline_storage=True, chunk_seconds=60)  # fmt: skip
    for seq, body in enumerate(oenvs):
        steps.append(("chunk", T0 + 3015 + seq, open_live, seq, body))
    return steps


TICKS = [T0 + 100, T0 + 300, T0 + 500, T0 + 700, T0 + 1000, T0 + 1500, T0 + 3100, T0 + 4000, T0 + 5000]
SETTLE = [T0 + 10000, T0 + 10100, T0 + 10200]


def apply(backend: Backend, step: tuple) -> None:
    kind, at = step[0], step[1]
    backend.clock.now = at
    if kind == "chunk":
        assert backend.put_chunk(step[2], step[3], step[4]) in (200, 201)
    elif kind == "seal":
        assert backend.put_seal(step[2], step[3]) == 200
    else:
        assert backend.put_event(step[2], step[3]) in (200, 201)


def run(backend: Backend, steps: list[tuple], ticks: list[float]) -> None:
    """Uploads interleaved with ticks by time (an upload at t happens before a tick at t' >= t)."""
    pending = sorted(steps, key=lambda s: s[1])
    for t in ticks:
        while pending and pending[0][1] <= t:
            apply(backend, pending.pop(0))
        backend.tick(t)
    for step in pending:
        apply(backend, step)


def settle(backend: Backend) -> None:
    for t in SETTLE:
        backend.tick(t)


def conversations(db) -> list[tuple]:
    return [tuple(r) for r in db.query(
        "SELECT id, status, note_path, start, end, provisional, late_audio, related_id FROM conversations ORDER BY start")]  # fmt: skip


# -- (0) every index column has a declared source ------------------------------------------------------


def test_every_index_column_declares_its_vault_source(tmp_path):
    conn = sqlite3.connect(tmp_path / "schema.sqlite3")
    conn.executescript(SCHEMA)
    tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    missing = []
    for table in tables:
        for column in (r[1] for r in conn.execute(f"PRAGMA table_info({table})")):
            if not COLUMN_SOURCES.get(table, {}).get(column):
                missing.append(f"{table}.{column}")
    assert not missing, f"columns without a declared vault source: {missing}"
    stale = [f"{t}.{c}" for t, cols in COLUMN_SOURCES.items() for c in cols
             if t not in tables or c not in {r[1] for r in conn.execute(f"PRAGMA table_info({t})")}]  # fmt: skip
    assert not stale, f"declared sources for columns that no longer exist: {stale}"


# -- (a) golden: delete the index, rebuild with exploding providers ------------------------------------


def test_a_golden_rebuild_reproduces_the_vault_byte_for_byte(tmp_path):
    settings = make_settings(tmp_path)
    first = Backend(settings, Clock(T0), scripted)
    run(first, scenario_inputs(), TICKS)
    settle(first)
    before_rows = conversations(first.worker.db)
    statuses = sorted(r[1] for r in before_rows)
    assert statuses == ["discarded", "done", "done", "done", "done", "failed"], before_rows
    assert any(r[5] for r in before_rows) and any(r[6] for r in before_rows)  # provisional and late audio
    before = snapshot(settings)

    shutil.rmtree(settings.index_dir)  # the index is gone; only the vault remains
    second = Backend(settings, Clock(SETTLE[0]), exploding)
    assert second.worker.replaying
    settle(second)
    assert not second.worker.replaying
    assert diff(before, snapshot(settings)) == []
    assert conversations(second.worker.db) == before_rows


# -- (b) copy mid-queue ----------------------------------------------------------------------------------


def test_b_copy_mid_queue_ends_like_an_uninterrupted_run(tmp_path):
    steps = scenario_inputs()
    first_half = [s for s in steps if s[1] <= T0 + 950]
    second_half = [s for s in steps if s[1] > T0 + 950]
    ticks_a = [t for t in TICKS if t <= T0 + 700]
    ticks_b = [t for t in TICKS if t > T0 + 700]

    straight = make_settings(tmp_path / "straight")
    a = Backend(straight, Clock(T0), scripted)
    run(a, first_half, ticks_a)
    copy_from = snapshot(straight)
    run(a, second_half, ticks_b)
    settle(a)

    copied = make_settings(tmp_path / "copied")
    shutil.copytree(straight.vault_dir, copied.vault_dir, dirs_exist_ok=True)
    for rel in set(snapshot(copied)) - set(copy_from):
        (copied.vault_dir / rel).unlink()  # the copy is the vault as it was mid-queue
    for rel, data in copy_from.items():
        (copied.vault_dir / rel).write_bytes(data)
    b = Backend(copied, Clock(T0 + 700), scripted)
    run(b, second_half, ticks_b)
    settle(b)
    assert diff(snapshot(straight), snapshot(copied)) == []


# -- (c) crash between the file write and the index commit (finalize, render) -------------------------------


def test_c_crash_after_finalize_or_render_record_before_the_index(tmp_path, monkeypatch):
    settings = make_settings(tmp_path)
    backend = Backend(settings, Clock(T0), scripted)
    steps = [s for s in scenario_inputs() if s[1] < T0 + 900]
    run(backend, steps, [T0 + 100])

    # Crash right after conversation.json is written at finalize, before the index is updated.
    real_close = Worker._close

    def crash_after_record(self, row, fields, known, now):
        from omi_notes.records import record_from_row, write_record

        write_record(self.vault, record_from_row(dict(row) | fields, known))
        raise RuntimeError("power loss")

    monkeypatch.setattr(Worker, "_close", crash_after_record)
    backend.tick(T0 + 300)
    monkeypatch.setattr(Worker, "_close", real_close)
    records = [p for p in (settings.vault_dir / "_omi" / "conversations").rglob("conversation.json")]
    assert records

    restarted = Backend(settings, Clock(T0 + 300), scripted)  # startup sweep applies the records
    for t in (T0 + 500, T0 + 700, T0 + 1000):
        restarted.tick(t)
    rows = conversations(restarted.worker.db)
    assert len({r[0] for r in rows}) == len(rows) and all(r[1] in ("done", "failed", "open") for r in rows), rows

    # Crash after a note and its record are written, before the index learns about it.
    done = [r for r in rows if r[1] == "done"][0]
    restarted.worker.db.execute("UPDATE conversations SET needs_render=1 WHERE id=?", (done[0],))
    real_set = restarted.worker.pipeline._set

    def crash_on_index(conv_id, **fields):
        if "record_sha" in fields:
            raise RuntimeError("power loss")
        return real_set(conv_id, **fields)

    monkeypatch.setattr(restarted.worker.pipeline, "_set", crash_on_index)
    with pytest.raises(RuntimeError, match="power loss"):
        restarted.worker.pipeline.advance(done[0], T0 + 1100)
    monkeypatch.undo()
    again = Backend(settings, Clock(T0 + 1100), scripted)
    again.tick(T0 + 1200)
    after = conversations(again.worker.db)
    assert [r[:3] for r in after if r[0] == done[0]] == [done[:3]]


# -- (d) retention, then rebuild ----------------------------------------------------------------------------


def test_d_rebuild_after_retention_keeps_every_note(tmp_path):
    settings = make_settings(tmp_path)
    first = Backend(settings, Clock(T0), scripted)
    run(first, scenario_inputs(), TICKS)
    settle(first)
    deleted = first.worker.retention(time.time() + 400 * 86400)
    assert deleted > 0
    notes = {k: v for k, v in snapshot(settings).items() if k.endswith(".md")}
    before_rows = conversations(first.worker.db)

    shutil.rmtree(settings.index_dir)
    second = Backend(settings, Clock(SETTLE[0]), exploding)
    settle(second)
    assert conversations(second.worker.db) == before_rows
    after = {k: v for k, v in snapshot(settings).items() if k.endswith(".md")}
    assert diff(notes, after) == []
    gone = second.worker.db.one("SELECT capture_id, chunk_sequence, sha256 FROM chunks WHERE raw_deleted=1 LIMIT 1")
    assert gone is not None
    # a re-upload of an expired chunk is recognized from its tombstone
    raw = {s[2:4]: s[4] for s in scenario_inputs() if s[0] == "chunk"}
    assert second.put_chunk(gone["capture_id"], gone["chunk_sequence"], raw[(gone["capture_id"], gone["chunk_sequence"])]) == 200
    other = next(body for key, body in raw.items() if key != (gone["capture_id"], gone["chunk_sequence"]))
    assert second.put_chunk(gone["capture_id"], gone["chunk_sequence"], other) == 409


# -- (e) seeded randomized arrival/tick interleavings with a rebuild at a random point -----------------------


def interleaving(seed: int) -> list[tuple]:
    """A random but causal arrival order: each capture's chunks in order, the rest shuffled; ticks
    at random points (increasing times)."""
    rng = random.Random(seed)
    steps = scenario_inputs()
    rng.shuffle(steps)
    order: list[tuple] = []
    seen: dict[str, int] = {}
    queue = list(steps)
    while queue:
        for i, step in enumerate(queue):
            if step[0] != "chunk" or seen.get(step[2], -1) == step[3] - 1 or rng.random() < 0.15:
                order.append(queue.pop(i))
                if step[0] == "chunk":
                    seen[step[2]] = max(seen.get(step[2], -1), step[3])
                break
    plan: list[tuple] = []
    t = T0 + 50
    for step in order:
        t += rng.uniform(5, 400)
        plan.append((step[0], t, *step[2:]))
        if rng.random() < 0.35:
            plan.append(("tick", t + 1))
    plan.append(("tick", t + 6000))
    return plan


def play(backend: Backend, plan: list[tuple], crash_at: int | None, settings, providers) -> Backend:
    for i, step in enumerate(plan):
        if i == crash_at:
            shutil.rmtree(settings.index_dir)
            backend = Backend(settings, Clock(backend.clock.now), providers)
        if step[0] == "tick":
            backend.tick(step[1])
        else:
            apply(backend, step)
    last = plan[-1][1]
    for dt in (10, 100, 200):
        backend.tick(last + dt)
    return backend


@pytest.mark.parametrize("seed", [1, 2, 3, 4, 5, 6])
def test_e_random_interleavings_with_a_rebuild_match_the_uninterrupted_run(tmp_path, seed):
    plan = interleaving(seed)
    crash_at = random.Random(seed * 7919).randrange(1, len(plan) - 1)
    straight = make_settings(tmp_path / "straight")
    a = play(Backend(straight, Clock(T0), scripted), plan, None, straight, scripted)
    rebuilt = make_settings(tmp_path / "rebuilt")
    b = play(Backend(rebuilt, Clock(T0), scripted), plan, crash_at, rebuilt, scripted)
    assert conversations(a.worker.db) == conversations(b.worker.db)
    ignore = {"_omi/VAULT.json"}  # two separate vaults (ids, creation times)
    assert [d for d in diff(snapshot(straight), snapshot(rebuilt)) if d.split(": ")[1] not in ignore] == []


# -- validation ---------------------------------------------------------------------------------------------


def test_missing_referenced_result_opens_the_vault_read_only(tmp_path):
    settings = make_settings(tmp_path)
    first = Backend(settings, Clock(T0), scripted)
    run(first, scenario_inputs(), TICKS)
    settle(first)
    row = first.worker.db.one("SELECT * FROM conversations WHERE llm_ref IS NOT NULL LIMIT 1")
    vault = Vault.open(settings)
    (vault.conversation_dir(row["id"]) / row["llm_ref"]).unlink()  # "still syncing"
    shutil.rmtree(settings.index_dir)
    second = Backend(settings, Clock(SETTLE[0]), exploding)
    reason = second.client.get("/v1/status", headers=AUTH).json()["read_only"]
    assert reason and "incomplete vault" in reason and row["llm_ref"] in reason
    capture = str(uuid.uuid4())
    body = live_envelopes(synth_speech_like(1), capture_id=capture, device_id=DEVICE, started_at=STARTED)[0]
    assert second.put_chunk(capture, 0, body) == 503
    second.tick(SETTLE[1])
    assert "Not writing to this vault" in (settings.vault_dir / "_status.md").read_text()


# -- notes edited outside My Notes -------------------------------------------------------------------------


def test_edited_note_is_postponed_then_overwritten_or_frozen(tmp_path):
    settings = make_settings(tmp_path)
    backend = Backend(settings, Clock(T0), scripted)
    run(backend, scenario_inputs(), TICKS)
    settle(backend)
    rows = [r for r in backend.worker.db.query("SELECT * FROM conversations WHERE status='done' ORDER BY start")]
    first, second = rows[0], rows[1]
    for row in (first, second):
        path = settings.vault_dir / row["note_path"]
        path.write_text(path.read_text().replace("## Transcript", "## Transcript\n\nI fixed a word here."))
        backend.worker.db.execute("UPDATE conversations SET needs_render=1 WHERE id=?", (row["id"],))
    backend.tick(T0 + 20000)
    for row in (first, second):
        assert "I fixed a word here." in (settings.vault_dir / row["note_path"]).read_text()
    status = (settings.vault_dir / "_status.md").read_text()
    assert "Notes edited outside My Notes" in status and "omi-notes note overwrite" in status

    env = cli_env(settings)
    result = CliRunner().invoke(cli, ["note", "overwrite", first["id"]], env=env)
    assert result.exit_code == 0, result.output
    assert "I fixed a word here." not in (settings.vault_dir / first["note_path"]).read_text()
    (displaced,) = (settings.vault_dir / "_omi" / "displaced").glob("*.md")
    assert "I fixed a word here." in displaced.read_text()

    result = CliRunner().invoke(cli, ["note", "freeze", second["id"]], env=env)
    assert result.exit_code == 0, result.output
    backend.worker.db.execute("UPDATE conversations SET needs_render=1 WHERE id=?", (second["id"],))
    backend.tick(T0 + 30000)
    assert "I fixed a word here." in (settings.vault_dir / second["note_path"]).read_text()
    record = json.loads((Vault.open(settings).conversation_dir(second["id"]) / "conversation.json").read_text())
    assert record["render"]["frozen"] is True
    assert "Notes edited outside My Notes" not in (settings.vault_dir / "_status.md").read_text()


def test_my_notes_edits_are_not_edits_outside_my_notes(tmp_path):
    settings = make_settings(tmp_path)
    backend = Backend(settings, Clock(T0), scripted)
    run(backend, scenario_inputs(), TICKS)
    settle(backend)
    row = backend.worker.db.one("SELECT * FROM conversations WHERE status='done' ORDER BY start LIMIT 1")
    path = settings.vault_dir / row["note_path"]
    path.write_text(path.read_text().replace("<!-- my-notes:start -->\n", "<!-- my-notes:start -->\nCall Priya.\n"))
    backend.worker.db.execute("UPDATE conversations SET needs_render=1 WHERE id=?", (row["id"],))
    backend.tick(T0 + 20000)
    fresh = backend.worker.db.one("SELECT edited, needs_render FROM conversations WHERE id=?", (row["id"],))
    assert (fresh["edited"], fresh["needs_render"]) == (0, 0)
    assert "Call Priya." in path.read_text()


def test_conflict_copies_are_reported_not_deleted(tmp_path):
    settings = make_settings(tmp_path)
    backend = Backend(settings, Clock(T0), scripted)
    run(backend, scenario_inputs(), TICKS)
    settle(backend)
    row = backend.worker.db.one("SELECT * FROM conversations WHERE status='done' ORDER BY start LIMIT 1")
    note = settings.vault_dir / row["note_path"]
    copy = note.with_name(note.stem + " (conflicted copy).md")
    copy.write_bytes(note.read_bytes())
    backend.worker.pipeline._conflicts = None
    backend.worker.pipeline.render_status("test", T0 + 20000, force=True)
    assert "Conflicting copies" in (settings.vault_dir / "_status.md").read_text() and copy.exists()


def test_sync_conflict_copy_under_omi_stops_writes(tmp_path):
    settings = make_settings(tmp_path)
    backend = Backend(settings, Clock(T0), scripted)
    run(backend, scenario_inputs()[:5], [T0 + 100])
    (record,) = list((settings.vault_dir / "_omi" / "raw").rglob("seal.json"))[:1]
    shutil.copy(record, record.with_name("seal 2.json"))
    assert backend.worker.check_divergence()
    reason = backend.client.get("/v1/status", headers=AUTH).json()["read_only"]
    assert "divergence" in reason and "seal 2.json" in reason


# -- (h) legacy install → migrate-vault → rebuild ------------------------------------------------------------


def test_h_migrating_a_legacy_install_keeps_every_note_and_conversation(tmp_path):
    legacy = tmp_path / "legacy"
    shutil.copytree(FIXTURES / "legacy_install", legacy)
    notes_before = {p.relative_to(legacy / "notes").as_posix(): p.read_bytes()
                    for p in (legacy / "notes").rglob("*.md") if not p.name.startswith("_status")
                    and "_in-progress" not in p.parts}  # fmt: skip
    old = sqlite3.connect(legacy / "data" / "omi-notes.sqlite3")
    old_rows = sorted(tuple(r) for r in old.execute(
        "SELECT id, status, note_path, start, end FROM conversations WHERE status <> 'open'"))  # fmt: skip
    old.close()

    settings = make_settings(tmp_path, vault_dir=legacy / "notes")
    env = cli_env(settings) | {"VAULT_DIR": str(legacy / "notes")}
    result = CliRunner().invoke(cli, ["migrate-vault", "--notes-dir", str(legacy / "notes"), "--data-dir",
                                      str(legacy / "data"), "--vault-dir", str(legacy / "notes")], env=env)  # fmt: skip
    assert result.exit_code == 0, result.output
    assert "checked 6 notes" in result.output
    assert (legacy / "data" / "omi-notes.sqlite3").exists()  # the legacy install is untouched

    backend = Backend(settings, Clock(T0 + 20000), exploding)  # first start: rebuild from the vault
    for t in (T0 + 20000, T0 + 20100, T0 + 20200):
        backend.tick(t)
    rows = sorted(tuple(r) for r in backend.worker.db.query(
        "SELECT id, status, note_path, start, end FROM conversations WHERE status <> 'open'"))  # fmt: skip
    assert rows == old_rows
    notes_after = {p.relative_to(legacy / "notes").as_posix(): p.read_bytes()
                   for p in (legacy / "notes").rglob("*.md") if not p.name.startswith("_status")
                   and "_in-progress" not in p.parts}  # fmt: skip
    assert diff(notes_before, notes_after) == []
    assert "Call Priya back." in next(v.decode() for k, v in notes_after.items() if "1400 Fake" in k and k.endswith("Segments.md"))


def test_h_migration_mismatch_leaves_the_vault_unfinished(tmp_path):
    legacy = tmp_path / "legacy"
    shutil.copytree(FIXTURES / "legacy_install", legacy)
    note = next((legacy / "notes" / "Conversations").rglob("*1300*.md"))
    note.write_text(note.read_text().replace("## Transcript", "## Transcript (edited by an old renderer)"))
    settings = make_settings(tmp_path, vault_dir=legacy / "notes")
    report = migrate(settings, legacy / "notes", legacy / "data", legacy / "notes")
    assert not report.ok and "renders differently" in report.mismatches[0]
    assert not (legacy / "notes" / "_omi" / "VAULT.json").exists()
