"""Regressions for Astra's implementation review 1 of the Voices hub (build/deployment/voices-hub-20261109/reviews)."""

from __future__ import annotations

import json

import numpy as np
import pytest

from omi_notes.speakers import match as sm
from omi_notes.vault import Vault

from .conftest import AUTH
from .helpers import T0
from .test_speaker_learning import ALAN, PRIYA, RAVI, dialogue, env, name_label, new_person, sample, talk, vec  # noqa: F401
from .test_speaker_samples import MODEL, me_with_samples, people, review, decide, sample_file  # noqa: F401


# -- 1: a sample change whose index write failed is reconciled -----------------------------------------------


def test_a_state_written_to_the_file_but_not_the_index_is_reconciled(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    store = worker.pipeline.speakers
    real = store._index_sample

    def crash(data):
        raise OSError("index write failed")

    monkeypatch.setattr(store, "_index_sample", crash)
    with pytest.raises(OSError), store.lock:
        store.set_sample_state(me, ids[0], "removed", action="remove", by="user", request_id="r")
    monkeypatch.setattr(store, "_index_sample", real)
    assert sample_file(settings, me, ids[0])["state"] == "removed"
    # the next model build reads the file's truth, not the stale index
    assert ids[0] not in {s.id for s in store.samples(*MODEL)}
    assert people(client)["Alan"]["samples_removed"] == 1


# -- 2: VAULT.json is never lowered; F0 in a voices file needs format 6 -----------------------------------------


def test_render_settings_never_lower_a_format_another_process_raised(tmp_path):
    from .conftest import make_settings

    settings = make_settings(tmp_path)
    stale = Vault.open(settings)  # this process read format 1
    Vault.open(settings).raise_format(6)  # another process raised it
    stale.sync_render_settings(make_settings(tmp_path, timezone="Europe/Paris"))
    info = json.loads((settings.vault_dir / "_omi" / "VAULT.json").read_text())
    assert info["format"] == 6 and info["timezone"] == "Europe/Paris"


def test_a_voices_file_with_f0_raises_the_format_first(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6,))
    voices = next(Vault.open(settings).conversation_dir(rows[0]["id"]).glob("voices-*.json"))
    assert "f0" in json.loads(voices.read_text())["labels"]["S1"]
    # an older backend prunes vector_b64 but not f0: it must refuse this vault
    assert json.loads((settings.vault_dir / "_omi" / "VAULT.json").read_text())["format"] == 6


# -- 12: GA is the consent-eligible label population, counted once ----------------------------------------------


def test_ga_counts_each_voice_once_and_only_what_vector_labels_allows(env):
    settings, client, worker = env
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z", "unknown_voices_enabled": True},
               headers=AUTH)  # fmt: skip
    me, rows, ids = me_with_samples(client, worker, days=(6, 5))
    store = worker.pipeline.speakers
    stored = worker.db.query("SELECT conversation_id, label FROM voices WHERE vector IS NOT NULL")
    assert {r["label"] for r in stored} == {"S1", "S2"}  # Alan named; Priya kept as an unknown voice
    # each named label's voice is also its sample: one voice, counted once
    assert store.rm_space(*MODEL).count == len(stored)
    # an unknown voice whose raw audio is gone is no longer allowed (even before a reconcile prunes it)
    worker.db.execute("UPDATE chunks SET raw_deleted=1")
    named = [r for r in stored if r["label"] == "S1"]
    assert store.rm_space(*MODEL).count == len(named)
    # a person's samples feed GA only with their consent
    priya = new_person(client, "Priya", attest_knows=True)
    with store.lock:
        store.add_sample(priya, vec(PRIYA), model=MODEL[0], model_sha=MODEL[1], source="user", seconds=8.0, day=None, session="x")
    assert store.rm_space(*MODEL).count == len(named) + 1
    client.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH)
    assert store.rm_space(*MODEL).count == len(named)
