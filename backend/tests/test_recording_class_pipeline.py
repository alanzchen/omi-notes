"""Recording classes in the pipeline: the summary's content cue, monologue and passive treatment, the owner's
choice through the API (applied by revision, never from a render), daily notes and the list filter. Fakes only."""

from __future__ import annotations

import json

import numpy as np

from omi_notes.pipeline.conversations import _reusable
from omi_notes.providers import LlmResult
from omi_notes.providers.fake import FakeLlm

from .conftest import AUTH
from .helpers import T0, convs, note_text, replay
from .test_speaker_learning import ALAN, voice

SR = 16000
USAGE = {"input_tokens": 100, "output_tokens": 10}


class ScriptedLlm(FakeLlm):
    """The fake summary with a chosen `interaction` and keep; asked for a monologue, it writes a cleaned text
    (unless `cleaned` is false). `during` runs inside a call (an owner acting while a summary is being made)."""

    def __init__(self, interaction: str, keep: bool = True, cleaned: bool = True, owner_items: bool = False):
        self.interaction, self.keep, self.cleaned, self.owner_items = interaction, keep, cleaned, owner_items
        self.calls: list[str] = []
        self.during = None

    def summarize(self, request):
        self.calls.append(request.user)
        if self.during:
            during, self.during = self.during, None
            during()
        result = super().summarize(request)
        data = dict(result.data, interaction=self.interaction, keep=self.keep,
                    discard_reason=None if self.keep else "a short request to an assistant")  # fmt: skip
        if self.owner_items:
            data["action_items"] = [dict(data["action_items"][0], description="Call the dentist", owner="me"),
                                    dict(data["action_items"][0], description="Someone else's errand", owner="other")]  # fmt: skip
        if "Recording kind: MONOLOGUE" in request.user and self.cleaned:
            data["sections"] = [{"heading": "Cleaned text", "bullets": ["Book the Lisbon hotel for the conference."]},
                                {"heading": "Tasks", "bullets": ["Hotel booking"]}]  # fmt: skip
        return LlmResult(data=data, model=self.model, usage=dict(USAGE))


def one_voice(client, seconds: float = 8.0):
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(seconds, ALAN, 7), np.zeros(3 * SR, np.int16)]))


def two_voices(client):
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(6, 210, 1), np.zeros(SR, np.int16), voice(6, 300, 2),
                                   np.zeros(3 * SR, np.int16)]))  # fmt: skip


def choose(client, conv_id: str, cls: str, rid: str, at: str):
    return client.put(f"/v1/conversations/{conv_id}/class", json={"class": cls, "request_id": rid, "set_at": at}, headers=AUTH)


def listed(client) -> dict:
    return client.get("/v1/conversations/recent", headers=AUTH).json()["conversations"][0]["recording_class"]


def applied(worker, conv_id: str) -> dict:
    return json.loads(worker.db.one("SELECT index_json FROM conversations WHERE id=?", (conv_id,))["index_json"])["recording_class"]


def test_a_dictation_is_kept_as_a_monologue_with_cleaned_text_even_if_the_summary_would_discard_it(client, worker, settings):
    worker.providers._llm = llm = ScriptedLlm("dictation", keep=False)
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "done", row["error"]
    text = note_text(settings, row)
    assert "recording_class: monologue" in text and "assistant_input: true" in text
    assert "## Cleaned Text" in text and "Book the Lisbon hotel" in text
    assert len(llm.calls) == 2, "the usual summary, then the monologue's cleaned text"


def test_both_summary_calls_of_a_monologue_are_counted_and_kept(client, worker):
    worker.providers._llm = ScriptedLlm("dictation")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    index = json.loads(row["index_json"])
    assert index["llm_usage"]["input_tokens"] == 200, "two calls of 100 input tokens"
    conv_dir = worker.pipeline.conv_dir(row["id"])
    assert (conv_dir / index["llm_preceded_by"]).exists() and (conv_dir / row["llm_ref"]).exists()
    worker.pipeline._collect_garbage(row["id"])
    assert (conv_dir / index["llm_preceded_by"]).exists(), "the first call's response is still referenced"


def test_a_monologue_whose_summary_left_out_the_cleaned_text_shows_the_words_flagged(client, worker, settings):
    worker.providers._llm = ScriptedLlm("dictation", cleaned=False)
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    text = note_text(settings, row)
    assert "## Cleaned Text" in text and "didn't return a cleaned text" in text


def test_media_without_alan_is_a_brief_passive_note_with_the_transcript_folded(client, worker, settings):
    worker.providers._llm = ScriptedLlm("media")
    two_voices(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    text = note_text(settings, row)
    assert row["status"] == "done" and "recording_class: passive" in text
    assert "> [!quote]- Transcript" in text and "## Key Points" not in text
    assert "Review the fake transcript" not in text, "no action items unless addressed to the owner"
    daily = next((settings.vault_dir / "Daily").glob("*.md")).read_text()
    assert "## Background" in daily and "Review the fake transcript" not in daily


def test_a_passive_recordings_owner_items_are_kept_and_others_hidden_everywhere(client, worker, settings):
    worker.providers._llm = ScriptedLlm("media", owner_items=True)
    two_voices(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    text = note_text(settings, row)
    assert "Call the dentist" in text and "Someone else's errand" not in text
    detail = client.get(f"/v1/conversations/{row['id']}", headers=AUTH).json()
    assert [a["description"] for a in detail["summary"]["action_items"]] == ["Call the dentist"]
    assert detail["summary"]["sections"] == [] and detail["summary"]["decisions"] == []
    assert [a for a in json.loads(row["index_json"])["action_items"] if "errand" in a] == []
    daily = next((settings.vault_dir / "Daily").glob("*.md")).read_text()
    assert "Call the dentist" in daily and "errand" not in daily


def test_the_owners_choice_is_applied_by_the_worker_and_shown_only_once_applied(client, worker, settings):
    worker.providers._llm = ScriptedLlm("media")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    r = choose(client, row["id"], "monologue", "r1", "2026-11-08T20:00:00Z")
    assert r.status_code == 200 and r.json()["applied"] is True
    assert r.json()["updating"] is True and r.json()["requested"] == "monologue"
    assert r.json()["class"] != "monologue", "not shown as applied before its summary"
    worker.tick(T0 + 500)
    worker.tick(T0 + 510)
    (row,) = convs(worker)
    assert "recording_class: monologue" in note_text(settings, row)
    shown = listed(client)
    assert shown["class"] == "monologue" and shown["overridden"] is True and shown["updating"] is False
    assert choose(client, row["id"], "monologue", "r1", "2026-11-08T20:00:00Z").json()["applied"] is True, "a repeat"
    assert choose(client, row["id"], "passive", "r0", "2026-11-08T19:00:00Z").json()["applied"] is False, "older"


def test_auto_goes_back_to_the_automatic_class_and_pinning_marks_the_choice(client, worker, settings):
    worker.providers._llm = ScriptedLlm("dictation")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert applied(worker, row["id"])["class"] == "monologue" and applied(worker, row["id"])["overridden"] is False
    choose(client, row["id"], "monologue", "pin", "2026-11-08T20:00:00Z")  # the same class, pinned
    worker.tick(T0 + 500)
    assert applied(worker, row["id"])["overridden"] is True and listed(client)["updating"] is False
    choose(client, row["id"], "dialogue", "r2", "2026-11-08T20:01:00Z")
    worker.tick(T0 + 540)
    assert applied(worker, row["id"])["class"] == "dialogue"
    choose(client, row["id"], "auto", "r3", "2026-11-08T20:02:00Z")
    assert listed(client)["updating"] is True
    worker.tick(T0 + 580)
    now = applied(worker, row["id"])
    assert now["class"] == "monologue" and now["overridden"] is False and listed(client)["updating"] is False


def test_a_choice_made_while_its_summary_is_being_written_is_not_lost(client, worker):
    worker.providers._llm = llm = ScriptedLlm("media")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    choose(client, row["id"], "monologue", "r1", "2026-11-08T20:00:00Z")
    # the owner changes it again while the worker is in the middle of the summary for "monologue"
    llm.during = lambda: choose(client, row["id"], "dialogue", "r2", "2026-11-08T20:01:00Z")
    worker.tick(T0 + 500)
    worker.tick(T0 + 540)
    worker.tick(T0 + 580)
    assert applied(worker, row["id"])["class"] == "dialogue" and listed(client)["updating"] is False


def test_a_frozen_note_keeps_its_kind_and_never_starts_a_summary(client, worker):
    worker.providers._llm = llm = ScriptedLlm("media")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    worker.db.execute("UPDATE conversations SET frozen=1 WHERE id=?", (row["id"],))
    assert choose(client, row["id"], "monologue", "r1", "2026-11-08T20:00:00Z").status_code == 409
    # a choice written by hand (or before the freeze) is left for later, not applied
    (worker.pipeline.conv_dir(row["id"]) / "class.json").write_text(json.dumps({"format": 1, "class": "monologue", "revision": 5, "set_at": 1}))
    calls = len(llm.calls)
    worker.tick(T0 + 500)
    worker.tick(T0 + 540)
    (after,) = convs(worker)
    assert after["status"] == "done" and len(llm.calls) == calls


def test_a_rerender_from_cache_never_starts_a_summary(client, worker):
    worker.providers._llm = llm = ScriptedLlm("media")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    choose(client, row["id"], "monologue", "r1", "2026-11-08T20:00:00Z")
    calls = len(llm.calls)
    worker.pipeline.summarize_and_render(row["id"], T0 + 450, cache_only=True)
    (after,) = convs(worker)
    assert after["status"] == "done" and len(llm.calls) == calls and applied(worker, row["id"])["class"] == "passive"


def test_an_unreadable_choice_is_an_issue_and_the_note_keeps_its_kind(client, worker):
    worker.providers._llm = ScriptedLlm("dictation")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    (worker.pipeline.conv_dir(row["id"]) / "class.json").write_text("{not json")
    assert choose(client, row["id"], "dialogue", "r1", "2026-11-08T20:00:00Z").status_code == 409
    shown = listed(client)
    assert shown["class"] == "monologue" and "can't be read" in shown["choice_unreadable"]
    worker.tick(T0 + 500)
    issues = client.get("/v1/issues", headers=AUTH).json()["issues"]
    assert any(i["code"] == "class_choice_unreadable" for i in issues)


def test_the_list_filters_by_class_before_paging(client, worker):
    worker.providers._llm = ScriptedLlm("dictation")
    one_voice(client)
    worker.tick(T0 + 400)
    ok = client.get("/v1/conversations/recent?class=monologue", headers=AUTH).json()["conversations"]
    none = client.get("/v1/conversations/recent?class=passive", headers=AUTH).json()["conversations"]
    assert len(ok) == 1 and none == []
    assert client.get("/v1/conversations/recent?class=junk", headers=AUTH).status_code == 422
    assert "recording_class" in client.get("/v1/status", headers=AUTH).json()["features"]


def test_cache_lookups_match_exact_identities_not_longer_names_that_start_the_same(tmp_path):
    base = "llm-m-p3-abcdef0123456789-s12345678"
    (tmp_path / f"{base}-cm3.json").write_text("{}")  # a monologue's summary, not the plain one
    assert _reusable(tmp_path, base, f"{base}-cm3.json", None) == f"{base}.json"
    (tmp_path / f"{base}-2.json").write_text("{}")
    assert _reusable(tmp_path, base, f"{base}-2.json", None) == f"{base}-2.json", "a write-once retry still counts"
