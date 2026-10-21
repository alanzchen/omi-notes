"""The vault as the only permanent state: layout, file-first ingest, orphans, lease, index identity."""

from __future__ import annotations

import json
import socket
import sqlite3
import threading
import time
import uuid

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes import ingest as ingest_mod
from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.devtools import live_envelopes, synth_speech_like
from omi_notes.pipeline.worker import Worker
from omi_notes.rebuild import index_is_current, open_index
from omi_notes.settings import Settings
from omi_notes.util import uuid7_for
from omi_notes.vault import LeaseError, Vault, VaultError, index_dir

from .conftest import AUTH, DEVICE, make_settings, put_chunk
from .helpers import STARTED, T0, convs, iso, live, live_seal, replay, silence

SPEECH = np.concatenate([silence(2), synth_speech_like(15), silence(3)])


def one_chunk(capture: str | None = None, seconds: float = 2.0) -> tuple[str, bytes]:
    capture = capture or str(uuid.uuid4())
    return capture, live_envelopes(synth_speech_like(seconds), capture_id=capture, device_id=DEVICE, started_at=STARTED)[0]


def seal_body(last: int = 0) -> dict:
    return {"last_chunk_sequence": last, "reason": "user_stopped", "ended_at": iso(T0 + 2), "end_offset_us": 2_000_000,
            "device_id": DEVICE, "source": "live_ble"}  # fmt: skip


def event_body(**extra) -> dict:
    return {"device_id": DEVICE, "type": "button", "at": iso(T0 + 1), "data": {"code": 1}} | extra


# -- layout ----------------------------------------------------------------------------------------


def test_vault_layout_and_index_outside_it(client, settings):
    vault = Vault.open(settings)
    info = json.loads(vault.vault_json.read_text())
    assert info["format"] == 1 and info["timezone"] == "America/Chicago" and uuid.UUID(info["vault_id"])
    directory = index_dir(settings, vault)
    assert directory.parent == settings.index_dir and directory.name.startswith(info["vault_id"] + "-")
    assert (directory / "index.sqlite3").exists() and not (settings.vault_dir / "index.sqlite3").exists()

    capture, body = one_chunk()
    assert put_chunk(client, capture, 0, body).status_code == 201
    assert client.put(f"/v1/captures/{capture}/seal", json=seal_body(), headers=AUTH).status_code == 200
    event_id = str(uuid.uuid4())
    assert client.put(f"/v1/events/{event_id}", json=event_body(), headers=AUTH).status_code == 201

    cap_dir = settings.vault_dir / "_omi" / "raw" / DEVICE / capture
    assert (cap_dir / "0.omnc").read_bytes() == body
    (receipt,) = Vault.read_jsonl(cap_dir / "receipts.jsonl")
    assert receipt["seq"] == 0 and len(receipt["sha256"]) == 64 and receipt["received_at"] > 1e9
    seal = json.loads((cap_dir / "seal.json").read_text())
    assert seal["body"] == seal_body() and seal["received_at"] > 1e9
    (events_file,) = (settings.vault_dir / "_omi" / "events").glob("*.jsonl")
    (line,) = Vault.read_jsonl(events_file)
    assert line["event_id"] == event_id and line["body"] == event_body()
    # Nothing the index or locks need lives in the vault.
    names = {p.name for p in settings.vault_dir.rglob("*")}
    assert not {n for n in names if n.endswith((".sqlite3", ".lock", "-wal", "-shm", ".tmp"))}


def test_explicit_render_settings_are_recorded_in_vault_json(tmp_path):
    settings = make_settings(tmp_path)
    Vault.open(settings)
    changed = make_settings(tmp_path, timezone="Europe/Berlin", owner_name="Alan")
    info = Vault.open(changed).info
    assert (info["timezone"], info["owner_name"]) == ("Europe/Berlin", "Alan")


def test_legacy_install_refuses_to_start_and_names_the_migration(tmp_path):
    legacy = Settings(omi_notes_token="t", notes_dir=tmp_path / "notes", data_dir=tmp_path / "data",
                      index_dir=tmp_path / "index", lock_dir=tmp_path / "locks")  # never this Mac's real locks
    with pytest.raises(VaultError, match="migrate-vault --notes-dir .*notes --data-dir .*data"):
        create_app(legacy, start_worker=False)


def test_incomplete_vault_without_vault_json_is_not_an_empty_vault(tmp_path):
    settings = make_settings(tmp_path)
    (settings.vault_dir / "_omi" / "raw").mkdir(parents=True)
    with pytest.raises(VaultError, match="no VAULT.json"):
        create_app(settings, start_worker=False)


def test_newer_vault_format_is_refused(tmp_path):
    settings = make_settings(tmp_path)
    vault = Vault.open(settings)
    Vault.write_json(vault.vault_json, vault.info | {"format": 99})
    with pytest.raises(VaultError, match="newer"):
        Vault.open(settings)


# -- events JSONL ------------------------------------------------------------------------------------


def test_torn_event_line_is_repaired_before_appending(client, settings):
    first = str(uuid.uuid4())
    assert client.put(f"/v1/events/{first}", json=event_body(), headers=AUTH).status_code == 201
    (path,) = (settings.vault_dir / "_omi" / "events").glob("*.jsonl")
    with path.open("ab") as fh:
        fh.write(b'{"event_id": "torn", "rece')  # a crash mid-append
    second = str(uuid.uuid4())
    assert client.put(f"/v1/events/{second}", json=event_body(), headers=AUTH).status_code == 201
    assert [line["event_id"] for line in Vault.read_jsonl(path)] == [first, second]
    assert path.read_bytes().count(b"\n") == 3


# -- orphans (file durable, index commit failed) -----------------------------------------------------


def failing_once(monkeypatch, name: str):
    real = getattr(ingest_mod, name)
    calls = {"n": 0}

    def flaky(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise sqlite3.OperationalError("disk I/O error")
        return real(*args, **kwargs)

    monkeypatch.setattr(ingest_mod, name, flaky)


@pytest.fixture
def lenient(settings) -> TestClient:
    return TestClient(create_app(settings, start_worker=False), raise_server_exceptions=False)


def test_chunk_file_without_index_row_is_adopted_by_an_identical_retry(lenient, settings, monkeypatch):
    capture, body = one_chunk()
    failing_once(monkeypatch, "index_chunk")
    assert put_chunk(lenient, capture, 0, body).status_code == 500
    assert (settings.vault_dir / "_omi" / "raw" / DEVICE / capture / "0.omnc").read_bytes() == body
    r = put_chunk(lenient, capture, 0, body)
    assert r.status_code == 200 and r.json()["duplicate"] is True
    assert lenient.get(f"/v1/captures/{capture}", headers=AUTH).json()["received_ranges"] == [[0, 0]]


def test_chunk_orphan_with_different_bytes_conflicts_and_is_never_overwritten(lenient, settings, monkeypatch):
    capture, body = one_chunk()
    _, other = one_chunk(capture, seconds=3.0)
    failing_once(monkeypatch, "index_chunk")
    assert put_chunk(lenient, capture, 0, body).status_code == 500
    assert put_chunk(lenient, capture, 0, other).status_code == 409
    assert (settings.vault_dir / "_omi" / "raw" / DEVICE / capture / "0.omnc").read_bytes() == body


def test_startup_sweep_indexes_orphans_after_a_crash(lenient, settings, monkeypatch):
    capture, body = one_chunk()
    event_id = str(uuid.uuid4())
    for name in ("index_chunk", "index_seal", "index_event"):
        failing_once(monkeypatch, name)
    assert put_chunk(lenient, capture, 0, body).status_code == 500
    assert lenient.put(f"/v1/captures/{capture}/seal", json=seal_body(), headers=AUTH).status_code == 500
    assert lenient.put(f"/v1/events/{event_id}", json=event_body(), headers=AUTH).status_code == 500
    monkeypatch.undo()

    restarted = TestClient(create_app(settings, start_worker=False))  # a new process: sweep at startup
    status = restarted.get(f"/v1/captures/{capture}", headers=AUTH).json()
    assert status["received_ranges"] == [[0, 0]] and status["sealed"] is True
    assert put_chunk(restarted, capture, 0, body).status_code == 200
    assert restarted.put(f"/v1/captures/{capture}/seal", json=seal_body(), headers=AUTH).status_code == 200
    assert restarted.put(f"/v1/events/{event_id}", json=event_body(), headers=AUTH).status_code == 200
    changed = event_body(data={"code": 2})
    assert restarted.put(f"/v1/events/{event_id}", json=changed, headers=AUTH).status_code == 409


def test_seal_and_event_orphans_are_adopted_in_process(lenient, settings, monkeypatch):
    capture, body = one_chunk()
    assert put_chunk(lenient, capture, 0, body).status_code == 201
    failing_once(monkeypatch, "index_seal")
    assert lenient.put(f"/v1/captures/{capture}/seal", json=seal_body(), headers=AUTH).status_code == 500
    assert lenient.put(f"/v1/captures/{capture}/seal", json=seal_body(1), headers=AUTH).status_code == 409
    assert lenient.put(f"/v1/captures/{capture}/seal", json=seal_body(), headers=AUTH).status_code == 200
    event_id = str(uuid.uuid4())
    failing_once(monkeypatch, "index_event")
    assert lenient.put(f"/v1/events/{event_id}", json=event_body(), headers=AUTH).status_code == 500
    assert lenient.put(f"/v1/events/{event_id}", json=event_body(data={"code": 2}), headers=AUTH).status_code == 409
    assert lenient.put(f"/v1/events/{event_id}", json=event_body(), headers=AUTH).status_code == 200
    (path,) = (settings.vault_dir / "_omi" / "events").glob("*.jsonl")
    assert [line["event_id"] for line in Vault.read_jsonl(path)] == [event_id]


# -- writer lease --------------------------------------------------------------------------------------


def foreign_lease(settings, renewed: float) -> None:
    vault = Vault.open(settings)
    Vault.write_json(vault.writer_json, {"writer_id": "x", "host": "other-host.local", "pid": 1, "started_at": renewed,
                                         "renewed_at": renewed})  # fmt: skip


def test_live_foreign_lease_is_refused_unless_taken_over(tmp_path):
    settings = make_settings(tmp_path)
    foreign_lease(settings, time.time() - 60)
    with pytest.raises(LeaseError, match="other-host.local"):
        create_app(settings, start_worker=False)
    create_app(settings, start_worker=False, take_over=True)
    foreign_lease(settings, time.time() - 16 * 60)  # stale: nobody renewed it for 15 minutes
    create_app(settings, start_worker=False)


def test_worker_takes_the_lease_and_stops_writing_when_fenced(client, settings):
    worker = Worker(settings, Database(settings.db_path))
    stop = threading.Event()
    thread = threading.Thread(target=worker.run_forever, args=(stop,), daemon=True)
    thread.start()
    vault = Vault.open(settings)
    deadline = time.time() + 10
    while (vault.read_lease() or {}).get("host") != socket.gethostname() and time.time() < deadline:
        time.sleep(0.05)
    lease = vault.read_lease()
    assert lease["host"] == socket.gethostname() and lease["pid"] > 0
    # Another machine takes over (after this one "was stopped", but it wasn't): fencing.
    Vault.write_json(vault.writer_json, lease | {"writer_id": "someone-else", "host": "other-host.local"})
    thread.join(20)
    stop.set()
    assert not thread.is_alive()
    assert "took over" in worker.db.meta("fenced")
    capture, body = one_chunk()
    r = put_chunk(client, capture, 0, body)
    assert r.status_code == 503 and r.json()["error"] == "vault_read_only"


# -- index identity ------------------------------------------------------------------------------------


def test_index_mismatch_triggers_an_automatic_rebuild(client, worker, settings):
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (before,) = convs(worker)
    vault = Vault.open(settings)
    path = index_dir(settings, vault) / "index.sqlite3"
    for key, value in (("schema_version", "0"), ("vault_id", "another"), ("vault_path", "/elsewhere"), ("complete", "0")):
        db = Database(path)
        original = db.meta(key)
        db.set_meta(key, value)
        assert index_is_current(path, vault) is not None
        db.execute("DELETE FROM conversations")
        rebuilt = open_index(settings, vault)
        assert rebuilt.meta(key) == original
        (after,) = [dict(r) for r in rebuilt.query("SELECT * FROM conversations")]
        assert (after["id"], after["status"], after["note_path"]) == (before["id"], "done", before["note_path"])


def test_a_copied_vault_gets_its_own_index(client, worker, settings, tmp_path):
    import shutil

    replay(client, SPEECH)
    worker.tick(T0 + 200)
    copy = tmp_path / "copy"
    shutil.copytree(settings.vault_dir, copy)
    moved = make_settings(tmp_path, vault_dir=copy)
    vault = Vault.open(moved)
    assert index_dir(moved, vault) != index_dir(settings, Vault.open(settings))
    db = open_index(moved, vault)
    (row,) = [dict(r) for r in db.query("SELECT * FROM conversations")]
    assert row["status"] == "done" and db.meta("vault_path").endswith("copy")


# -- records -------------------------------------------------------------------------------------------


def test_finalized_conversation_record_holds_the_decision_and_known_through(client, worker, settings):
    capture = replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    vault = Vault.open(settings)
    record = json.loads((vault.conversation_dir(row["id"]) / "conversation.json").read_text())
    assert record["decision"]["start"] == row["start"] and record["decision"]["end"] == row["end"]
    last = worker.db.one("SELECT last_chunk_sequence FROM captures WHERE capture_id=?", (capture,))[0]
    assert record["decision"]["known_through"] == {capture: last + 1}  # the seal flush is chunk last + 1
    assert record["render"]["note_path"] == row["note_path"] and record["render"]["kind"] == "completed"
    assert record["settings"] == {"owner_name": "", "timezone": "America/Chicago"}
    assert record["failure"] is None
    assert vault.conversation_dir(row["id"]).parent.name == "2026-09"
    names = {p.name for p in vault.conversation_dir(row["id"]).iterdir()}
    assert {"conversation.json", "transcript.json"} <= names and any(n.startswith("llm-") for n in names)


def test_conversation_ids_derive_from_device_and_start(client, worker):
    replay(client, SPEECH)
    worker.tick(T0 + 200)
    (row,) = convs(worker)
    assert row["id"] == uuid7_for(row["start"], f"{DEVICE}|{row['start']:.6f}")


def test_known_through_is_what_was_processed_when_the_conversation_closed(client, worker, settings):
    pcm = np.concatenate([silence(1), synth_speech_like(10), silence(150), synth_speech_like(10), silence(2)])
    envs = live_envelopes(pcm, capture_id=(capture := str(uuid.uuid4())), device_id=DEVICE, started_at=STARTED,
                          offline_storage=False)  # fmt: skip
    for seq, body in enumerate(envs):
        assert put_chunk(client, capture, seq, body).status_code == 201
    worker.tick(T0 + 200)  # the first talk closes while the capture is still open
    (first, second) = convs(worker)
    assert first["status"] == "done" and second["status"] == "open"
    known = lambda conv_id: {r["capture_id"]: r["seq"] for r in worker.db.query(  # noqa: E731
        "SELECT * FROM known_through WHERE conversation_id=?", (conv_id,))}  # fmt: skip
    assert known(first["id"]) == {capture: len(envs) - 1}
    live_seal(client, capture, envs)
    worker.tick(T0 + 400)  # the seal's flush is the virtual chunk last + 1
    second = convs(worker)[1]
    assert second["status"] == "done" and known(second["id"]) == {capture: len(envs)}
    assert not worker.db.query("SELECT 1 FROM speech WHERE capture_id=? AND open=1", (capture,))


# -- retention -------------------------------------------------------------------------------------------


def test_retention_writes_evidence_then_tombstones(client, worker, settings):
    capture = live(client, np.concatenate([silence(1), synth_speech_like(20), silence(2)]), offline_storage=False,
                   chunk_seconds=10)  # fmt: skip
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "done"
    chunks = worker.db.query("SELECT * FROM chunks WHERE capture_id=? ORDER BY chunk_sequence", (capture,))
    deleted = worker.retention(time.time() + 31 * 86400)
    assert deleted == len(chunks)
    vault = Vault.open(settings)
    evidence = json.loads(vault.capture_json_path(DEVICE, capture).read_text())
    assert evidence["finalized"] is True and set(evidence["deleted"]) == {str(c["chunk_sequence"]) for c in chunks}
    last = str(chunks[-1]["chunk_sequence"])
    assert evidence["deleted"][last]["carry"] is not None and evidence["deleted"]["0"]["carry"] is None
    assert evidence["coverage"] and all(kind == "live" for _, kind, _, _ in evidence["coverage"])
    for c in chunks:
        tomb = json.loads(vault.tombstone_path(DEVICE, capture, c["chunk_sequence"]).read_text())
        assert tomb["sha256"] == c["sha256"] and tomb["size"] == c["size"] and tomb["header"]["capture_id"] == capture
        assert not (vault.root / c["path"]).exists()
    # Re-uploading an expired chunk: 200 with the same bytes, 409 with different ones.
    envs = live_envelopes(np.concatenate([silence(1), synth_speech_like(20), silence(2)]), capture_id=capture,
                          device_id=DEVICE, started_at=STARTED, offline_storage=False, chunk_seconds=10)  # fmt: skip
    assert put_chunk(client, capture, 0, envs[0]).status_code == 200
    assert put_chunk(client, capture, 0, envs[1]).status_code == 409


# -- doctor ------------------------------------------------------------------------------------------------


def test_doctor_reports_vault_index_and_sync_pitfalls(client, settings, monkeypatch):
    from typer.testing import CliRunner

    from omi_notes.cli import app as cli

    from .conftest import cli_env

    monkeypatch.setattr("omi_notes.cli._tailscale_url", lambda: None)  # never this Mac's tailscale
    (settings.vault_dir / ".obsidian").mkdir()
    foreign_lease(settings, time.time() - 30)
    result = CliRunner().invoke(cli, ["doctor"], env=cli_env(settings))
    out = result.output
    assert "Vault " in out and "Index at" in out
    assert "Sync all other types" in out and "3-4 GB" in out
    assert "other-host.local renewed its writer lease" in out


def test_doctor_names_the_migration_for_a_legacy_install(tmp_path, monkeypatch):
    from typer.testing import CliRunner

    from omi_notes.cli import app as cli

    monkeypatch.setattr("omi_notes.cli._tailscale_url", lambda: None)  # never this Mac's tailscale
    env = {"NOTES_DIR": str(tmp_path / "notes"), "DATA_DIR": str(tmp_path / "data"), "OMI_NOTES_TOKEN": "t",
           "INDEX_DIR": str(tmp_path / "index"), "LOCK_DIR": str(tmp_path / "locks")}
    result = CliRunner().invoke(cli, ["doctor"], env=env)
    assert "omi-notes migrate-vault --notes-dir" in result.output and result.exit_code == 1
