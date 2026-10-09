"""The phone's "Name this voice" flow (docs/speaker-learning.md, "Naming from the phone").

What the server adds for it: each clip with the transcript text it overlaps (so the phone never
pairs a clip with an unrelated sentence), the context and scope of a suggestion, a durable
"keep unknown" that is not the 7-day dismissal, and an undo that reverts exactly what one naming
request changed."""

from __future__ import annotations

import json
import shutil
import uuid

from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.pipeline.worker import Worker
from omi_notes.providers.fake import FakeStt
from omi_notes.speakers.service import SpeakerService
from omi_notes.vault import Vault

from .conftest import AUTH
from .test_speaker_learning import ALAN, PRIYA, RAVI, CountingLlm, FakeEmbedder, dialogue, env, name_label, new_person, talk  # noqa: F401


class TaggedStt(FakeStt):
    """Each utterance says which turn it is, so a clip's text can be checked against its turn."""

    def transcribe(self, request):
        response = super().transcribe(request)
        for i, utt in enumerate(response["results"]["utterances"]):
            utt["transcript"] = f"Turn {i} of the conversation."
        return response


def get(client, path):
    r = client.get(path, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()


def labels(client, conv_id):
    return {x["label"]: x for x in get(client, f"/v1/conversations/{conv_id}/speakers")["labels"]}


def recurring(env):
    """Alan (me) plus Ravi recurring in 3 conversations on 2 days, unknown voices on, consent given."""
    settings, client, worker = env
    worker.providers._stt = TaggedStt()
    me = new_person(client, "Alan", me=True)
    seed = talk(client, worker, dialogue(ALAN, PRIYA), day=9)
    name_label(client, seed["id"], "S1", me)
    client.put("/v1/speakers/settings", json={"unknown_voices_enabled": True, "acknowledged_at": "2026-09-27T10:00:00Z"},
               headers=AUTH)  # fmt: skip
    rows = [talk(client, worker, dialogue(ALAN, RAVI, turns=6, seconds=5.0, seed=day), day=day) for day in (3, 2, 2)]
    (s,) = [x for x in get(client, "/v1/speakers/suggestions")["suggestions"] if x["kind"] == "who_is_this"]
    return me, rows, s


def test_each_clip_carries_the_text_it_overlaps_not_the_first_sentence(env):
    settings, client, worker = env
    worker.providers._stt = TaggedStt()
    row = talk(client, worker, dialogue(ALAN, PRIYA, turns=6, seconds=5.0))
    s2 = labels(client, row["id"])["S2"]
    assert len(s2["clips"]) >= 2 and s2["clip_id"] == s2["clips"][0]["id"]
    texts = [c["text"] for c in s2["clips"]]
    # S2 speaks turns 1, 3, 5; each clip shows its own turn, never S1's words or always turn 1
    assert all(t.startswith("Turn ") for t in texts) and len(set(texts)) == len(texts)
    assert all(int(t.split()[1]) % 2 == 1 for t in texts)
    for c in s2["clips"]:
        assert 0 < c["seconds"] <= 10 and c["started_at"]
        assert client.get(f"/v1/clips/{c['id']}", headers=AUTH).status_code == 200
    assert s2["kept_unknown"] is False


def test_a_suggestion_says_where_it_was_heard_and_offers_another_day(env):
    me, rows, s = recurring(env)
    _, client, _ = env
    assert s["conversation"]["id"] in {r["id"] for r in rows} and s["conversation"]["started_at"]
    assert {c["id"] for c in s["scope"]} == {r["id"] for r in rows}  # what naming it would change
    assert s["clips"] and all(c["conversation_id"] == s["conversation"]["id"] and c["text"] for c in s["clips"])
    other = s["other_day"]
    assert other is not None and other["conversation_id"] != s["conversation"]["id"]
    assert other["started_at"][:10] != s["conversation"]["started_at"][:10]
    assert client.get(f"/v1/clips/{other['id']}", headers=AUTH).status_code == 200


def test_keep_unknown_is_durable_and_is_not_the_seven_day_dismissal(env):
    settings, client, worker = env
    me, rows, s = recurring(env)
    r = client.post(f"/v1/speakers/suggestions/{s['id']}/keep-unknown", json={"request_id": "ku-1"}, headers=AUTH)
    assert r.status_code == 200, r.text
    assert set(r.json()["conversations"]) == {row["id"] for row in rows}
    assert all(labels(client, row["id"])["S2"]["kept_unknown"] for row in rows)
    assert all(labels(client, row["id"])["S2"]["person_id"] is None for row in rows)
    speakers_settings = json.loads((settings.vault_dir / "_omi" / "speakers" / "settings.json").read_text())
    assert s["id"] not in (speakers_settings.get("dismissed") or {})  # not a cooldown
    assert json.loads((settings.vault_dir / "_omi" / "VAULT.json").read_text())["format"] == 4
    assert s["id"] not in {x["id"] for x in get(client, "/v1/speakers/suggestions")["suggestions"]}

    # long after any cooldown, and after the index is rebuilt from the vault, it is still unknown
    shutil.rmtree(settings.index_dir)
    client = TestClient(create_app(settings, start_worker=False))
    worker = Worker(settings, Database(settings.db_path))
    worker.providers._embedder = FakeEmbedder()
    client.app.state.speakers = SpeakerService(worker.pipeline)
    for t in range(4):
        worker.tick(10**10 + t)
    assert all(labels(client, row["id"])["S2"]["kept_unknown"] for row in rows)
    assert s["id"] not in {x["id"] for x in client.get("/v1/speakers/suggestions", headers=AUTH).json()["suggestions"]}


def test_a_kept_unknown_label_is_never_named_automatically(env):
    settings, client, worker = env
    me, rows, s = recurring(env)
    conv = rows[0]["id"]
    assert name_label(client, conv, "S2", None, keep_unknown=True).status_code == 200
    ravi = new_person(client, "Ravi", attest_knows=True)
    for row in rows[1:]:  # Ravi becomes well known elsewhere
        assert name_label(client, row["id"], "S2", ravi).status_code == 200
    worker.tick(10**10)
    assert labels(client, conv)["S2"]["person_id"] is None and labels(client, conv)["S2"]["kept_unknown"]
    # and the owner can still name it later
    assert name_label(client, conv, "S2", ravi).json()["labels"][1]["person_id"] == ravi


def test_undo_reverts_exactly_one_naming_and_keeps_the_rest_of_the_voice(env):
    settings, client, worker = env
    me, rows, s = recurring(env)
    ravi = new_person(client, "Ravi", attest_knows=True)
    # an earlier, separate confirmation of Ravi stays whatever happens to the suggestion's
    other = talk(client, worker, dialogue(PRIYA, RAVI, seed=41), day=1)
    assert name_label(client, other["id"], "S2", ravi).json()["sample"] == "created"
    samples_before = {r["id"] for r in worker.db.query("SELECT id FROM samples WHERE person_id=?", (ravi,))}

    assert client.post(f"/v1/speakers/suggestions/{s['id']}/assign", json={"person_id": ravi, "request_id": "name-1"},
                       headers=AUTH).status_code == 200  # fmt: skip
    assert all(labels(client, row["id"])["S2"]["person_id"] == ravi for row in rows)
    added = {r["id"] for r in worker.db.query("SELECT id FROM samples WHERE person_id=?", (ravi,))} - samples_before
    assert added

    r = client.post("/v1/speakers/undo", json={"request_id": "name-1", "undo_request_id": "undo-1"}, headers=AUTH)
    assert r.status_code == 200, r.text
    assert set(r.json()["undone"]) == {row["id"] for row in rows} and r.json()["skipped"] == []
    assert all(labels(client, row["id"])["S2"]["person_id"] is None for row in rows)
    after = {r["id"] for r in worker.db.query("SELECT id FROM samples WHERE person_id=?", (ravi,))}
    assert after == samples_before  # only what that naming created is gone
    assert labels(client, other["id"])["S2"]["person_id"] == ravi
    assert any(p["id"] == ravi for p in get(client, "/v1/people")["people"])
    again = client.post("/v1/speakers/undo", json={"request_id": "name-1", "undo_request_id": "undo-1"}, headers=AUTH)
    assert again.status_code == 200 and set(again.json()["undone"]) == set(r.json()["undone"])


def test_undo_leaves_a_label_changed_since_alone(env):
    settings, client, worker = env
    worker.providers._stt = TaggedStt()
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH)
    priya = new_person(client, "Priya", attest_knows=True)
    rid = str(uuid.uuid4())
    assert name_label(client, row["id"], "S2", priya, request_id=rid).status_code == 200
    assert name_label(client, row["id"], "S2", me).status_code == 200  # changed again meanwhile
    r = client.post("/v1/speakers/undo", json={"request_id": rid, "undo_request_id": "u-2"}, headers=AUTH)
    assert r.status_code == 200 and r.json()["undone"] == [] and r.json()["skipped"] == [row["id"]]
    assert labels(client, row["id"])["S2"]["person_id"] == me


def test_naming_does_not_queue_a_summary(env):
    settings, client, worker = env
    me, rows, s = recurring(env)
    ravi = new_person(client, "Ravi", attest_knows=True)
    calls = worker.providers._llm.calls
    client.post(f"/v1/speakers/suggestions/{s['id']}/assign", json={"person_id": ravi, "request_id": "n-2"}, headers=AUTH)
    for t in range(3):
        worker.tick(10**10 + t)
    assert worker.providers._llm.calls == calls  # names re-render the note from cache; no new summary
    assert get(client, "/v1/status")["features"].count("name_voice") == 1


# -- regressions found in acceptance (coordinator's reproducers, adopted as they were) -------------


def test_undo_restores_original_confirmed_voice_samples(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH)
    priya = new_person(client, "Priya", attest_knows=True)
    assert name_label(client, row["id"], "S2", priya).json()["sample"] == "created"
    before = {r["id"] for r in worker.db.query("SELECT id FROM samples WHERE person_id=?", (priya,))}
    assert before
    rid = str(uuid.uuid4())
    assert name_label(client, row["id"], "S2", me, request_id=rid).status_code == 200
    response = client.post("/v1/speakers/undo", json={"request_id": rid, "undo_request_id": str(uuid.uuid4())}, headers=AUTH)
    assert response.status_code == 200
    after = {r["id"] for r in worker.db.query("SELECT id FROM samples WHERE person_id=?", (priya,))}
    assert after == before, "Undo reports success but drops original confirmed voice samples"
    assert labels(client, row["id"])["S2"]["person_id"] == priya


def test_clip_without_overlapping_words_does_not_quote_other_audio():
    service = object.__new__(SpeakerService)
    transcript = {"timemap": [[0, 1000, 100]],
                  "segments": [{"speaker": "S1", "start": 1050, "end": 1060, "text": "Words from a different moment"}]}  # fmt: skip
    clips = service._clip_list("fixture", transcript, "S1", [[0, 10]])
    assert clips[0]["text"] == "", "No overlapping words: do not silently substitute a different moment"


def test_undo_never_brings_back_a_forgotten_voice(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH)
    priya = new_person(client, "Priya", attest_knows=True)
    name_label(client, row["id"], "S2", priya)
    rid = str(uuid.uuid4())
    name_label(client, row["id"], "S2", me, request_id=rid)
    assert client.delete(f"/v1/people/{priya}", headers=AUTH).status_code == 200  # forgotten meanwhile
    r = client.post("/v1/speakers/undo", json={"request_id": rid, "undo_request_id": "u-forgot"}, headers=AUTH).json()
    assert r["undone"] == [] and r["skipped"] == [row["id"]]  # nothing partial: the later decision stands
    assert not worker.db.query("SELECT 1 FROM samples WHERE person_id=?", (priya,))
    folder = worker.pipeline.speakers.person_dir(priya)
    assert not folder.exists() or not any(folder.rglob("*.json"))  # nothing withdrawn was kept behind
    assert labels(client, row["id"])["S2"]["person_id"] == me


def test_withdrawn_voiceprints_are_kept_only_for_a_bounded_time(env):
    settings, client, worker = env
    row = talk(client, worker, dialogue(ALAN, PRIYA))
    me = new_person(client, "Alan", me=True)
    client.put("/v1/speakers/settings", json={"acknowledged_at": "2026-09-27T10:00:00Z"}, headers=AUTH)
    priya = new_person(client, "Priya", attest_knows=True)
    name_label(client, row["id"], "S2", priya)
    rid = str(uuid.uuid4())
    name_label(client, row["id"], "S2", me, request_id=rid)
    store = worker.pipeline.speakers
    assert store.purge_withdrawn(now=10**12) >= 1  # past the undo window: deleted for good
    r = client.post("/v1/speakers/undo", json={"request_id": rid, "undo_request_id": "u-late"}, headers=AUTH).json()
    assert r["undone"] == [] and r["skipped"] == [row["id"]]  # no partial undo without the voiceprints
    assert labels(client, row["id"])["S2"]["person_id"] == me
