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


# -- 3: a journaled label change schedules its note's re-render and a relabel ------------------------------------------


def test_a_journaled_label_change_queues_the_render_and_the_relabel(env):
    from omi_notes.speakers import journal

    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    store = worker.pipeline.speakers
    worker.db.execute("UPDATE conversations SET needs_render=0")
    worker.db.set_meta("relabel_pending", None)
    with store.lock:  # what recovery runs: no API layer around it
        journal.run(store, {"kind": "move", "request_id": "j-1", "by": "user", "from": me, "to": priya,
                            "pairs": [[ids[0], "11111111-1111-4111-8111-111111111111"]],
                            "label": {"conversation_id": rows[0]["id"], "label": "S1"}})  # fmt: skip
    assert store.labels(rows[0]["id"])["S1"]["person_id"] == priya
    assert worker.db.one("SELECT needs_render FROM conversations WHERE id=?", (rows[0]["id"],))["needs_render"] == 1
    assert worker.db.meta("relabel_pending") == "1"
