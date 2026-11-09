"""Regressions for Astra's re-review (round 2) of the Voices hub fixes."""

from __future__ import annotations

import json

import pytest

from omi_notes.vault import Vault

from .conftest import AUTH
from .helpers import T0
from .test_speaker_learning import ALAN, PRIYA, dialogue, env, name_label, new_person, talk, vec  # noqa: F401
from .test_speaker_review_fixes import consented_priya, import_range, journal_files, monologue_row
from .test_speaker_samples import MODEL, me_with_samples, review, decide, sample_file  # noqa: F401


def crash_on(monkeypatch, store, name: str, action: str | None = None):
    real = getattr(store, name)

    def failing(*args, **kwargs):
        if action is None or kwargs.get("action") == action:
            raise OSError("power cut")
        return real(*args, **kwargs)

    monkeypatch.setattr(store, name, failing)
    return lambda: monkeypatch.setattr(store, name, real)


# -- 2: one sample's successful write never hides another's failed index write ------------------------------------


def test_a_later_successful_write_keeps_another_samples_failed_index_write_pending(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    store = worker.pipeline.speakers
    restore = crash_on(monkeypatch, store, "_index_sample")
    with pytest.raises(OSError), store.lock:
        store.set_sample_state(me, ids[0], "removed", action="remove", by="user", request_id="r1")
    restore()
    with store.lock:  # another sample changes fine (its index row written)
        store.set_sample_state(me, ids[1], "removed", action="remove", by="user", request_id="r2")
    assert ids[0] not in {s.id for s in store.samples(*MODEL)}, "the first change is still reconciled"
