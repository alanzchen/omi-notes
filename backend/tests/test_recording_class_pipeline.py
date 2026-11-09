"""Recording classes in the pipeline: the summary's content cue, monologue and passive treatment, the owner's
choice through the API (applied by revision, never from a render), daily notes and the list filter. Fakes only."""

from __future__ import annotations

import json
from datetime import timedelta

import numpy as np

from omi_notes import recording_class as rclass
from omi_notes.pipeline.conversations import CLASS_REWRITE_RETRY, _reusable
from omi_notes.providers import LlmResult, ProviderError
from omi_notes.providers.fake import FakeLlm

from .conftest import AUTH
from .helpers import STARTED, T0, convs, note_text, replay
from .test_speaker_learning import ALAN, voice

SR = 16000
USAGE = {"input_tokens": 100, "output_tokens": 10}


class ScriptedLlm(FakeLlm):
    """The fake summary with a chosen `interaction` and keep; asked for a monologue, it writes a cleaned text
    (unless `cleaned` is false). `during` runs inside a call (an owner acting while a summary is being made)."""

    def __init__(self, interaction: str, keep: bool = True, cleaned: bool = True, owner_items: bool = False,
                 ai_items: bool = False):  # fmt: skip
        self.interaction, self.keep, self.cleaned, self.owner_items = interaction, keep, cleaned, owner_items
        self.ai_items = ai_items
        self.calls: list[str] = []
        self.during = None
        self.fail: ProviderError | None = None

    def summarize(self, request):
        self.calls.append(request.user)
        if self.fail:
            raise self.fail
        if self.during:
            during, self.during = self.during, None
            during()
        result = super().summarize(request)
        data = dict(result.data, interaction=self.interaction, keep=self.keep,
                    discard_reason=None if self.keep else "a short request to an assistant")  # fmt: skip
        if self.owner_items:
            data["action_items"] = [dict(data["action_items"][0], description="Call the dentist", owner="me"),
                                    dict(data["action_items"][0], description="Someone else's errand", owner="other")]  # fmt: skip
        if self.ai_items:
            data["action_items"] = [dict(data["action_items"][0], description="Call the dentist", owner="me"),
                                    dict(data["action_items"][0], description="Draft the hotel email", owner="me",
                                         directed_at_ai=True)]  # fmt: skip
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


def test_a_class_rewrite_that_fails_keeps_the_last_good_note_and_stays_requested(client, worker, settings):
    worker.providers._llm = llm = ScriptedLlm("media")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    before, conv_dir = note_text(settings, row), worker.pipeline.conv_dir(row["id"])
    choose(client, row["id"], "monologue", "r1", "2026-11-08T20:00:00Z")
    llm.fail = ProviderError("the summary provider refused", terminal=True, kind="notes")
    worker.tick(T0 + 500)
    worker.tick(T0 + 540)
    (after,) = convs(worker)
    assert after["status"] == "done" and after["llm_ref"] == row["llm_ref"] and after["llm_status"] == "ok"
    assert (conv_dir / row["llm_ref"]).exists(), "the last good summary is never collected"
    assert note_text(settings, after) == before and applied(worker, row["id"])["class"] == "passive"
    shown = listed(client)
    assert shown["class"] == "passive" and shown["updating"] is True and shown["requested"] == "monologue"
    assert "couldn't be rewritten" in shown["update_failed"]
    worker.tick(T0 + 600)
    assert convs(worker)[0]["status"] == "done", "not retried at once"
    llm.fail = None
    worker.tick(T0 + 540 + CLASS_REWRITE_RETRY + 1)
    worker.tick(T0 + 540 + CLASS_REWRITE_RETRY + 40)
    assert applied(worker, row["id"])["class"] == "monologue" and "update_failed" not in listed(client)


def test_a_note_frozen_after_its_rewrite_was_queued_is_left_as_it_was(client, worker):
    worker.providers._llm = llm = ScriptedLlm("media")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    choose(client, row["id"], "monologue", "r1", "2026-11-08T20:00:00Z")
    assert worker.pipeline.reconcile_classes(T0 + 450) == 1
    worker.db.execute("UPDATE conversations SET frozen=1 WHERE id=?", (row["id"],))
    calls = len(llm.calls)
    worker.tick(T0 + 500)
    worker.tick(T0 + 540)
    (after,) = convs(worker)
    assert after["status"] == "done" and len(llm.calls) == calls and applied(worker, row["id"])["class"] == "passive"


def test_a_choice_file_with_malformed_fields_is_unreadable_and_never_breaks_the_list(client, worker):
    worker.providers._llm = ScriptedLlm("media")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    path = worker.pipeline.conv_dir(row["id"]) / "class.json"
    for bad in ({"class": "monologue", "revision": "broken", "set_at": 1}, {"class": "monologue", "revision": 1, "set_at": "x"},
                {"class": "monologue", "revision": True, "set_at": 1}, {"class": "monologue", "revision": 1, "set_at": 1, "requests": 3}):
        path.write_text(json.dumps(bad))
        try:
            rclass.read(worker.pipeline, row["id"])
        except rclass.UnreadableChoice:
            pass
        else:
            raise AssertionError(f"{bad} was read as a choice")
    path.write_text(json.dumps({"class": "monologue", "revision": "broken", "set_at": 1}))
    r = client.get("/v1/conversations/recent", headers=AUTH)
    assert r.status_code == 200 and r.json()["conversations"][0]["recording_class"]["choice_unreadable"]
    assert worker.pipeline.reconcile_classes(T0 + 450) == 0


def test_one_bad_choice_never_stops_the_others_being_applied(client, worker, monkeypatch):
    worker.providers._llm = ScriptedLlm("media")
    one_voice(client)
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8.0, ALAN, 7), np.zeros(3 * SR, np.int16)]),
           start=STARTED + timedelta(hours=1))  # fmt: skip
    worker.tick(T0 + 3600 + 400)
    rows = convs(worker)
    assert len(rows) == 2 and all(r["status"] == "done" for r in rows)
    for i, r in enumerate(rows):
        choose(client, r["id"], "monologue", f"r{i}", "2026-11-08T20:00:00Z")
    real = rclass.read

    def read(pipeline, conv_id):
        if conv_id == rows[0]["id"]:
            raise RuntimeError("boom")
        return real(pipeline, conv_id)

    monkeypatch.setattr(rclass, "read", read)
    assert worker.pipeline.reconcile_classes(T0 + 3600 + 450) == 1


def test_a_failed_conversation_refuses_a_class_change_with_a_way_forward(client, worker):
    worker.providers._llm = ScriptedLlm("media")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    worker.db.execute("UPDATE conversations SET status='failed' WHERE id=?", (row["id"],))
    r = choose(client, row["id"], "monologue", "r1", "2026-11-08T20:00:00Z")
    assert r.status_code == 409 and "retry" in r.text.lower()
    assert not (worker.pipeline.conv_dir(row["id"]) / "class.json").exists()


def test_requests_for_an_assistant_stay_apart_from_action_items_everywhere(client, worker, settings):
    worker.providers._llm = ScriptedLlm("conversation", ai_items=True)
    two_voices(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    summary = client.get(f"/v1/conversations/{row['id']}", headers=AUTH).json()["summary"]
    assert [a["description"] for a in summary["action_items"]] == ["Call the dentist"]
    assert [a["description"] for a in summary["assistant_requests"]] == ["Draft the hotel email"]
    assert "## Asked of an Assistant" in note_text(settings, row)


def test_a_passive_recording_has_no_requests_for_an_assistant_anywhere(client, worker, settings):
    worker.providers._llm = ScriptedLlm("media", ai_items=True)
    two_voices(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    summary = client.get(f"/v1/conversations/{row['id']}", headers=AUTH).json()["summary"]
    assert [a["description"] for a in summary["action_items"]] == ["Call the dentist"]
    assert summary["assistant_requests"] == []
    text = note_text(settings, row)
    assert "Draft the hotel email" not in text and "Draft the hotel email" not in row["index_json"]


# -- discards no class can change (Astra review of b6d8123) ---------------------------------------------------


def hand_written_choice(worker, conv_id: str, cls: str = "monologue", revision: int = 1) -> None:
    """A choice that reached the vault without the API's checks (written before the discard, or by sync)."""
    (worker.pipeline.conv_dir(conv_id) / "class.json").write_text(
        json.dumps({"format": 1, "class": cls, "revision": revision, "set_at": 1, "requests": []}))


def test_a_rule_discard_refuses_a_class_change_and_a_stored_choice_is_handled_once(client, worker, settings):
    from .test_pipeline import FillerStt
    from omi_notes.devtools import synth_speech_like

    worker.providers._stt = FillerStt()
    worker.providers._llm = llm = ScriptedLlm("conversation")
    replay(client, np.concatenate([np.zeros(SR, np.int16), synth_speech_like(5), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "discarded" and row["note_path"].startswith("_discarded/")
    r = choose(client, row["id"], "monologue", "r1", "2026-11-08T20:00:00Z")
    assert r.status_code == 409 and r.json()["error"] == "not_applicable", r.text
    assert not (worker.pipeline.conv_dir(row["id"]) / "class.json").exists()
    hand_written_choice(worker, row["id"])
    assert worker.pipeline.reconcile_classes(T0 + 450) == 1
    worker.tick(T0 + 460)
    (after,) = convs(worker)
    assert after["status"] == "discarded" and llm.calls == [], "the deterministic discard stands, without a summary"
    handled = json.loads(after["index_json"])["recording_class"]
    assert handled["revision"] == 1 and handled["outcome"] == "not_applicable" and handled.get("class") is None
    assert worker.pipeline.reconcile_classes(T0 + 500) == 0, "the owner's revision is recorded as handled: no loop"
    assert worker.pipeline.reconcile_classes(T0 + 600) == 0
    shown = listed(client)
    assert shown["updating"] is False and shown["class"] is None
    worker.pipeline.summarize_and_render(after["id"], T0 + 700, cache_only=True)
    assert worker.pipeline.reconcile_classes(T0 + 800) == 0, "a re-render keeps the handled revision"


def test_a_watch_alternate_handles_a_stored_choice_once(client, worker, settings):
    from .test_watch_sources import WATCH, by_device, heard_by_watch, run, talk
    from .helpers import live, silence

    speech = np.concatenate([silence(1), talk(45, 1), silence(2)])
    live(client, speech, offline_storage=False)
    replay(client, heard_by_watch(speech), start=STARTED + timedelta(seconds=4), source="watch_mic", device=WATCH)
    run(worker, T0 + 1200)
    _, (watch,) = by_device(worker)
    assert watch["status"] == "discarded"
    r = choose(client, watch["id"], "monologue", "r1", "2026-11-08T20:00:00Z")
    assert r.status_code == 409 and r.json()["error"] == "not_applicable", r.text
    hand_written_choice(worker, watch["id"], revision=3)
    assert worker.pipeline.reconcile_classes(T0 + 1300) == 1
    worker.tick(T0 + 1310)
    _, (after,) = by_device(worker)
    assert after["status"] == "discarded"
    assert json.loads(after["index_json"])["recording_class"]["revision"] == 3
    assert worker.pipeline.reconcile_classes(T0 + 1400) == 0


def test_a_choice_time_that_is_not_finite_or_not_a_date_is_unreadable_and_the_list_still_loads(client, worker):
    worker.providers._llm = ScriptedLlm("media")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    path = worker.pipeline.conv_dir(row["id"]) / "class.json"
    for bad in ("1e20", "Infinity", "1e300", "-Infinity"):
        path.write_text('{"format": 1, "class": "monologue", "revision": 1, "set_at": %s, "requests": []}' % bad)
        try:
            rclass.read(worker.pipeline, row["id"])
        except rclass.UnreadableChoice:
            pass
        else:
            raise AssertionError(f"set_at {bad} was read as a choice")
        r = client.get("/v1/conversations/recent", headers=AUTH)
        assert r.status_code == 200, (bad, r.text)
        assert r.json()["conversations"][0]["recording_class"]["choice_unreadable"]
        assert client.get(f"/v1/conversations/{row['id']}", headers=AUTH).status_code == 200
    assert worker.pipeline.reconcile_classes(T0 + 450) == 0
