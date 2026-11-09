"""Regressions for Astra's fifth review of the Voices hub fixes."""

from __future__ import annotations

import threading

import pytest

from omi_notes.vault import Vault

from .conftest import AUTH
from .test_speaker_learning import env, new_person  # noqa: F401
from .test_speaker_review_fixes import consented_priya, import_range, journal_files, monologue_row
from .test_speaker_samples import MODEL, me_with_samples, sample_file  # noqa: F401


# -- 1: a lock-free reader never rebuilds the sample index over a concurrent change -------------------------------------


def test_a_sample_index_rebuild_never_overwrites_a_concurrent_remove(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    store = worker.pipeline.speakers
    target = ids[0]
    worker.db.set_meta("samples_dirty:other:0", "1")  # something asks for a rebuild
    real = store._index_sample
    paused, resume = threading.Event(), threading.Event()

    def slow(data):
        if data["sample_id"] == target and not paused.is_set():  # the reader has read the file, not yet indexed it
            paused.set()
            resume.wait(timeout=2)
        return real(data)

    monkeypatch.setattr(store, "_index_sample", slow)
    reader = threading.Thread(target=lambda: client.get(f"/v1/conversations/{rows[1]['id']}/speakers", headers=AUTH))
    reader.start()
    assert paused.wait(timeout=5)

    def remove():
        with store.lock:
            store.set_sample_state(me, target, "removed", action="remove", by="user", request_id="c-1")

    remover = threading.Thread(target=remove)
    remover.start()
    remover.join(timeout=0.5)  # with the rebuild under the lock, the remove waits for it
    resume.set()
    reader.join(timeout=10)
    remover.join(timeout=10)
    monkeypatch.setattr(store, "_index_sample", real)
    assert sample_file(settings, me, target)["state"] == "removed"
    assert worker.db.one("SELECT state FROM samples WHERE id=?", (target,))["state"] == "removed"


# -- 2: cancelling a move removes the files it wrote, even before its copy was published ---------------------------------


def test_forgetting_the_source_cleans_up_import_files_of_a_move_that_never_published_its_copy(env, monkeypatch):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    priya = consented_priya(client)
    row = monologue_row(client, worker)
    mine = import_range(client, me, row["id"], 0, 60).json()
    store = worker.pipeline.speakers
    real = store.add_sample

    def crash(*args, **kwargs):
        if (kwargs.get("extra") or {}).get("moved_from"):
            raise OSError("power cut")
        return real(*args, **kwargs)

    monkeypatch.setattr(store, "add_sample", crash)
    with pytest.raises(OSError):
        client.post(f"/v1/samples/{mine['sample_id']}/move", json={"person_id": priya, "request_id": "mv-1"}, headers=AUTH)
    folder = Vault.open(settings).person_dir(priya)
    assert list((folder / "enrollment").glob("*.omiaudio")), "the copy's audio was written before its sample"
    # recovery keeps failing at the same point, so the forget cancels the move
    assert client.delete(f"/v1/people/{me}", headers=AUTH).status_code == 200
    monkeypatch.setattr(store, "add_sample", real)
    assert journal_files(settings) == []
    assert not list((folder / "samples").glob("*.json")) if (folder / "samples").exists() else True
    assert not list((folder / "enrollment").glob("*")) and not list((folder / "enrollments").glob("*"))


# -- 3: a move never takes over (or later deletes) a historical import of the destination -------------------------------


def test_undoing_a_move_onto_a_historical_import_keeps_that_imports_files(env):
    settings, client, worker = env
    me = new_person(client, "Alan", me=True)
    priya = consented_priya(client)
    row = monologue_row(client, worker)
    hers = import_range(client, priya, row["id"], 0, 60, name="Priya").json()
    assert client.post(f"/v1/samples/{hers['sample_id']}/remove", json={"request_id": "h-1"}, headers=AUTH).status_code == 200
    mine = import_range(client, me, row["id"], 0, 60).json()
    assert client.post(f"/v1/samples/{mine['sample_id']}/move", json={"person_id": priya, "request_id": "h-2"},
                       headers=AUTH).status_code == 200  # fmt: skip
    folder = Vault.open(settings).person_dir(priya)
    audio, result = folder / "enrollment" / f"{hers['import_id']}.omiaudio", folder / "enrollments" / f"{hers['import_id']}.json"
    undo = client.post("/v1/speakers/undo", json={"request_id": "h-2", "undo_request_id": "u-h"}, headers=AUTH).json()
    assert undo["samples"]["undone"] == [mine["sample_id"]], undo
    assert audio.exists() and result.exists(), "the historical import is not this move's to delete"
    assert client.post(f"/v1/samples/{hers['sample_id']}/restore", json={"request_id": "h-3"}, headers=AUTH).status_code == 200
