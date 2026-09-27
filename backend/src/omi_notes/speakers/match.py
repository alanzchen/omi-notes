"""Who is speaking (pure; docs/speaker-learning.md, "Matching").

- A person's voice model is the normalized centroid of their *confirmed* samples only (enrollment
  and user assignments, newest 20); automatic matches never become samples, so models don't drift.
- A label is accepted for a person iff its cosine distance to that model is < 0.50, the runner-up
  is at least 0.10 further, the evidence is ≥ 5 s from ≥ 2 clean turns, and the label isn't mixed
  (Omi's pooled operating points — priors, recalibrated by `omi-notes speakers bench`).
- Automatic naming applies to a person only once they are *active*: ≥ 3 confirmed samples beyond
  enrollment, from ≥ 2 sessions on different days, and every sample matches the centroid of the
  others within threshold and margin (leave-one-out). Enrollment alone never activates.
- `source: user` assignments are sticky; `not` blocks a person for that label. Several labels may
  map to one person (diarization over-splits), but only when they are about as close: within one
  conversation the closest label is the runner-up for the others (margin 0.10).
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .voices import centroid, cosine_distance

THRESHOLD = 0.50
MARGIN = 0.10
MIN_EVIDENCE = 5.0
MIN_TURNS = 2
SAMPLE_CAP = 20
ACTIVE_SAMPLES = 3
ACTIVE_DAYS = 2
CONFIRMED = ("enrollment", "user")


@dataclass(frozen=True)
class Operating:
    threshold: float = THRESHOLD
    margin: float = MARGIN
    min_evidence: float = MIN_EVIDENCE
    min_turns: int = MIN_TURNS


@dataclass
class Sample:
    id: str
    person_id: str
    vector: np.ndarray
    source: str  # enrollment | user
    day: str | None = None  # local date of the audio
    session: str | None = None  # conversation or enrollment id
    created_at: float = 0.0


@dataclass
class PersonModel:
    id: str
    centroid: np.ndarray | None
    samples: list[Sample] = field(default_factory=list)
    active: bool = False
    why_inactive: str = ""


@dataclass(frozen=True)
class Match:
    person_id: str | None
    distance: float | None
    margin: float | None  # runner-up distance minus best distance (None: no runner-up)
    accepted: bool
    reason: str = ""


def confirmed(samples: list[Sample]) -> list[Sample]:
    """The newest SAMPLE_CAP confirmed samples."""
    keep = [s for s in samples if s.source in CONFIRMED]
    return sorted(keep, key=lambda s: (s.created_at, s.id))[-SAMPLE_CAP:]


def build_models(samples: list[Sample], op: Operating = Operating()) -> dict[str, PersonModel]:
    by_person: dict[str, list[Sample]] = {}
    for s in samples:
        by_person.setdefault(s.person_id, []).append(s)
    models = {}
    for pid, items in by_person.items():
        chosen = confirmed(items)
        models[pid] = PersonModel(pid, centroid([s.vector for s in chosen]) if chosen else None, chosen)
    for model in models.values():
        model.active, model.why_inactive = activation(model, models, op)
    return models


def activation(model: PersonModel, models: dict[str, PersonModel], op: Operating = Operating()) -> tuple[bool, str]:
    beyond = [s for s in model.samples if s.source != "enrollment"]
    sessions_by_day: dict[str | None, set[str | None]] = {}
    for s in beyond:
        sessions_by_day.setdefault(s.day, set()).add(s.session)
    if len(beyond) < ACTIVE_SAMPLES:
        return False, f"needs {ACTIVE_SAMPLES} confirmed samples beyond enrollment ({len(beyond)} so far)"
    if len([d for d in sessions_by_day if d]) < ACTIVE_DAYS:
        return False, f"needs samples from {ACTIVE_DAYS} different days"
    others = [m for m in models.values() if m.id != model.id and m.centroid is not None]
    for sample in model.samples:
        rest = [s.vector for s in model.samples if s is not sample]
        if not rest:
            return False, "needs more samples"
        own = cosine_distance(sample.vector, centroid(rest))
        best_other = min((cosine_distance(sample.vector, m.centroid) for m in others), default=None)
        if own >= op.threshold or (best_other is not None and best_other - own < op.margin):
            return False, "leave-one-out check failed: a sample does not match the others"
    return True, ""


def best_match(vector: np.ndarray, models: dict[str, PersonModel], exclude: set[str] = frozenset()) -> tuple[str | None, float | None, float | None]:
    scored = sorted(
        (cosine_distance(vector, m.centroid), pid) for pid, m in models.items() if m.centroid is not None and pid not in exclude
    )
    if not scored:
        return None, None, None
    best, runner = scored[0], (scored[1][0] if len(scored) > 1 else None)
    return best[1], best[0], (None if runner is None else runner - best[0])


def match(voice, models: dict[str, PersonModel], exclude: set[str] = frozenset(), op: Operating = Operating()) -> Match:
    """`voice`: anything with `vector`, `seconds`, `turns`, `mixed`."""
    if voice is None or voice.vector is None:
        return Match(None, None, None, False, "no voice")
    pid, distance, margin = best_match(voice.vector, models, exclude)
    if pid is None:
        return Match(None, None, None, False, "nobody to compare with")
    reasons = []
    if distance >= op.threshold:
        reasons.append(f"distance {distance:.2f} ≥ {op.threshold}")
    if margin is not None and margin < op.margin:
        reasons.append(f"runner-up margin {margin:.2f} < {op.margin}")
    if voice.seconds < op.min_evidence or voice.turns < op.min_turns:
        reasons.append(f"evidence {voice.seconds:.1f} s from {voice.turns} turns")
    if voice.mixed:
        reasons.append("mixed voices under one label")
    return Match(pid, round(distance, 4), None if margin is None else round(margin, 4), not reasons, "; ".join(reasons))


def assign(voices: dict[str, object], current: dict[str, dict], models: dict[str, PersonModel], *, auto_assign: bool,
           op: Operating = Operating()) -> dict[str, dict]:  # fmt: skip
    """Label states after (re)assignment. User assignments and `not` lists are kept; automatic
    ones are recomputed from the stored voices (only for active people, when auto naming is on)."""
    out: dict[str, dict] = {}
    for label in sorted(set(voices) | set(current), key=_label_key):
        state = dict(current.get(label) or {})
        blocked = set(state.get("not") or [])
        if state.get("source") == "user" and state.get("person_id"):
            out[label] = state
            continue
        found = match(voices.get(label), models, blocked, op)
        fresh = {"person_id": None, "source": None, "distance": found.distance, "margin": found.margin,
                 "evidence_s": getattr(voices.get(label), "seconds", None), "not": sorted(blocked)}  # fmt: skip
        model = models.get(found.person_id) if found.person_id else None
        if auto_assign and found.accepted and model is not None and model.active:
            fresh |= {"person_id": found.person_id, "source": "auto"}
        out[label] = fresh
    # The diarizer already heard these labels as different voices, so the closest label to a person
    # is the runner-up for the others: another label keeps the name only if it is about as close (an
    # over-split). Without this, the only enrolled person has no runner-up and takes every near voice.
    for pid in {s["person_id"] for s in out.values() if s.get("source") == "auto"}:
        near = {lab: cosine_distance(voices[lab].vector, models[pid].centroid) for lab, s in out.items()
                if s.get("person_id") == pid and getattr(voices.get(lab), "vector", None) is not None}  # fmt: skip
        best = min(near.values())
        for lab, distance in near.items():
            if out[lab]["source"] == "auto" and distance - best >= op.margin:
                out[lab] |= {"person_id": None, "source": None}
    return out


def _label_key(label: str) -> tuple[int, str]:
    return (int(label[1:]) if label[1:].isdigit() else 10**6, label)
