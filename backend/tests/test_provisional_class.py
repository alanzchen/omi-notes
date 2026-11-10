"""A deferred short session's provisional class (docs/architecture.md, "Deferred short sessions"): honest without
the wearer's voice model (未确定, never a guess), re-derived in the background when the Voices calibration
generation or the wearer's activation changes. Fakes only."""

from __future__ import annotations

import json
import time

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


# -- the work queue (Astra, review of main 9b11b7c) -------------------------------------------------------------------


def deferred_rows(worker, n: int, *, model: str | None, start: float = T0, due: bool = True) -> list[str]:
    """`n` closed deferred sessions inserted into the index, newest last; `model`: their provisional generation."""
    now = time.time()
    block = json.dumps({"policy": "short_speech", "threshold_s": 60.0, "speech_s": 9.0, "decided_at": 0,
                        "provisional": {"class": "undetermined", "confidence": None, "rule_id": "none-v1", "model": model}})
    ids = [f"d{k:06d}" for k in range(n)]
    cols = "id, device_id, start, end, status, deferral, speech_seconds, created_at, updated_at, finalized_at"
    rows = [(cid, "d", start + k * 60, start + k * 60 + 30, "closed", block, 9.0, now, now, now) for k, cid in enumerate(ids)]
    with worker.db.tx() as conn:
        conn.executemany(f"INSERT INTO conversations ({cols}) VALUES ({', '.join('?' * 10)})", rows)
        if not due:
            conn.execute("UPDATE conversations SET prov_due = 0")
    return ids


def test_unreadable_newer_sessions_never_starve_an_older_one(client, worker, monkeypatch):
    ids = deferred_rows(worker, 30, model=None)
    oldest = ids[0]
    embedder = FakeEmbedder()
    monkeypatch.setattr(worker.pipeline, "provisional_wearer", lambda: wearer_of(embedder))
    tried = []

    def audio(row, *a, **k):
        tried.append(row["id"])
        if row["id"] != oldest:
            raise OSError("chunk unreadable")
        return worker.pipeline.__class__.conversation_audio(worker.pipeline, row, *a, **k)

    monkeypatch.setattr(worker.pipeline, "conversation_audio", audio)
    monkeypatch.setattr(worker.pipeline, "_wearer_windows", lambda row, wearer: (audio(row), [(5.0, 0.9)])[1])
    for t in range(12):  # each tick takes a few; the failing ones back off
        worker.pipeline.refresh_provisional(T0 + t)
    assert oldest in tried, "every runnable session is reached while 29 newer ones keep failing"
    row = worker.db.one("SELECT deferral, prov_due FROM conversations WHERE id=?", (oldest,))
    assert json.loads(row["deferral"])["provisional"]["model"] == "k1" and row["prov_due"] == 0
    failing = worker.db.one("SELECT prov_due, prov_retry_at FROM conversations WHERE id=?", (ids[-1],))
    assert failing["prov_due"] == 1 and failing["prov_retry_at"] > T0, "backed off in the index, still to do"


def test_a_settled_queue_costs_nothing_whatever_the_number_of_deferred_sessions(client, worker, settings, monkeypatch):
    from .test_home_cost import Steps

    monkeypatch.setattr(worker.pipeline, "provisional_wearer", lambda: None)
    steps = Steps(monkeypatch)
    costs = []
    for n in (50, 5000):
        worker.db.execute("DELETE FROM conversations")
        deferred_rows(worker, n, model=None, due=False)
        worker.pipeline.refresh_provisional(T0)  # the generation check
        _, cost = steps.measure(lambda: worker.pipeline.refresh_provisional(T0 + 1))
        costs.append(cost)
    assert costs[1] <= costs[0] * 1.3 + 500, costs


# -- the wearer follows the current evidence (Astra, review of main 9b11b7c) ------------------------------------------


class Evidence:
    """The speaker store as the provisional wearer sees it: an evidence digest, the wearer's model and the space."""

    def __init__(self, worker, monkeypatch):
        from types import SimpleNamespace

        from omi_notes.speakers.space import RmSpace

        self.key, self.active, self.samples, self.models_built = "e1", True, ["s1", "s2", "s3"], 0
        embedder = worker.providers._embedder = FakeEmbedder()
        _, centroid, ga = wearer_of(embedder)
        store = worker.pipeline.speakers
        monkeypatch.setattr(store, "me", lambda: {"id": "p-me", "name": "Alan"})
        monkeypatch.setattr(store, "evidence_key", lambda model, sha: self.key)

        def models(*_a):
            self.models_built += 1
            samples = [SimpleNamespace(id=i, state="active") for i in self.samples]
            return {"p-me": SimpleNamespace(active=self.active, samples=samples, centroid=centroid)}

        monkeypatch.setattr(store, "models", models)
        monkeypatch.setattr(worker.pipeline, "voice_space", lambda e: RmSpace(ga=ga, centroids={"p-me": centroid}, count=500))


def test_a_revoked_wearer_is_never_served_from_the_cache(client, worker, settings, monkeypatch):
    """Rejecting samples, a consent change or a forget changes the evidence at once, while the published calibration
    (debounced, and kept by a forget) still says the same: the wearer must follow the evidence."""
    ev = Evidence(worker, monkeypatch)
    Vault.write_json(settings.vault_dir / "_omi" / "speakers" / "calibration.json", {"fingerprint": "same"})
    pipeline = worker.pipeline
    first = pipeline.provisional_wearer()
    assert first is not None and pipeline.provisional_wearer()[0] == first[0] and ev.models_built == 1, "cached"
    ev.key, ev.active = "e2", False  # a sample rejected: the model is no longer active
    assert pipeline.provisional_wearer() is None
    ev.key, ev.active = "e3", True
    assert pipeline.provisional_wearer()[0] == first[0], "the same samples: the same generation, nothing to redo"
    ev.key, ev.samples = "e4", ["s1", "s2"]
    assert pipeline.provisional_wearer()[0] != first[0], "other samples: another generation"


def test_a_result_is_committed_only_if_the_wearer_is_still_the_same(client, worker, monkeypatch):
    ev = Evidence(worker, monkeypatch)
    (conv,) = deferred_rows(worker, 1, model=None)
    pipeline = worker.pipeline

    def windows(row, wearer):
        ev.key, ev.active = "e9", False  # revoked while the session was being scored
        return [(9.0, 0.9)]

    monkeypatch.setattr(pipeline, "_wearer_windows", windows)
    pipeline.refresh_provisional(T0)
    row = worker.db.one("SELECT deferral, prov_due FROM conversations WHERE id=?", (conv,))
    assert json.loads(row["deferral"])["provisional"]["class"] == "undetermined", "never a class from revoked evidence"
    pipeline.refresh_provisional(T0 + 1)
    row = worker.db.one("SELECT deferral, prov_due FROM conversations WHERE id=?", (conv,))
    assert json.loads(row["deferral"])["provisional"] == {"class": "undetermined", "confidence": None,
                                                          "rule_id": "none-v1", "model": None}
