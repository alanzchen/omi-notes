"""docs/proposals/unreadable-speaker-files.md (shape ii), with Carbon D1's corrections: one policy per person,
OPTED_OUT > FROZEN > NORMAL, owned by SpeakerStore.person_policy and applied only by the two derived-state writers
(vector_labels, settle_states). A real opt-out wins over any unreadable file; an unreadable file never prunes, drops or
gives an automatic name; the wearer bypasses consent only, never an unreadable sample. Carbon D1's 10-item matrix, built on
its IT6 setup (synthetic fixtures only)."""

from __future__ import annotations

import json
import uuid
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.settings import Settings
from omi_notes.speakers.voices import Clip, LabelVoice
from omi_notes.util import canonical_json, sha256_hex

AUTH = {"Authorization": "Bearer tok"}


class _FakeEmb:
    model = "wespeaker"
    model_sha = "deadbeef12345678"

    def __init__(self, vec):
        self._vec = vec

    def embed(self, pcm):
        return self._vec


def _settings(root: Path) -> Settings:
    return Settings(vault_dir=root / "vault", index_dir=root / "index", lock_dir=root / "locks", omi_notes_token="tok",
                    stt_provider="fake", llm_provider="fake")  # fmt: skip


class Env:
    def __init__(self, tmp_path, *, n_samples=3, unknown_voices=False, me=False):
        self.client = TestClient(create_app(_settings(tmp_path), start_worker=False))
        self.svc = self.client.app.state.speakers
        self.store = self.svc.store
        rng = np.random.default_rng(42)
        self.gvec = rng.normal(size=256).astype(np.float32)
        self.gvec /= np.linalg.norm(self.gvec)
        self.svc.pipeline.providers._embedder = _FakeEmb(self.gvec)
        self.store.update_settings(acknowledged_at="2026-11-01T00:00:00Z", unknown_voices_enabled=unknown_voices,
                                   auto_assign=True)  # fmt: skip
        self.gigi = str(uuid.uuid4())
        body = {"name": "Gigi", "me": me} | ({} if me else {"attest_knows": True})
        assert self.client.put(f"/v1/people/{self.gigi}", json=body, headers=AUTH).status_code == 201
        for i in range(n_samples):
            v = self.gvec + 0.01 * rng.normal(size=256).astype(np.float32)
            self.store.add_sample(self.gigi, v / np.linalg.norm(v), model="wespeaker", model_sha="deadbeef12345678",
                                  source="user", seconds=6.0, day=f"2026-11-{18 + i:02d}", session=f"s-{i}")  # fmt: skip
        self.svc.warm(now=1000.0)
        self.conv, self.vfile = self.conversation(named=True, extra_unnamed=unknown_voices)

    def conversation(self, *, named: bool, extra_unnamed: bool = False, sha: str = "a"):
        conv_id = str(uuid.uuid4())
        segments = [{"speaker": "S1", "start": 0.0, "end": 8.0, "text": "Hello"}]
        tsha = sha256_hex(canonical_json(segments).encode())
        cdir = self.store.conv_dir(conv_id)
        cdir.mkdir(parents=True, exist_ok=True)
        (cdir / "transcript.json").write_text(json.dumps({"segments": segments, "audio_sha": sha * 64,
                                                           "speaker_clips": {"S1": [[0.5, 4.0], [4.5, 7.5]]}}))  # fmt: skip
        with self.store.db.tx() as conn:
            conn.execute('INSERT INTO conversations(id,device_id,start,"end",status,transcript_sha,audio_sha,blocks_json,'
                         "created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                         (conv_id, "dev1", 2000.0, 2010.0, "done", tsha, sha * 64, "[[2000,2010]]", 2000.0, 2010.0))  # fmt: skip
        voices = {"S1": LabelVoice("S1", [Clip(0.5, 4.0, 0), Clip(4.5, 7.5, 1)], vector=self.gvec.copy(), spread=0.05,
                                   rms_db=-20.0, f0=210.0, f0_voiced=10)}  # fmt: skip
        if extra_unnamed:
            other = np.random.default_rng(7).normal(size=256).astype(np.float32)
            voices["S2"] = LabelVoice("S2", [Clip(8.0, 9.0, 2)], vector=other / np.linalg.norm(other), spread=0.05,
                                      rms_db=-20.0, f0=120.0, f0_voiced=10)  # fmt: skip
        vname = f"voices-wespeaker-deadbeef-{sha * 16}-c00000000-" + tsha[:8] + ".json"
        self.store.write_voices(conv_id, vname, "wespeaker", "deadbeef12345678", voices, keep_vectors=set(voices))
        if named:
            self.store.write_labels(conv_id, {"S1": {"person_id": self.gigi, "source": "auto", "distance": 0.01, "margin": None,
                                                     "evidence_s": 6.5, "not": []}}, transcript_sha=tsha, voices=vname)  # fmt: skip
        return conv_id, cdir / vname

    def tear_sample(self):
        path = sorted((self.store.person_dir(self.gigi) / "samples").glob("*.json"))[0]
        self.original = path.read_text()
        path.write_text("{torn")
        return path

    def tear_consent(self, content="{torn"):
        (self.store.person_dir(self.gigi) / "consent.json").write_text(content)

    def name(self, conv=None):
        return (self.store.labels(conv or self.conv).get("S1") or {}).get("person_id")

    def stored(self, vfile=None):
        return {lab for lab, v in json.loads((vfile or self.vfile).read_text())["labels"].items() if "vector_b64" in v}

    def worker_pass(self, now=3000.0):
        """What the worker does: relabel (when pending), then retention."""
        self.svc.pipeline.relabel(now)
        self.store.reconcile_vectors()

    def identify_new(self):
        conv_id, _ = self.conversation(named=False, sha="c")
        segs = [{"speaker": "S1", "start": 0.0, "end": 8.0, "text": "Hello"}]
        tsha = sha256_hex(canonical_json(segs).encode())
        audio = type("Audio", (), {"pcm": np.ones(160000, dtype=np.int16)})()
        for f in self.store.conv_dir(conv_id).glob("voices-*.json"):
            f.unlink()  # fresh: identify embeds and assigns
        self.store.db.execute("DELETE FROM voices WHERE conversation_id=?", (conv_id,))
        self.svc.pipeline.identify(conv_id, audio, "c" * 64, {"S1": [Clip(0.5, 4.0, 0), Clip(4.5, 7.5, 1)]}, tsha, {"S1"})
        return self.name(conv_id)


def policy(env):
    return env.store.person_policy(env.gigi, env.store.settings())


# 1. C4-01
def test_1_a_torn_consent_file_freezes_names_and_vectors(tmp_path):
    e = Env(tmp_path)
    e.tear_consent()
    assert policy(e) == "frozen"
    e.store.db.set_meta("relabel_pending", "1")
    e.worker_pass()
    assert e.name() == e.gigi and e.stored() == {"S1"}


# 2. C5-01
@pytest.mark.parametrize("content,expected", [("[]", "frozen"), ("null", "frozen"), ("0", "frozen"), ('""', "frozen"),
                                              ("false", "frozen"), ("{}", "opted_out"), (None, "opted_out")])
def test_2_consent_file_shapes(tmp_path, content, expected):
    e = Env(tmp_path)
    path = e.store.person_dir(e.gigi) / "consent.json"
    if content is None:
        path.unlink()
    else:
        path.write_text(content)
    assert policy(e) == expected


# 3. C5-02, for a non-wearer and the wearer (D1-01)
@pytest.mark.parametrize("me", [False, True])
def test_3_a_torn_sample_freezes_even_the_wearer_and_repair_relabels(tmp_path, me):
    e = Env(tmp_path, me=me)
    saved = e.tear_sample()
    e.store.load_samples()  # the next reload (a file torn in place keeps its old, valid index row until then)
    assert policy(e) == "frozen"
    e.store.db.set_meta("relabel_pending", "1")
    e.worker_pass()
    assert e.name() == e.gigi and e.stored() == {"S1"}
    assert e.store.db.meta("relabel_pending") is None
    saved.write_text(e.original)  # repaired: the skipped set changes, so a relabel is marked
    assert e.store.sync_samples() is True and e.store.db.meta("relabel_pending") == "1"
    assert policy(e) == "normal"


# 4. C6-02
def test_4_unlinking_a_torn_sample_marks_a_relabel_and_an_inactive_name_goes(tmp_path):
    e = Env(tmp_path)
    bad = e.tear_sample()
    e.store.load_samples()
    e.store.db.set_meta("relabel_pending", "1")
    e.worker_pass()
    assert e.name() == e.gigi
    bad.unlink()  # "Fix or remove these files"
    assert e.store.sync_samples() is True and e.store.db.meta("relabel_pending") == "1"
    e.worker_pass()
    assert e.name() is None, "two samples left: the model is inactive and the automatic name goes"


# 5. C6-03
@pytest.mark.parametrize("block", ["frozen", "opted_out"])
def test_5_a_blocked_automatic_name_on_a_stateless_label_writes_nothing(tmp_path, block):
    e = Env(tmp_path, n_samples=4, unknown_voices=True)
    conv, _ = e.conversation(named=False, sha="d")
    if block == "frozen":
        e.tear_sample()
        e.store.load_samples()
    else:
        e.tear_consent("{}")
    assert not (e.store.conv_dir(conv) / "speakers.json").exists()
    e.store.db.set_meta("relabel_pending", "1")
    e.svc.pipeline.relabel(3000.0)
    assert not (e.store.conv_dir(conv) / "speakers.json").exists() and e.store.labels(conv) == {}


# 6. forget
@pytest.mark.parametrize("damage", [None, "consent", "sample"])
def test_6_forgetting_drops_names_and_vectors_whatever_is_unreadable(tmp_path, damage):
    e = Env(tmp_path)
    if damage == "consent":
        e.tear_consent()
    elif damage == "sample":
        e.tear_sample()
        e.store.load_samples()
    assert e.client.delete(f"/v1/people/{e.gigi}", headers=AUTH).status_code == 200
    e.worker_pass()
    assert e.name() is None and "S1" not in e.stored()


# 7. acknowledgment withdrawn
@pytest.mark.parametrize("unknown_voices", [False, True])
@pytest.mark.parametrize("damage", ["consent", "sample"])
def test_7_withdrawing_the_acknowledgment_wins_over_an_unreadable_file(tmp_path, unknown_voices, damage):
    e = Env(tmp_path, unknown_voices=unknown_voices)
    e.tear_consent() if damage == "consent" else (e.tear_sample(), e.store.load_samples())
    e.store.db.set_meta("relabel_pending", None)
    assert e.client.put("/v1/speakers/settings", json={"acknowledged_at": None}, headers=AUTH).status_code == 200
    assert e.store.db.meta("relabel_pending") == "1", "the transition schedules the relabel"
    assert policy(e) == "opted_out"
    e.worker_pass()
    assert e.name() is None
    # her voice may stay only as an anonymous unknown voice, and only while unknown voices are on (raw audio kept)
    assert ("S1" in e.stored()) is unknown_voices
    assert e.identify_new() is None


# 8. consent withdrawn ({} consent.json)
@pytest.mark.parametrize("damage", [None, "sample"])
def test_8_a_readable_consent_without_attestation_opts_out_names_vectors_and_hints(tmp_path, damage):
    e = Env(tmp_path)
    if damage:
        e.tear_sample()
        e.store.load_samples()
    e.store.db.set_meta("relabel_pending", None)
    e.tear_consent("{}")
    e.svc.warm(now=2000.0)  # the worker's People scan sees the change
    assert e.store.db.meta("relabel_pending") == "1", "the consent transition schedules the relabel"
    e.worker_pass()
    assert e.name() is None and "S1" not in e.stored()
    hints = e.svc.pipeline.possible_voice_names(e.conv, e.store.labels_transcript(e.conv))
    assert all(name != "Gigi" for name, _ in hints.values())
    assert e.identify_new() is None


# 9. auto_assign off
@pytest.mark.parametrize("damage", ["consent", "sample"])
def test_9_turning_automatic_naming_off_wins_over_an_unreadable_file(tmp_path, damage):
    e = Env(tmp_path)
    e.tear_consent() if damage == "consent" else (e.tear_sample(), e.store.load_samples())
    assert e.client.put("/v1/speakers/settings", json={"auto_assign": False}, headers=AUTH).status_code == 200
    e.worker_pass()
    assert e.name() is None and "S1" not in e.stored()


# 10. unknown voices off; a frozen person gets no new automatic name
def test_10_unknown_voices_off_prunes_unnamed_keeps_frozen_and_a_frozen_person_isnt_named_anew(tmp_path):
    e = Env(tmp_path, n_samples=4, unknown_voices=True)
    e.tear_sample()
    e.store.load_samples()
    assert e.client.put("/v1/speakers/settings", json={"unknown_voices_enabled": False}, headers=AUTH).status_code == 200
    e.worker_pass()
    assert e.stored() == {"S1"} and e.name() == e.gigi
    assert e.identify_new() is None, "frozen: no new automatic name"


def test_person_policy_reads_no_files_on_a_get(tmp_path, monkeypatch):
    e = Env(tmp_path)
    calls = []
    monkeypatch.setattr(e.store, "person_policy", lambda *a, **k: calls.append(1) or "normal")
    for path in ("/v1/people", "/v1/speakers/suggestions", "/v1/issues", "/v1/status"):
        assert e.client.get(path, headers=AUTH).status_code == 200
    assert calls == []
