"""`ConversationNotes`: the LLM's structured output, parsed leniently.

Lesson from Omi (`backend/models/structured_extraction.py`): one malformed optional element must
never cost the whole note. Unusable list elements are dropped, out-of-vocabulary enum values are
coerced, and missing scalars get defaults.
"""

from __future__ import annotations

import logging
from datetime import date
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator

log = logging.getLogger(__name__)

CATEGORIES = (
    "personal", "education", "health", "finance", "legal", "philosophy", "spiritual", "science",
    "entrepreneurship", "parenting", "romantic", "travel", "inspiration", "technology", "business",
    "social", "work", "sports", "politics", "literature", "history", "architecture", "music",
    "weather", "news", "entertainment", "psychology", "real", "design", "family", "economics",
    "environment", "other",
)  # fmt: skip  (Omi's CategoryEnum)

Owner = Literal["me", "other", "unknown"]

# What kind of recording it seems to be (a hint, never a verdict about who took part).
INTERACTIONS = ("conversation", "dictation", "reflection", "call", "media", "mixed", "unknown")
# How worth revisiting it is for the owner, as judged from this conversation alone.
VALUE_LEVELS = ("high", "normal", "low", "unknown")
MAX_HIGHLIGHTS = 3


class Section(BaseModel):
    model_config = ConfigDict(extra="ignore")
    heading: str
    bullets: list[str] = Field(default_factory=list)

    @field_validator("bullets", mode="before")
    @classmethod
    def _strings(cls, value: Any) -> Any:
        return [b for b in value if isinstance(b, str) and b.strip()] if isinstance(value, list) else value


class ActionItem(BaseModel):
    model_config = ConfigDict(extra="ignore")
    description: str = Field(min_length=1)
    owner: Owner = "unknown"
    owner_name: str | None = None
    due_date: date | None = None
    context: str | None = None
    # an instruction or draft addressed to an AI assistant, not something the owner committed to
    directed_at_ai: bool = False

    @model_validator(mode="before")
    @classmethod
    def _coerce(cls, data: Any) -> Any:
        if not isinstance(data, dict):
            return data
        data = dict(data)
        owner = data.get("owner")
        if isinstance(owner, str) and owner.strip().lower() in ("me", "other", "unknown"):
            data["owner"] = owner.strip().lower()
        elif isinstance(owner, str) and owner.strip():
            # A name where an owner class belongs still says "somebody other than the owner".
            data.setdefault("owner_name", owner.strip())
            data["owner"] = "other"
        else:
            data["owner"] = "unknown"
        if not isinstance(data.get("directed_at_ai", False), bool):
            data["directed_at_ai"] = False
        due = data.get("due_date")
        if due is not None:
            try:
                data["due_date"] = date.fromisoformat(str(due)[:10])
            except ValueError:
                data["due_date"] = None
        return data


class Value(BaseModel):
    """Personal informational value (prompt v3+). Absent on older summaries: "legacy", not low."""

    model_config = ConfigDict(extra="ignore")
    level: str = "unknown"
    reasons: list[str] = Field(default_factory=list)

    @model_validator(mode="before")
    @classmethod
    def _coerce(cls, data: Any) -> Any:
        if not isinstance(data, dict):
            return {"level": "unknown"}
        data = dict(data)
        level = data.get("level")
        data["level"] = level.strip().lower() if isinstance(level, str) and level.strip().lower() in VALUE_LEVELS else "unknown"
        reasons = data.get("reasons")
        data["reasons"] = [r.strip() for r in reasons if isinstance(r, str) and r.strip()][:2] if isinstance(reasons, list) else []
        return data


class Highlight(BaseModel):
    """A span worth revisiting, grounded in transcript segments (indices as numbered in the prompt)."""

    model_config = ConfigDict(extra="ignore")
    title: str = Field(min_length=1)
    why: str = ""
    first_segment: int | None = None
    last_segment: int | None = None

    @field_validator("first_segment", "last_segment", mode="before")
    @classmethod
    def _index(cls, value: Any) -> Any:
        return value if isinstance(value, int) and not isinstance(value, bool) else None


class CalendarEvent(BaseModel):
    model_config = ConfigDict(extra="ignore")
    title: str = Field(min_length=1)
    start_local_iso: str | None = None
    duration_min: int | None = Field(default=None, ge=1, le=24 * 60)

    @field_validator("duration_min", mode="before")
    @classmethod
    def _duration(cls, value: Any) -> Any:
        return value if isinstance(value, int) and 1 <= value <= 24 * 60 else None


class Person(BaseModel):
    model_config = ConfigDict(extra="ignore")
    name: str = Field(min_length=1)
    note: str = ""


_ELEMENT_MODELS: dict[str, type[BaseModel]] = {
    "sections": Section,
    "action_items": ActionItem,
    "events": CalendarEvent,
    "people": Person,
    "highlights": Highlight,
}
_STRING_LISTS = ("decisions", "open_questions", "memorable_facts", "tags")


class ConversationNotes(BaseModel):
    model_config = ConfigDict(extra="ignore")

    keep: bool = True
    discard_reason: str | None = None
    title: str = ""
    emoji: str = ""
    category: str = "other"
    overview: str = ""
    sections: list[Section] = Field(default_factory=list)
    action_items: list[ActionItem] = Field(default_factory=list)
    decisions: list[str] = Field(default_factory=list)
    open_questions: list[str] = Field(default_factory=list)
    events: list[CalendarEvent] = Field(default_factory=list)
    people: list[Person] = Field(default_factory=list)
    memorable_facts: list[str] = Field(default_factory=list)
    speaker_names: dict[str, str] = Field(default_factory=dict)
    tags: list[str] = Field(default_factory=list)
    # prompt v3+: None on older summaries (shown as legacy, never guessed)
    interaction: str | None = None
    value: Value | None = None
    highlights: list[Highlight] = Field(default_factory=list)

    @model_validator(mode="before")
    @classmethod
    def _keep_usable(cls, data: Any) -> Any:
        if not isinstance(data, dict):
            return data
        data = dict(data)
        for key in ("title", "emoji", "overview", "discard_reason", "category"):
            if key in data and not isinstance(data[key], str):
                data.pop(key)
        if not isinstance(data.get("keep", True), bool):
            data.pop("keep")
        for key, model in _ELEMENT_MODELS.items():
            values = data.get(key)
            if values is None:
                data.pop(key, None)
                continue
            if not isinstance(values, list):
                data.pop(key)
                continue
            usable = []
            for element in values:
                try:
                    usable.append(model.model_validate(element))
                except ValidationError as exc:
                    log.warning("dropping unusable %s element: %s", key, [e["type"] for e in exc.errors()])
            data[key] = usable
        for key in _STRING_LISTS:
            values = data.get(key)
            data[key] = [v.strip() for v in values if isinstance(v, str) and v.strip()] if isinstance(values, list) else []
        data["memorable_facts"] = data["memorable_facts"][:3]
        if "highlights" in data:
            data["highlights"] = data["highlights"][:MAX_HIGHLIGHTS]
        interaction = data.get("interaction")
        if interaction is not None:
            interaction = interaction.strip().lower() if isinstance(interaction, str) else "unknown"
            data["interaction"] = interaction if interaction in INTERACTIONS else "unknown"
        names = data.get("speaker_names")
        mapping: dict[str, str] = {}
        if isinstance(names, dict):
            mapping = {str(k): v.strip() for k, v in names.items() if isinstance(v, str) and v.strip()}
        elif isinstance(names, list):  # the structured-output schema uses [{label, name}]
            for item in names:
                if isinstance(item, dict) and isinstance(item.get("label"), str) and isinstance(item.get("name"), str):
                    if item["name"].strip():
                        mapping[item["label"].strip()] = item["name"].strip()
        data["speaker_names"] = mapping
        return data

    @field_validator("category", mode="after")
    @classmethod
    def _category(cls, value: str) -> str:
        value = value.strip().lower()
        return value if value in CATEGORIES else "other"

    @field_validator("title", "overview", "emoji", mode="after")
    @classmethod
    def _strip(cls, value: str) -> str:
        return value.strip()


def _nullable(schema: dict) -> dict:
    return {"anyOf": [schema, {"type": "null"}]}


def _obj(properties: dict[str, dict]) -> dict:
    return {
        "type": "object",
        "properties": properties,
        "required": list(properties),
        "additionalProperties": False,
    }


_STR = {"type": "string"}
_STR_LIST = {"type": "array", "items": _STR}

# Structured-output schema sent to the API. Kept to the widely supported JSON Schema subset
# (every object closed, every property required, optionals expressed as nullable).
NOTES_JSON_SCHEMA: dict = _obj(
    {
        "keep": {"type": "boolean"},
        "discard_reason": _nullable(_STR),
        "title": _STR,
        "emoji": _STR,
        "category": {"type": "string", "enum": list(CATEGORIES)},
        "overview": _STR,
        "sections": {"type": "array", "items": _obj({"heading": _STR, "bullets": _STR_LIST})},
        "action_items": {
            "type": "array",
            "items": _obj(
                {
                    "description": _STR,
                    "owner": {"type": "string", "enum": ["me", "other", "unknown"]},
                    "owner_name": _nullable(_STR),
                    "due_date": _nullable({"type": "string", "description": "YYYY-MM-DD"}),
                    "context": _nullable(_STR),
                    "directed_at_ai": {"type": "boolean"},
                }
            ),
        },
        "decisions": _STR_LIST,
        "open_questions": _STR_LIST,
        "events": {
            "type": "array",
            "items": _obj(
                {
                    "title": _STR,
                    "start_local_iso": _nullable(_STR),
                    "duration_min": _nullable({"type": "integer"}),
                }
            ),
        },
        "people": {"type": "array", "items": _obj({"name": _STR, "note": _STR})},
        "memorable_facts": _STR_LIST,
        "speaker_names": {"type": "array", "items": _obj({"label": _STR, "name": _STR})},
        "tags": _STR_LIST,
        "interaction": {"type": "string", "enum": list(INTERACTIONS)},
        "value": _obj({"level": {"type": "string", "enum": list(VALUE_LEVELS)}, "reasons": _STR_LIST}),
        "highlights": {
            "type": "array",
            "items": _obj({"title": _STR, "why": _STR, "first_segment": {"type": "integer"},
                           "last_segment": {"type": "integer"}}),  # fmt: skip
        },
    }
)
