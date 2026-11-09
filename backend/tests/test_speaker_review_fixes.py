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


# -- 11: activation validates the model that is actually matched -------------------------------------------------


def test_an_enrollment_only_model_is_active_only_if_the_confirmations_match_it():
    # an orthogonal 80 s enrollment, older than 20 confirmations (the newest-20 cap leaves it out of leave-one-out)
    other = [sm.Sample(f"e{i}", "alan", vec(RAVI, i), "enrollment", "2026-09-20", f"imp{i}", float(i), seconds=20.0) for i in range(4)]
    mine = [sm.Sample(f"u{i}", "alan", vec(ALAN, i % 9), "user", f"2026-09-2{i % 3}", f"c{i}", 10.0 + i, seconds=8.0)
            for i in range(sm.SAMPLE_CAP)]  # fmt: skip
    model = sm.build_models(other + mine)["alan"]
    assert model.enrollment_only
    assert not model.active and "enrollment" in model.why_inactive, "an enrollment unlike every confirmation is no model"
    same = [sm.Sample(s.id, s.person_id, vec(ALAN, 5 + i), s.source, s.day, s.session, s.created_at, seconds=20.0)
            for i, s in enumerate(other)]  # fmt: skip
    assert sm.build_models(same + mine)["alan"].active, "the gates themselves are unchanged"


# -- 13: the calibration fingerprint covers everything the evaluation depends on ----------------------------------


def test_the_calibration_fingerprint_covers_ga_unknown_storage_and_operating_points(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker, days=(6, 5))
    calibrator = worker.calibrator
    first = calibrator.fingerprint()
    client.put("/v1/speakers/settings", json={"unknown_voices_enabled": True}, headers=AUTH)
    second = calibrator.fingerprint()
    assert second != first, "the unknown-voice preference changes what GA may hold"
    worker.pipeline.operating = sm.Operating(threshold=0.45, margin=0.1)
    third = calibrator.fingerprint()
    assert third != second, "other operating points are another matcher"
    store = worker.pipeline.speakers
    with store.lock:  # GA changes without any sample or named label changing: a stored unknown voice
        store.prune_vectors(rows[0]["id"], {"S1"})
    assert calibrator.fingerprint() == third
    worker.db.execute("UPDATE voices SET vector=? WHERE conversation_id=? AND label='S1'",
                      (np.asarray(vec(RAVI), dtype="<f4").tobytes(), rows[1]["id"]))  # fmt: skip
    assert calibrator.fingerprint() != third, "the GA cohort is part of the input"


# -- 15: uploads at other sample rates are resampled without aliasing -------------------------------------------


def test_an_uploaded_wav_at_another_rate_is_resampled_without_aliasing():
    import io

    import soundfile as sf

    from omi_notes.audio import aac
    from omi_notes.speakers.imports import decode_upload

    if not aac.available():
        pytest.skip("ffmpeg is not installed")
    rate = 44100
    t = np.arange(rate * 2) / rate
    high = (np.sin(2 * np.pi * 12000 * t) * 12000).astype(np.int16)  # above the 8 kHz Nyquist of 16 kHz audio
    low = (np.sin(2 * np.pi * 300 * t) * 12000).astype(np.int16)
    buf = io.BytesIO()
    sf.write(buf, np.stack([high, high], axis=1), rate, format="WAV", subtype="PCM_16")
    out = decode_upload("stereo.wav", buf.getvalue()).astype(np.float64)
    assert abs(len(out) - 32000) <= 32
    assert np.sqrt(np.mean(out**2)) < 0.02 * 12000 / np.sqrt(2), "a 12 kHz tone must not fold into the speech band"
    buf = io.BytesIO()
    sf.write(buf, low, rate, format="WAV", subtype="PCM_16")
    kept = decode_upload("tone.wav", buf.getvalue()).astype(np.float64)
    assert np.sqrt(np.mean(kept**2)) == pytest.approx(12000 / np.sqrt(2), rel=0.05)


# -- 3, 4, 5 and decision (a): journaled moves, rejects and their undo ------------------------------------------


def journal_files(settings) -> list:
    folder = settings.vault_dir / "_omi" / "speakers" / "journal"
    return sorted(folder.glob("*.json")) if folder.exists() else []


def consented_priya(client) -> str:
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH)
    return new_person(client, "Priya", attest_knows=True)


def test_a_move_interrupted_after_its_copy_is_finished_and_the_copy_never_counted_before(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    store = worker.pipeline.speakers
    real = store.set_sample_state

    def crash(*args, **kwargs):
        if kwargs.get("action") == "move":
            raise OSError("power cut")
        return real(*args, **kwargs)

    monkeypatch.setattr(store, "set_sample_state", crash)
    with pytest.raises(OSError):
        client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": priya, "request_id": "mv-1"}, headers=AUTH)
    monkeypatch.setattr(store, "set_sample_state", real)
    (op,) = journal_files(settings)
    copies = list((Vault.open(settings).person_dir(priya) / "samples").glob("*.json"))
    assert len(copies) == 1 and json.loads(copies[0].read_text())["pending_op"]
    assert worker.db.one("SELECT state FROM samples WHERE id=?", (copies[0].stem,))["state"] == "pending"
    # the next model build finishes it: original moved, copy counts, label follows, journal empty
    eligible = {s.id for s in store.samples(*MODEL)}
    assert copies[0].stem in eligible and ids[0] not in eligible
    assert sample_file(settings, me, ids[0])["state"] == "moved" and journal_files(settings) == []
    assert store.labels(rows[0]["id"])["S1"]["person_id"] == priya
    again = client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": priya, "request_id": "mv-1"}, headers=AUTH)
    assert again.status_code == 200 and again.json()["sample"]["state"] == "moved"


def test_worker_startup_and_forget_finish_an_interrupted_operation_first(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    store = worker.pipeline.speakers
    real = store.set_sample_state
    monkeypatch.setattr(store, "set_sample_state", lambda *a, **k: (_ for _ in ()).throw(OSError("power cut"))
                        if k.get("action") == "move" else real(*a, **k))  # fmt: skip
    with pytest.raises(OSError):
        client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": priya, "request_id": "mv-s"}, headers=AUTH)
    monkeypatch.setattr(store, "set_sample_state", real)
    from omi_notes.db import Database
    from omi_notes.pipeline.worker import Worker

    fresh = Worker(settings, Database(settings.db_path))
    fresh.tick(T0 + 9000)
    assert journal_files(settings) == [] and sample_file(settings, me, ids[0])["state"] == "moved"
    # forget: an operation interrupted again is finished before the person's data goes
    monkeypatch.setattr(store, "set_sample_state", lambda *a, **k: (_ for _ in ()).throw(OSError("power cut"))
                        if k.get("action") == "move" else real(*a, **k))  # fmt: skip
    with pytest.raises(OSError):
        client.post(f"/v1/samples/{ids[1]}/move", json={"person_id": priya, "request_id": "mv-t"}, headers=AUTH)
    monkeypatch.setattr(store, "set_sample_state", real)
    assert client.delete(f"/v1/people/{priya}", headers=AUTH).status_code == 200
    assert journal_files(settings) == [] and not Vault.open(settings).person_dir(priya).exists()


def test_an_interrupted_undo_of_a_move_is_finished_without_both_copies_counting(env, monkeypatch):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    store = worker.pipeline.speakers
    assert client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": priya, "request_id": "mv-2"}, headers=AUTH).status_code == 200
    copy = sample_file(settings, me, ids[0])["moved_to"]["sample_id"]
    real = store.remove_sample_ids
    monkeypatch.setattr(store, "remove_sample_ids", lambda *a, **k: (_ for _ in ()).throw(OSError("power cut")))
    with pytest.raises(OSError):
        client.post("/v1/speakers/undo", json={"request_id": "mv-2", "undo_request_id": "u-2"}, headers=AUTH)
    monkeypatch.setattr(store, "remove_sample_ids", real)
    assert sample_file(settings, me, ids[0])["state"] == "active"
    eligible = {s.id for s in store.samples(*MODEL)}  # reconciles: the copy goes
    assert copy not in eligible and ids[0] in eligible and journal_files(settings) == []
    assert not (Vault.open(settings).person_dir(priya) / "samples" / f"{copy}.json").exists()
    assert store.labels(rows[0]["id"])["S1"]["person_id"] == me


def test_moving_one_sample_moves_every_sample_its_label_gave_that_person(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    store = worker.pipeline.speakers
    with store.lock:  # the label contributed a second confirmation of Alan (e.g. confirmed again later)
        second = store.add_sample(me, vec(ALAN, 3), model=MODEL[0], model_sha=MODEL[1], source="user", seconds=8.0,
                                  day="2026-09-20", session=rows[0]["id"], conversation_id=rows[0]["id"], label="S1")  # fmt: skip
        states = store.labels(rows[0]["id"])
        states["S1"]["samples"] = sorted({ids[0], second})
        store.write_labels(rows[0]["id"], states)
    listed = [second]
    r = client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": priya, "request_id": "mv-3"}, headers=AUTH)
    assert r.status_code == 200, r.text
    label = store.labels(rows[0]["id"])["S1"]
    assert label["person_id"] == priya
    owners = {sid: (Vault.open(settings).person_dir(priya) / "samples" / f"{sid}.json").exists() for sid in label["samples"]}
    assert len(owners) == 2 and all(owners.values()), "no sample of Alan's stays on a label named Priya"
    assert all(sample_file(settings, me, sid)["state"] == "moved" for sid in sorted(set(listed) | {ids[0]}))


def test_undoing_a_move_is_skipped_after_a_later_decision_about_its_copy(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    priya = consented_priya(client)
    assert client.post(f"/v1/samples/{ids[0]}/move", json={"person_id": priya, "request_id": "mv-4"}, headers=AUTH).status_code == 200
    copy = sample_file(settings, me, ids[0])["moved_to"]["sample_id"]
    assert client.post(f"/v1/samples/{copy}/remove", json={"request_id": "rm-4"}, headers=AUTH).status_code == 200
    undo = client.post("/v1/speakers/undo", json={"request_id": "mv-4", "undo_request_id": "u-4"}, headers=AUTH).json()
    assert undo["undone"] == [] and undo["skipped"] == [rows[0]["id"]]
    assert sample_file(settings, me, ids[0])["state"] == "moved" and sample_file(settings, priya, copy)["state"] == "removed"


def test_undoing_a_reject_needs_the_persons_current_consent(env):
    settings, client, worker = env
    priya = consented_priya(client)
    row = talk(client, worker, dialogue(ALAN, PRIYA, seed=3), day=3)
    assert name_label(client, row["id"], "S2", priya).json()["sample"] == "created"
    (sid,) = worker.pipeline.speakers.labels(row["id"])["S2"]["samples"]
    item = next(i for i in review(client) if i.get("sample_id") == sid)
    assert decide(client, item["id"], "reject", "rj-5").status_code == 200
    client.put(f"/v1/people/{priya}", json={"name": "Priya", "attest_knows": False}, headers=AUTH)
    client.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH)
    undo = client.post("/v1/speakers/undo", json={"request_id": "rj-5", "undo_request_id": "u-5"}, headers=AUTH).json()
    assert undo["undone"] == [] and sample_file(settings, priya, sid)["state"] == "removed"
    restore = client.post(f"/v1/samples/{sid}/restore", json={"request_id": "rs-5"}, headers=AUTH)
    assert restore.status_code == 409 and restore.json()["error"] == "consent_required"


def test_a_reject_leaves_a_label_alone_that_no_longer_lists_the_sample(env):
    settings, client, worker = env
    me, rows, ids = me_with_samples(client, worker)
    store = worker.pipeline.speakers
    states = store.labels(rows[0]["id"])
    states["S1"]["samples"] = []  # the label's provenance moved on (another confirmation, a re-transcription)
    store.write_labels(rows[0]["id"], states)
    item = next(i for i in review(client) if i.get("sample_id") == ids[0])
    assert decide(client, item["id"], "reject", "rj-6").status_code == 200
    assert sample_file(settings, me, ids[0])["state"] == "removed"
    label = store.labels(rows[0]["id"])["S1"]
    assert label["person_id"] == me and label["not"] == []
