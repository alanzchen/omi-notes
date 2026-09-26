from datetime import date

from omi_notes.notes.schema import NOTES_JSON_SCHEMA, ConversationNotes


def test_full_valid_payload():
    notes = ConversationNotes.model_validate(
        {
            "keep": True,
            "discard_reason": None,
            "title": " Team Finalizes Q2 Budget ",
            "emoji": "💰",
            "category": "Work",
            "overview": "They agreed on the budget.",
            "sections": [{"heading": "Budget", "bullets": ["Agreed on 120k.", ""]}],
            "action_items": [{"description": "Send the budget", "owner": "me", "owner_name": None,
                              "due_date": "2026-10-01", "context": None}],  # fmt: skip
            "decisions": ["Budget approved"],
            "open_questions": [],
            "events": [{"title": "Review", "start_local_iso": "2026-10-02T10:00", "duration_min": 30}],
            "people": [{"name": "Priya", "note": "owns analytics"}],
            "memorable_facts": ["a", "b", "c", "d"],
            "speaker_names": [{"label": "S2", "name": "Priya"}, {"label": "S1", "name": " "}],
            "tags": ["budget"],
        }
    )
    assert notes.title == "Team Finalizes Q2 Budget" and notes.category == "work"
    assert notes.sections[0].bullets == ["Agreed on 120k."]
    assert notes.action_items[0].due_date == date(2026, 10, 1)
    assert notes.memorable_facts == ["a", "b", "c"]
    assert notes.speaker_names == {"S2": "Priya"}


def test_bad_elements_are_dropped_not_fatal():
    notes = ConversationNotes.model_validate(
        {
            "title": "Ok",
            "sections": [{"heading": "fine", "bullets": ["x"]}, {"bullets": ["no heading"]}, "junk"],
            "action_items": [
                {"description": "Call Sam", "owner": "Priya"},  # a name where the enum belongs
                {"description": "", "owner": "me"},  # empty description → dropped
                {"description": "Pay rent", "owner": "ME", "due_date": "next friday"},  # unparseable date → None
            ],
            "events": [{"title": "Lunch", "duration_min": 0}, {"start_local_iso": "x"}],
            "people": [{"name": "Priya"}, {"note": "nameless"}],
            "decisions": ["ok", 3, None],
            "category": "not-a-category",
            "speaker_names": {"S1": "Tom", "S2": 5},
            "emoji": None,
        }
    )
    assert [s.heading for s in notes.sections] == ["fine"]
    assert [(a.description, a.owner, a.owner_name, a.due_date) for a in notes.action_items] == [
        ("Call Sam", "other", "Priya", None),
        ("Pay rent", "me", None, None),
    ]
    assert [(e.title, e.duration_min) for e in notes.events] == [("Lunch", None)]
    assert [p.name for p in notes.people] == ["Priya"]
    assert notes.decisions == ["ok"]
    assert notes.category == "other" and notes.emoji == "" and notes.speaker_names == {"S1": "Tom"}


def test_empty_and_garbage_inputs():
    assert ConversationNotes.model_validate({}).keep is True
    notes = ConversationNotes.model_validate({"keep": "yes", "sections": {"not": "a list"}, "tags": "x"})
    assert notes.keep is True and notes.sections == [] and notes.tags == []


def test_structured_output_schema_is_closed_and_complete():
    def walk(schema):
        if schema.get("type") == "object":
            assert schema["additionalProperties"] is False
            assert set(schema["required"]) == set(schema["properties"])
            for sub in schema["properties"].values():
                walk(sub)
        for key in ("items",):
            if key in schema:
                walk(schema[key])
        for option in schema.get("anyOf", []):
            walk(option)

    walk(NOTES_JSON_SCHEMA)
    assert set(NOTES_JSON_SCHEMA["properties"]) >= set(ConversationNotes.model_fields)
