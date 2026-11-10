"""A deferred short session's provisional class (docs/architecture.md, "Deferred short sessions"): honest without
the wearer's voice model (未确定, never a guess), re-derived in the background when the Voices calibration
generation or the wearer's activation changes. Fakes only."""

from __future__ import annotations

import json

import numpy as np

from omi_notes import deferral
from omi_notes.vault import Vault

from .conftest import AUTH
from .helpers import STARTED, T0, convs, replay, silence
from .test_deferred import busy, fakes, record, short
from .test_speaker_learning import ALAN, PRIYA, FakeEmbedder, voice


def wearer_of(embedder: FakeEmbedder, key: str = "k1"):
    """An active wearer model for ALAN's synthetic voice (what `provisional_wearer` returns when it can identify him)."""
    centroid = np.asarray(embedder.embed(voice(3, ALAN, 1)), dtype=np.float64)
    return (key, centroid / np.linalg.norm(centroid), np.zeros_like(centroid))


def decodes(worker, monkeypatch) -> list[str]:
    calls: list[str] = []
    real = worker.pipeline.conversation_audio
    monkeypatch.setattr(worker.pipeline, "conversation_audio", lambda row, *a, **k: calls.append(row["id"]) or real(row, *a, **k))
    return calls


def provisional(worker, conv_id: str) -> dict:
    return record(worker, conv_id)["deferral"]["provisional"]


def test_without_an_identifiable_wearer_it_is_undetermined_and_nothing_is_decoded(client, worker, monkeypatch):
    fakes(worker)
    busy(worker, monkeypatch)
    worker.providers._embedder = FakeEmbedder()
    calls = decodes(worker, monkeypatch)
    short(client)
    worker.tick(T0 + 400)
    worker.tick(T0 + 460)
    (row,) = convs(worker)
    assert worker.pipeline.provisional_wearer() is None, "no wearer: Alan's model isn't active"
    assert provisional(worker, row["id"])["class"] == "undetermined" and row["kind"] == "undetermined"
    assert calls == [], "nothing to compare against: no audio is decoded"


def test_once_the_wearer_is_identifiable_the_class_is_rederived_in_the_background_and_only_once(client, worker, monkeypatch):
    fakes(worker)
    busy(worker, monkeypatch)
    worker.providers._embedder = embedder = FakeEmbedder()
    short(client)  # Alan alone
    replay(client, np.concatenate([silence(1), voice(8, ALAN, 2), silence(0.3), voice(8, PRIYA, 3), silence(3)]),
           start=STARTED.replace(hour=21))  # fmt: skip
    worker.tick(T0 + 3 * 3600)
    alone, talk = sorted(convs(worker), key=lambda r: r["start"])
    assert deferral.waiting(alone) and deferral.waiting(talk)
    wearer = wearer_of(embedder)
    monkeypatch.setattr(worker.pipeline, "provisional_wearer", lambda: wearer)
    calls = decodes(worker, monkeypatch)
    worker.tick(T0 + 3 * 3600 + 60)
    assert provisional(worker, alone["id"]) | {"wearer_s": None} == {
        "class": "monologue", "confidence": "low", "rule_id": deferral.RULE_WINDOWS, "model": "k1", "wearer_s": None}
    assert provisional(worker, talk["id"])["class"] == "dialogue"
    rows = {r["id"]: r for r in convs(worker)}
    assert rows[alone["id"]]["kind"] == "monologue" and rows[talk["id"]]["kind"] == "dialogue", "listed under its kind"
    assert rows[alone["id"]]["status"] == "closed", "still deferred: nothing was transcribed"
    listed = client.get("/v1/conversations/recent?class=monologue", headers=AUTH).json()["conversations"]
    assert [c["id"] for c in listed] == [alone["id"]] and listed[0]["recording_class"]["class"] == "monologue"
    decoded = len(calls)
    assert decoded == 2
    worker.tick(T0 + 3 * 3600 + 120)
    assert len(calls) == decoded, "the same generation is never derived again"
    # the model goes inactive again (or can't identify him): honest again, without decoding anything
    monkeypatch.setattr(worker.pipeline, "provisional_wearer", lambda: None)
    worker.tick(T0 + 3 * 3600 + 180)
    assert provisional(worker, alone["id"])["class"] == "undetermined" and provisional(worker, alone["id"])["model"] is None
    assert len(calls) == decoded


def test_a_quiet_wearer_is_never_called_passive(client, worker, monkeypatch):
    fakes(worker)
    busy(worker, monkeypatch)
    worker.providers._embedder = embedder = FakeEmbedder()
    replay(client, np.concatenate([silence(1), voice(10, PRIYA, 4), silence(3)]))  # someone else only
    worker.tick(T0 + 400)
    monkeypatch.setattr(worker.pipeline, "provisional_wearer", lambda: wearer_of(embedder))
    worker.tick(T0 + 460)
    (row,) = convs(worker)
    assert provisional(worker, row["id"])["class"] == "undetermined", "a voice can confirm the wearer, never his absence"


def test_one_unreadable_session_never_stalls_the_others(client, worker, monkeypatch):
    fakes(worker)
    busy(worker, monkeypatch)
    worker.providers._embedder = embedder = FakeEmbedder()
    short(client)
    short(client, at=STARTED.replace(hour=21))
    worker.tick(T0 + 3 * 3600)
    first, second = sorted(convs(worker), key=lambda r: r["start"], reverse=True)
    monkeypatch.setattr(worker.pipeline, "provisional_wearer", lambda: wearer_of(embedder))
    real = worker.pipeline.conversation_audio

    def audio(row, *a, **k):
        if row["id"] == first["id"]:
            raise OSError("chunk unreadable")
        return real(row, *a, **k)

    monkeypatch.setattr(worker.pipeline, "conversation_audio", audio)
    worker.tick(T0 + 3 * 3600 + 60)
    assert provisional(worker, second["id"])["class"] == "monologue"
    assert provisional(worker, first["id"])["class"] == "undetermined"


def test_the_wearer_follows_the_voices_calibration_generation(client, worker, settings, monkeypatch):
    """`provisional_wearer` rebuilds the wearer's model only when the published calibration's fingerprint (or the
    wearer, or the voice model) changes: a cheap check on every tick."""
    pipeline = worker.pipeline
    worker.providers._embedder = FakeEmbedder()
    monkeypatch.setattr(pipeline.speakers, "me", lambda: {"id": "p-me", "name": "Alan"})
    built = []
    monkeypatch.setattr(pipeline.speakers, "models", lambda *a: built.append(1) or {})
    path = settings.vault_dir / "_omi" / "speakers" / "calibration.json"
    Vault.write_json(path, {"fingerprint": "a"})
    assert pipeline.provisional_wearer() is None and pipeline.provisional_wearer() is None
    assert len(built) == 1
    Vault.write_json(path, {"fingerprint": "b"})  # samples or consent changed: a new generation
    pipeline.provisional_wearer()
    assert len(built) == 2
    assert json.loads(path.read_text())["fingerprint"] == "b"
