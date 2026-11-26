"""Carbon IT2 (2026-11-25) on the people snapshot, as invariants. C2-01: a snapshot published at generation N reflects
every mutation completed before N was taken. C2-02: one bad file never wedges People (skipped, counted and surfaced;
the samples index never emptied). C2-03: a live chunk differing only by case from its folder rebuilds. C2-04: a
malformed people.json is ignored. C2-05: put_person computes the people list once. Built from Carbon's reproducers
(which pinned the defects)."""

from __future__ import annotations

import hashlib
import json
import threading
import uuid
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.envelope import build_envelope, parse_envelope
from omi_notes.ingest import index_chunk
from omi_notes.rebuild import open_index
from omi_notes.settings import Settings
from omi_notes.vault import Vault

from .test_disk_full import _envs

AUTH = {"Authorization": "Bearer tok"}


class _FakeEmb:
    model = "wespeaker"
    model_sha = "deadbeef12345678"


def _settings(root: Path) -> Settings:
    return Settings(vault_dir=root / "vault", index_dir=root / "index", lock_dir=root / "locks", omi_notes_token="tok",
                    stt_provider="fake", llm_provider="fake")  # fmt: skip


def test_c2_01_a_mutation_reads_its_own_write_despite_an_earlier_build(tmp_path, monkeypatch):
    """Carbon's interleave: an earlier worker build read the old note, and its index write is held until the PUT's own
    build is running. The GET after the PUT's 200 must show the PUT's name. (The held worker waits at most 1 s: with the
    fix the PUT can't start until the worker's build is done, which is the point.)"""
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    store = svc.store
    pid = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid}", json={"name": "Dana"}, headers=AUTH).status_code == 201

    scanned, allow, wrote = threading.Event(), threading.Event(), threading.Event()
    real_query, real_people, real_scan = store.db.query, store.people, store.scan_people
    worker_tid: list[int] = []

    def hooked_query(sql, params=()):
        if threading.get_ident() in worker_tid and sql == "SELECT * FROM people" and not scanned.is_set():
            scanned.set()
            allow.wait(1)
        return real_query(sql, params)

    intercept = [False]

    def hooked_people():
        if intercept[0] and threading.get_ident() not in worker_tid:
            intercept[0] = False
            allow.set()
            wrote.wait(1)
        return real_people()

    def tracked_scan():
        out = real_scan()
        if threading.get_ident() in worker_tid and scanned.is_set():
            wrote.set()
        return out

    monkeypatch.setattr(store.db, "query", hooked_query)
    monkeypatch.setattr(store, "people", hooked_people)
    monkeypatch.setattr(store, "scan_people", tracked_scan)

    def worker():
        worker_tid.append(threading.get_ident())
        svc.refresh_people()

    wt = threading.Thread(target=worker)
    wt.start()
    assert scanned.wait(5)
    real_refresh = svc.refresh_people

    def mark(*a, **k):
        intercept[0] = True
        return real_refresh(*a, **k)

    monkeypatch.setattr(svc, "refresh_people", mark)
    put = client.put(f"/v1/people/{pid}", json={"name": "Dana Lee"}, headers=AUTH)
    assert put.status_code == 200 and put.json()["name"] == "Dana Lee"
    wt.join(5)
    got = client.get("/v1/people", headers=AUTH).json()
    assert [p["name"] for p in got["people"]] == ["Dana Lee"] and got["ready"] is True, got


def _alan_with_a_sample(tmp_path):
    client = TestClient(create_app(_settings(tmp_path), start_worker=False), raise_server_exceptions=False)
    svc = client.app.state.speakers
    store = svc.store
    svc.pipeline.providers._embedder = _FakeEmb()
    pid = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid}", json={"name": "Alan", "me": True}, headers=AUTH).status_code == 201
    vec = np.ones(256, dtype=np.float32) / np.sqrt(256)
    store.add_sample(pid, vec, model="wespeaker", model_sha="deadbeef12345678", source="user", seconds=6.0,
                     day="2026-11-20", session="c1")  # fmt: skip
    svc.warm(now=1000.0)
    assert client.get("/v1/people", headers=AUTH).json()["people"][0]["samples"] == 1
    return client, svc, store, pid


def _issue(client, code):
    return next((i for i in client.get("/v1/issues", headers=AUTH).json()["issues"] if i["code"] == code), None)


def test_c2_02_one_corrupt_sample_file_is_skipped_counted_and_surfaced(tmp_path):
    client, svc, store, pid = _alan_with_a_sample(tmp_path)
    bad = store.person_dir(pid) / "samples" / "00000000-0000-4000-8000-000000000000.json"
    bad.write_text("{corrupt sample json")
    assert client.put("/v1/speakers/settings", json={"auto_assign": False}, headers=AUTH).status_code == 200
    pid2 = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid2}", json={"name": "Priya"}, headers=AUTH).status_code == 201
    svc.warm(now=1010.0)  # the worker: no exception escapes, and People is rebuilt
    ans = client.get("/v1/people", headers=AUTH).json()
    assert ans["ready"] is True and "stale" not in ans
    assert sorted(p["name"] for p in ans["people"]) == ["Alan", "Priya"]
    assert next(p for p in ans["people"] if p["name"] == "Alan")["samples"] == 1
    assert store.db.one("SELECT COUNT(*) AS n FROM samples")["n"] == 1, "the good sample's index row stays"
    issue = _issue(client, "speaker_files_unreadable")
    assert issue and issue["count"] == 1 and "00000000-0000-4000-8000-000000000000" in issue["server_step"]
    bad.unlink()  # fixed on the server: the issue goes at the next build
    svc.warm(now=1400.0)
    assert _issue(client, "speaker_files_unreadable") is None


def test_c2_02_a_reload_never_empties_the_samples_index_when_it_fails(tmp_path, monkeypatch):
    client, svc, store, pid = _alan_with_a_sample(tmp_path)

    def broken(data):
        raise OSError("synthetic: index write failed")

    monkeypatch.setattr(store, "_index_sample", broken)
    with pytest.raises(OSError):
        store.load_samples()
    assert store.db.one("SELECT COUNT(*) AS n FROM samples")["n"] == 1, "the DELETE and the inserts are one transaction"


@pytest.mark.parametrize("which", ["consent", "calibration"])
def test_c2_02_a_corrupt_consent_or_calibration_file_doesnt_stop_the_build(tmp_path, which):
    client, svc, store, pid = _alan_with_a_sample(tmp_path)
    path = store.person_dir(pid) / "consent.json" if which == "consent" else svc.vault.speakers / "calibration.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{torn")
    pid2 = str(uuid.uuid4())
    assert client.put(f"/v1/people/{pid2}", json={"name": "Priya"}, headers=AUTH).status_code == 201
    svc.warm(now=2000.0)  # the worker's build (a PUT person doesn't rebuild in the request)
    ans = client.get("/v1/people", headers=AUTH).json()
    assert ans["ready"] is True and sorted(p["name"] for p in ans["people"]) == ["Alan", "Priya"]
    assert _issue(client, "speaker_files_unreadable")["count"] == 1


def test_c2_02_a_suggestion_whose_transcript_cant_be_read_is_skipped(tmp_path, monkeypatch):
    client, svc, store, pid = _alan_with_a_sample(tmp_path)

    class Rep:
        conversation_id, label, day = "missing-conversation", "S1", "2026-11-20"

    class Sug:
        id, kind, person_id, seconds, conversations, days, representative, members = "s1", "who_is_this", None, 9.0, 1, 1, Rep(), []

    monkeypatch.setattr(svc, "_suggestions", lambda now: ([Sug()], {}))

    def unreadable(conv_id):
        raise ValueError("synthetic: torn transcript.json")

    monkeypatch.setattr(svc, "_transcript", unreadable)
    assert svc.refresh_people() is True
    sug = client.get("/v1/speakers/suggestions", headers=AUTH).json()
    assert sug["suggestions"] == [] and sug["ready"] is True
    assert _issue(client, "speaker_files_unreadable")["count"] == 1


def test_c2_02_warm_still_builds_people_when_the_review_queue_fails(tmp_path, monkeypatch):
    client, svc, store, pid = _alan_with_a_sample(tmp_path)
    monkeypatch.setattr(svc.review, "entries", lambda *a, **k: (_ for _ in ()).throw(ValueError("synthetic")))
    (svc.vault.root / "People" / "Zed.md").write_text(f"---\nomi_person_id: {uuid.uuid4()}\n---\n")
    svc.warm(now=5000.0)  # logged, not raised; People is still rebuilt
    assert "Zed" in [p["name"] for p in client.get("/v1/people", headers=AUTH).json()["people"]]


def test_c2_02_a_failed_rebuild_after_put_person_answers_its_change_marked_stale(tmp_path, monkeypatch):
    client, svc, store, pid = _alan_with_a_sample(tmp_path)

    def broken(*a, **k):
        raise OSError("synthetic: build failed")

    monkeypatch.setattr(svc, "_compute_people", broken)
    pid2 = str(uuid.uuid4())
    r = client.put(f"/v1/people/{pid2}", json={"name": "Priya"}, headers=AUTH)
    # 2026-11-26 R5: no build runs in the request, so a broken build can't fail it; the change is served at once
    assert r.status_code == 201 and r.json()["name"] == "Priya"
    assert "Priya" in [p["name"] for p in client.get("/v1/people", headers=AUTH).json()["people"]]


def test_c2_02_suggestions_carry_ready_and_stale(tmp_path):
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    cold = client.get("/v1/speakers/suggestions", headers=AUTH).json()
    assert cold["suggestions"] == [] and cold["ready"] is False
    client.app.state.speakers.warm()
    warm = client.get("/v1/speakers/suggestions", headers=AUTH).json()
    assert warm["ready"] is True and "stale" not in warm and "generation" in warm


def test_c2_03_a_live_chunk_differing_only_by_case_from_its_folder_rebuilds(tmp_path):
    """Carbon's APFS reproducer for live .omnc chunks, asserting the fixed outcome (977ac3f's case-folded folder rule)."""
    probe = tmp_path / "apfs_probe"
    probe.mkdir()
    if not (tmp_path / "APFS_PROBE").exists():
        pytest.skip("filesystem is case-sensitive")
    s = _settings(tmp_path)
    v = Vault.open(s)
    db = open_index(s, v)
    upper = "5EED0000-0000-4000-8000-00000000C0DE"
    lower = upper.lower()
    cap1, cap2 = str(uuid.uuid4()), str(uuid.uuid4())
    e1, e2 = parse_envelope(_envs(cap1)[0]), parse_envelope(_envs(cap2)[0])
    raw1 = build_envelope(dict(e1.header.model_dump(mode="json"), device_id=upper), e1.payload)
    raw2 = build_envelope(dict(e2.header.model_dump(mode="json"), device_id=lower), e2.payload)
    d1, d2 = hashlib.sha256(raw1).hexdigest(), hashlib.sha256(raw2).hexdigest()
    v.publish_bytes(v.chunk_path(upper, cap1, 0), raw1)
    v.append_confirmed(v.receipts_path(upper, cap1), {"seq": 0, "sha256": d1, "received_at": 100.0})
    v.publish_bytes(v.chunk_path(lower, cap2, 0), raw2)
    v.append_confirmed(v.receipts_path(lower, cap2), {"seq": 0, "sha256": d2, "received_at": 101.0})
    with db.tx() as conn:
        index_chunk(conn, parse_envelope(raw1).header, digest=d1, size=len(raw1),
                    path=v.relpath(v.chunk_path(upper, cap1, 0)), received_at=100.0)  # fmt: skip
        index_chunk(conn, parse_envelope(raw2).header, digest=d2, size=len(raw2),
                    path=v.relpath(v.chunk_path(lower, cap2, 0)), received_at=101.0)  # fmt: skip
    db.close()
    again = open_index(s, v, force_rebuild=True)
    assert again.one("SELECT device_id FROM chunks WHERE capture_id=?", (cap2,))["device_id"] == lower
    again.close()


def test_c2_04_a_people_json_whose_people_isnt_a_list_is_ignored(tmp_path):
    s = _settings(tmp_path)
    c0 = TestClient(create_app(s, start_worker=False))
    cache = c0.app.state.speakers._people_cache
    c0.app.state.db.close()
    cache.write_text('{"people": "abc", "built_at": 1.0}')
    got = TestClient(create_app(s, start_worker=False)).get("/v1/people", headers=AUTH).json()
    assert got["people"] == [] and got["ready"] is False


def test_c2_05_put_person_computes_the_people_list_once(tmp_path, monkeypatch):
    client = TestClient(create_app(_settings(tmp_path), start_worker=False))
    svc = client.app.state.speakers
    calls = []
    real = svc._compute_people
    monkeypatch.setattr(svc, "_compute_people", lambda *a: calls.append(1) or real(*a))
    assert client.put(f"/v1/people/{uuid.uuid4()}", json={"name": "Una"}, headers=AUTH).status_code == 201
    assert len(calls) == 0, "2026-11-26 R5: a PUT person computes nothing population-wide; the worker builds"
