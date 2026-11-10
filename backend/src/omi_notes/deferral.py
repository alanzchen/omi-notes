"""Short sessions deferred (docs/architecture.md, "Deferred short sessions"; docs/vault.md, "deferral").

A conversation with under `DEFER_SPEECH_SECONDS` (60 s) of detected speech is not transcribed by default. The
decision is made once, when segmentation finalizes the conversation (after the usual coverage-aware closure: the
120 s gap, provisional closure and late audio are unchanged, and a short session is never taken as a sign that
anything ended), and written into its `conversation.json` as `deferral`:

    {"policy": "short_speech", "threshold_s": 60.0, "speech_s": 23.4, "decided_at": <epoch>,
     "provisional": {"class": "undetermined", "confidence": null, "rule_id": "none-v1", "model": null},
     "requested": {"op": <operation id>, "at": <epoch>}}          # only once the owner asked

The lifecycle status stays `closed`. A deferred conversation is transcribed by the lowest-priority lane, only when
nothing else is runnable (`pipeline.run`), or at normal priority once the owner asks
(`POST /v1/conversations/{id}/transcribe`, an operation like a retry). Its raw audio is kept like all audio. Voice
enrollments and recordings under 1.5 s (set aside without a note) are never deferred.

`provisional_class` is the one place a transcription-free classifier plugs in. Until there is one it answers
`undetermined`: missing evidence is never `passive`.
"""

from __future__ import annotations

import json

POLICY = "short_speech"
VAULT_FORMAT = 7  # raised before the first `deferral` block or `transcribe` operation is written (6 is the Voices release's)
UNDETERMINED = "undetermined"
RULE_NONE = "none-v1"  # no transcription-free classifier yet
# The identity of the model a provisional rule depends on (e.g. the wearer's voice model: a rule like "monologue only
# if the wearer's voice share is high, the SNR good and there is one voice" is only as good as that model). None: the
# rule uses no model. A rule that does records it, so a recalibrated voice model can tell which decisions to redo.
PROVISIONAL_MODEL: str | None = None


def provisional_class(features: dict) -> tuple[str, str | None, str]:
    """(class, confidence, rule_id) for a conversation nobody has transcribed yet, from transcription-free features
    (speech seconds, and whatever a later classifier reads). Without a classifier, or without enough evidence, the
    answer is `undetermined` (never `passive`: a quiet recording isn't proof the owner was absent; a short clip is
    never called passive or dialogue). The block records `PROVISIONAL_MODEL` with the rule."""
    del features
    return UNDETERMINED, None, RULE_NONE


def decide(threshold_s: float, speech_s: float, now: float, *, too_short_s: float) -> dict | None:
    """The deferral block for a conversation being finalized, or None when it is processed normally."""
    if threshold_s <= 0 or speech_s >= threshold_s or speech_s < too_short_s:
        return None  # long enough, the policy is off, or set aside as too short (its own rule, unchanged)
    cls, confidence, rule = provisional_class({"speech_s": speech_s})
    return {"policy": POLICY, "threshold_s": float(threshold_s), "speech_s": round(float(speech_s), 3), "decided_at": now,
            "provisional": {"class": cls, "confidence": confidence, "rule_id": rule, "model": PROVISIONAL_MODEL}}  # fmt: skip


def block(row) -> dict | None:
    """The row's deferral block (index column `deferral`), or None."""
    try:
        raw = row["deferral"]
    except (KeyError, IndexError):
        return None
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except (TypeError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def requested_op(row) -> str | None:
    """The owner's transcription request: committed into the record, or accepted and not yet committed."""
    data = block(row) or {}
    committed = (data.get("requested") or {}).get("op") if isinstance(data.get("requested"), dict) else None
    try:
        pending = row["transcribe_op"]
    except (KeyError, IndexError):
        pending = None
    return committed or pending


def waiting(row) -> bool:
    """Deferred and still without a result: not asked for, no note yet, no app retry. Such a row is claimed only by
    the idle lane (its summary too), and shown as deferred. Once it has a note it is never deferred again (a later
    reprocess is an ordinary re-run)."""
    return (block(row) is not None and row["status"] in ("closed", "transcribing", "summarizing") and not row["note_path"]
            and not row["retry_op"] and requested_op(row) is None)  # fmt: skip


# Rows `waiting` selects, as SQL (the same predicate; `queue_counts` and the backfill driver use it).
WAITING_SQL = ("(deferral IS NOT NULL AND status IN ('closed','transcribing','summarizing') AND note_path IS NULL "
               "AND retry_op IS NULL AND transcribe_op IS NULL AND json_extract(deferral, '$.requested') IS NULL)")


def provisional_view(row, choice: dict | None) -> dict | None:
    """What the phone shows for a deferred conversation's kind before any summary: the owner's choice when there is
    one (it is applied by the first summary, which reads `class.json`), else the provisional class."""
    data = block(row)
    if data is None or row["note_path"]:
        return None
    provisional = data.get("provisional") or {}
    chosen = (choice or {}).get("class")
    if chosen in ("monologue", "dialogue", "passive"):
        return {"class": chosen, "auto": provisional.get("class"), "confidence": "owner", "overridden": True,
                "provisional": True, "rule_id": provisional.get("rule_id"), "model": provisional.get("model")}  # fmt: skip
    return {"class": provisional.get("class") or UNDETERMINED, "auto": provisional.get("class"),
            "confidence": provisional.get("confidence"), "overridden": False, "provisional": True,
            "rule_id": provisional.get("rule_id"), "model": provisional.get("model")}  # fmt: skip
