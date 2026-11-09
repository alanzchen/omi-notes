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
