"""Recording classes in the pipeline: the summary's content cue, monologue and passive treatment, the owner's
choice through the API, daily notes and the list filter. Fakes only."""

from __future__ import annotations

import numpy as np

from omi_notes.providers import LlmResult
from omi_notes.providers.fake import FakeLlm

from .conftest import AUTH
from .helpers import T0, convs, note_text, replay
from .test_speaker_learning import ALAN, voice

SR = 16000


class ScriptedLlm(FakeLlm):
    """The fake summary with a chosen `interaction` and keep; asked for a monologue, it writes a cleaned text."""

    def __init__(self, interaction: str, keep: bool = True):
        self.interaction, self.keep, self.calls = interaction, keep, []

    def summarize(self, request):
        self.calls.append(request.user)
        result = super().summarize(request)
        data = dict(result.data, interaction=self.interaction, keep=self.keep,
                    discard_reason=None if self.keep else "a short request to an assistant")  # fmt: skip
        if "Recording kind: MONOLOGUE" in request.user:
            data["sections"] = [{"heading": "Cleaned text", "bullets": ["Book the Lisbon hotel for the conference."]},
                                {"heading": "Tasks", "bullets": ["Hotel booking"]}]  # fmt: skip
        return LlmResult(data=data, model=self.model)


def one_voice(client, seconds: float = 8.0):
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(seconds, ALAN, 7), np.zeros(3 * SR, np.int16)]))


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


def test_media_without_alan_is_a_brief_passive_note_with_the_transcript_folded(client, worker, settings):
    worker.providers._llm = ScriptedLlm("media")
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(6, 210, 1), np.zeros(SR, np.int16), voice(6, 300, 2),
                                   np.zeros(3 * SR, np.int16)]))  # fmt: skip
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    text = note_text(settings, row)
    assert row["status"] == "done" and "recording_class: passive" in text
    assert "> [!quote]- Transcript" in text and "## Key Points" not in text
    assert "Review the fake transcript" not in text, "no action items unless addressed to the owner"
    daily = next((settings.vault_dir / "Daily").glob("*.md")).read_text()
    assert "## Background" in daily and "Review the fake transcript" not in daily


def test_the_owners_choice_reclassifies_and_resummarizes(client, worker, settings):
    worker.providers._llm = ScriptedLlm("media")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    body = {"class": "monologue", "request_id": "r1", "set_at": "2026-11-08T20:00:00Z"}
    r = client.put(f"/v1/conversations/{row['id']}/class", json=body, headers=AUTH)
    assert r.status_code == 200 and r.json()["class"] == "monologue" and r.json()["applied"] is True
    listed = client.get("/v1/conversations/recent", headers=AUTH).json()["conversations"][0]["recording_class"]
    assert listed["updating"] is True
    worker.tick(T0 + 500)
    worker.tick(T0 + 510)
    (row,) = convs(worker)
    assert "recording_class: monologue" in note_text(settings, row)
    listed = client.get("/v1/conversations/recent", headers=AUTH).json()["conversations"][0]["recording_class"]
    assert listed["class"] == "monologue" and listed["overridden"] is True and listed["updating"] is False
    assert client.put(f"/v1/conversations/{row['id']}/class", json=body, headers=AUTH).json()["applied"] is True, "a repeat"
    old = {"class": "passive", "request_id": "r0", "set_at": "2026-11-08T19:00:00Z"}
    assert client.put(f"/v1/conversations/{row['id']}/class", json=old, headers=AUTH).json()["applied"] is False


def test_the_list_filters_by_class_before_paging(client, worker):
    worker.providers._llm = ScriptedLlm("dictation")
    one_voice(client)
    worker.tick(T0 + 400)
    ok = client.get("/v1/conversations/recent?class=monologue", headers=AUTH).json()["conversations"]
    none = client.get("/v1/conversations/recent?class=passive", headers=AUTH).json()["conversations"]
    assert len(ok) == 1 and none == []
    assert client.get("/v1/conversations/recent?class=junk", headers=AUTH).status_code == 422
    assert "recording_class" in client.get("/v1/status", headers=AUTH).json()["features"]


def test_an_unreadable_choice_is_an_error_not_no_choice(client, worker, settings):
    worker.providers._llm = ScriptedLlm("dictation")
    one_voice(client)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    (worker.pipeline.conv_dir(row["id"]) / "class.json").write_text("{not json")
    body = {"class": "dialogue", "request_id": "r1", "set_at": "2026-11-08T20:00:00Z"}
    assert client.put(f"/v1/conversations/{row['id']}/class", json=body, headers=AUTH).status_code == 409
