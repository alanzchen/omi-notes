"""What kind of recording a conversation is: monologue (Alan talking alone: dictation, a thought dump for the
assistant), dialogue (Alan and at least one other real speaker) or passive (Alan absent: others talking,
background, videos). Each kind is treated differently (docs/architecture.md, "Recording classes").

`classify` is pure. Its input is per-label speech time (the union of the label's segment intervals) and the
wearer evidence for each label: named as the wearer (a user or automatic assignment), or a centred
voiceprint score against the wearer's centroid (`speakers.space`). A strong score counts as the wearer
(automatic naming is off while the person models fail their leave-one-out check; the centred score
separates Alan's dictation, 0.5-0.9, from other voices, about -0.5). When no label is the wearer, the one
label not clearly someone else is "possibly the wearer": if counting it would raise the class, the higher
class is taken with low confidence. Passive needs evidence of absence: every substantial voice scored as
clearly someone else, never just a missing identity.

The owner's choice (`<conversation dir>/class.json`, written atomically, deduplicated by `request_id`, the
later `set_at` wins, "auto" goes back to the automatic class) always wins. An unreadable file is an error,
never "no choice".
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime

from .ingest import ApiError
from .lock import SpeakerLock
from .util import iso_utc_epoch
from .vault import Vault
from .views import LISTED

RULE_VERSION = 2
CLASSES = ("monologue", "dialogue", "passive")
RANK = {"monologue": 0, "dialogue": 1, "passive": 2}  # also the summarizing priority
STRONG = 0.45  # centred wearer score counted as the wearer
NOT_WEARER = -0.20  # at or below: clearly someone else
MONOLOGUE_SHARE = 0.90
PASSIVE_SHARE = 0.05
OTHER_SHORT_S = 5.0  # a monologue allows one other voice this short (or 10% of the speech)
TRIVIAL_S = 1.0  # shorter voices don't count as another speaker
EVIDENCE_S = 3.0  # a voice at least this long without a score leaves the wearer's absence unproven
REQUEST_MEMORY = 50


@dataclass(frozen=True)
class Voice:
    label: str
    seconds: float
    named_wearer: bool = False
    named_other: bool = False  # assigned to someone who isn't the wearer
    score: float | None = None  # centred voiceprint score against the wearer; None: no usable voiceprint


def speech_seconds(segments: list[dict]) -> tuple[dict[str, float], float]:
    """Per-label speech time (union of its segments' intervals) and the conversation's (union of all)."""

    def union(spans: list[tuple[float, float]]) -> float:
        total, end = 0.0, float("-inf")
        for a, b in sorted(spans):
            if b <= end:
                continue
            total += b - max(a, end)
            end = b
        return total

    by: dict[str, list[tuple[float, float]]] = {}
    for seg in segments:
        a, b = float(seg["start"]), float(seg["end"])
        if b > a and str(seg.get("text", "")).strip():
            by.setdefault(seg["speaker"], []).append((a, b))
    return {label: union(spans) for label, spans in by.items()}, union([s for spans in by.values() for s in spans])


CONTENT_MONOLOGUE = ("dictation", "reflection")  # the summary's `interaction`: the owner talking alone
CONTENT_DIALOGUE = ("conversation", "call", "mixed")
CONTENT_PASSIVE = ("media",)  # a video, broadcast or background talk


def classify(voices: list[Voice], total: float, *, interaction: str | None = None, coarse_timing: bool = False) -> dict:
    """{class, confidence, wearer_share, wearer_s, total_s, version, reason} from two independent cues: the voices
    (a confirmed wearer's share of the speech) and the content (the summary's `interaction`). Measured on Alan's
    recordings (asr-backfill-20261108): a strong centred score is the wearer 88% of the time, but 23% of his own
    labels score as clearly someone else, so the voice can confirm the wearer and never prove him absent. The
    content judgement agrees with it closely (dictation: 20 of 23 with a strong wearer voice; media: none of 12).
    So passive needs the content to say media AND no confirmed wearer; a monologue needs either cue with no real
    second voice; anything else, or any disagreement, keeps the fuller treatment (dialogue)."""
    out = {"version": RULE_VERSION, "total_s": round(total, 1), "interaction": interaction}
    if total <= 0:
        return out | {"class": "dialogue", "confidence": "low", "wearer_share": 0.0, "wearer_s": 0.0, "reason": "no speech"}
    people = [v for v in voices if v.label != "unknown"]
    wearer = [v for v in people if v.named_wearer or (v.score is not None and v.score >= STRONG and not v.named_other)]
    wearer_s = sum(v.seconds for v in wearer)
    share = wearer_s / total
    real = sorted((v for v in people if v.seconds >= TRIVIAL_S), key=lambda v: -v.seconds)
    # one real voice, or a second one too short to be another speaker in this exchange
    alone = len(real) <= 1 or (len(real) == 2 and real[1].seconds <= max(OTHER_SHORT_S, 0.1 * total))
    voice = "monologue" if share >= MONOLOGUE_SHARE and alone else ("dialogue" if share >= PASSIVE_SHARE else None)
    content = ("monologue" if interaction in CONTENT_MONOLOGUE else "passive" if interaction in CONTENT_PASSIVE
               else "dialogue" if interaction in CONTENT_DIALOGUE else None)  # fmt: skip
    # a single voice that isn't clearly someone else, whatever the content says: borderline keeps the higher class
    lone_maybe = alone and bool(real) and not real[0].named_other and real[0].score is not None and real[0].score > NOT_WEARER
    if voice == "monologue" or (content == "monologue" and alone) or (lone_maybe and content != "passive"):
        final = "monologue"
    elif content == "passive" and share < PASSIVE_SHARE:
        final = "passive"
    else:
        final = "dialogue"
    unclear = [v for v in people if not v.named_other and (v.score is None or v.score > NOT_WEARER) and v not in wearer
               and v.seconds >= EVIDENCE_S]  # fmt: skip
    if final == "monologue":
        agree = voice == "monologue" and content in ("monologue", None)
    elif final == "passive":
        agree = not unclear  # every substantial voice also sounds like someone else
    else:
        agree = (content == "dialogue" or content is None) and (voice == "dialogue")
    conflict = (content is not None and voice is not None and content != voice) or (content == "monologue" and voice is None
               and any(v.score is not None and v.score <= NOT_WEARER for v in real))  # fmt: skip
    conflict = conflict or (final == "monologue" and voice != "monologue" and content != "monologue")
    confidence = "low" if conflict or content is None and voice is None else ("high" if agree else "medium")
    if coarse_timing and confidence == "high":  # old text-only transcripts: window-sized timings
        confidence = "medium"
    reason = f"wearer {wearer_s:.0f} s of {total:.0f} s by voice; content: {interaction or 'unknown'}"
    return out | {"class": final, "confidence": confidence, "wearer_share": round(share, 3), "wearer_s": round(wearer_s, 1),
                  "reason": reason}  # fmt: skip


def effective(auto: dict | None, override: dict | None) -> dict:
    """What the conversation is treated as: the owner's choice when there is one, else the automatic class."""
    auto = auto or {}
    chosen = (override or {}).get("class")
    if chosen in CLASSES:
        return {"class": chosen, "auto": auto.get("class"), "confidence": "owner", "overridden": True,
                "wearer_share": auto.get("wearer_share"), "revision": override.get("revision", 0)}  # fmt: skip
    return {"class": auto.get("class"), "auto": auto.get("class"), "confidence": auto.get("confidence"), "overridden": False,
            "wearer_share": auto.get("wearer_share"), "revision": (override or {}).get("revision", 0)}  # fmt: skip


# -- the owner's choice ----------------------------------------------------------------------------


class UnreadableChoice(RuntimeError):
    """class.json exists but can't be read: never treated as "no choice"."""


def _path(pipeline, conv_id: str):
    return pipeline.conv_dir(conv_id) / "class.json"


def read(pipeline, conv_id: str) -> dict | None:
    path = _path(pipeline, conv_id)
    if not path.exists():
        return None
    try:
        data = Vault.read_json(path)
    except (OSError, ValueError) as exc:
        raise UnreadableChoice(f"{path.name} of {conv_id} can't be read: {exc}") from exc
    if not isinstance(data, dict) or data.get("class") not in (*CLASSES, "auto"):
        raise UnreadableChoice(f"{path.name} of {conv_id} has no valid class")
    return data


def put(pipeline, conv_id: str, body: dict, auto: dict | None) -> dict:
    """`PUT /v1/conversations/{id}/class` {class: monologue|dialogue|passive|auto, request_id, set_at}."""
    chosen, request_id, set_at = body.get("class"), body.get("request_id"), body.get("set_at")
    if chosen not in (*CLASSES, "auto"):
        raise ApiError(422, "invalid_body", "class must be monologue, dialogue, passive or auto")
    if not isinstance(request_id, str) or not request_id or len(request_id) > 100:
        raise ApiError(422, "invalid_body", "request_id is required")
    try:
        when = datetime.fromisoformat(str(set_at).replace("Z", "+00:00"))
        if when.tzinfo is None:
            raise ValueError
    except ValueError as exc:
        raise ApiError(422, "invalid_body", "set_at must be an ISO-8601 time with a timezone") from exc
    row = pipeline.db.one(f"SELECT status FROM conversations WHERE id=? AND {LISTED}", (conv_id,))
    if row is None:
        raise ApiError(404, "not_found", "unknown conversation")
    if row["status"] == "open":
        raise ApiError(409, "in_progress", "the conversation is still being recorded")
    when_epoch = when.astimezone(UTC).timestamp()
    with SpeakerLock(pipeline.vault, name="class.lock"):
        try:
            current = read(pipeline, conv_id) or {"format": 1, "class": "auto", "revision": 0, "set_at": 0, "requests": []}
        except UnreadableChoice as exc:
            raise ApiError(409, "unreadable", str(exc)) from exc
        if request_id in current.get("requests", []):
            return view(current, auto, applied=True)
        if when_epoch <= float(current.get("set_at") or 0):
            return view(current, auto, applied=False)  # an older choice than the stored one: the newer stands
        data = {"format": 1, "class": chosen, "set_at": when_epoch, "revision": int(current.get("revision", 0)) + 1,
                "request_id": request_id, "requests": (list(current.get("requests", [])) + [request_id])[-REQUEST_MEMORY:],
                "source": "app",
                # what the automatic rule said when the owner chose: training evidence for the thresholds
                "auto_at_choice": {k: (auto or {}).get(k) for k in ("class", "confidence", "wearer_share", "version")}}  # fmt: skip
        Vault.write_json(_path(pipeline, conv_id), data)
        return view(data, auto, applied=True)


def view(override: dict | None, auto: dict | None, *, applied: bool | None = None) -> dict:
    out = effective(auto, override)
    if override and override.get("set_at"):
        out["set_at"] = iso_utc_epoch(override["set_at"])
    return out if applied is None else out | {"applied": applied}
