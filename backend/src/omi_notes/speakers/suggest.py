"""Recurring unknown voices worth naming (pure; docs/speaker-learning.md, "Suggestions").

Only with unknown-voice storage opted in. Candidates are unassigned labels with ≥ 10 s of speech
whose raw audio still exists; they are clustered with average linkage at 0.50; a cluster spanning
≥ 3 conversations on ≥ 2 days is suggested, ranked by conversations × seconds, at most 5. A
cluster close to an existing person asks "Is this Priya?"; while nobody is "me", the loudest
recurring voice asks "Is this you?" (the wearer is closest to the microphone). A dismissed
suggestion stays hidden for 7 days (cf. Omi `backend/routers/speaker_tag_prompts.py`).
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass

import numpy as np

from .match import THRESHOLD, PersonModel, best_match
from .voices import centroid

SIGNIFICANT_SECONDS = 10.0
MIN_CONVERSATIONS = 3
MIN_DAYS = 2
LIMIT = 5
COOLDOWN = 7 * 86400


@dataclass(frozen=True)
class Candidate:
    conversation_id: str
    label: str
    vector: np.ndarray
    seconds: float
    day: str
    rms_db: float | None = None

    @property
    def key(self) -> str:
        return f"{self.conversation_id}:{self.label}"


@dataclass
class Suggestion:
    id: str
    kind: str  # is_this_you | is_this_person | who_is_this
    members: list[Candidate]
    person_id: str | None = None

    @property
    def conversations(self) -> int:
        return len({m.conversation_id for m in self.members})

    @property
    def days(self) -> int:
        return len({m.day for m in self.members})

    @property
    def seconds(self) -> float:
        return round(sum(m.seconds for m in self.members), 1)

    @property
    def representative(self) -> Candidate:
        """The member closest to the cluster's centre (its clip and excerpt are shown)."""
        center = centroid([m.vector for m in self.members], [m.seconds for m in self.members])
        return max(self.members, key=lambda m: (float(np.dot(m.vector, center)), m.seconds))


def cluster(vectors: list[np.ndarray], threshold: float = THRESHOLD) -> list[list[int]]:
    """Average-linkage agglomerative clustering on cosine distance, merged while < threshold."""
    if not vectors:
        return []
    x = np.stack([v / (np.linalg.norm(v) or 1.0) for v in vectors]).astype(np.float64)
    dist = 1.0 - x @ x.T
    groups: list[list[int]] = [[i] for i in range(len(vectors))]
    while len(groups) > 1:
        best = (float("inf"), -1, -1)
        for i in range(len(groups)):
            for j in range(i + 1, len(groups)):
                d = float(dist[np.ix_(groups[i], groups[j])].mean())
                if d < best[0]:
                    best = (d, i, j)
        if best[0] >= threshold:
            break
        _, i, j = best
        groups[i] = groups[i] + groups[j]
        del groups[j]
    return groups


def suggestion_id(members: list[Candidate]) -> str:
    """Stable while the cluster grows: new conversations come later than the earliest member."""
    first = min(members, key=lambda m: m.key)
    return hashlib.sha1(first.key.encode()).hexdigest()[:16]


def suggestions(candidates: list[Candidate], models: dict[str, PersonModel], *, me_exists: bool,
                dismissed: dict[str, float], now: float, limit: int = LIMIT) -> list[Suggestion]:  # fmt: skip
    pool = [c for c in candidates if c.seconds >= SIGNIFICANT_SECONDS]
    found: list[Suggestion] = []
    for group in cluster([c.vector for c in pool]):
        members = [pool[i] for i in group]
        s = Suggestion(suggestion_id(members), "who_is_this", members)
        if s.conversations < MIN_CONVERSATIONS or s.days < MIN_DAYS:
            continue
        if dismissed.get(s.id, 0) > now:
            continue
        center = centroid([m.vector for m in members], [m.seconds for m in members])
        pid, distance, _ = best_match(center, models)
        if pid is not None and distance is not None and distance < THRESHOLD:
            s.kind, s.person_id = "is_this_person", pid
        found.append(s)
    if not me_exists:
        unnamed = [s for s in found if s.kind == "who_is_this"]
        loud = [s for s in unnamed if all(m.rms_db is not None for m in s.members)]
        if loud:
            max(loud, key=lambda s: float(np.mean([m.rms_db for m in s.members]))).kind = "is_this_you"
    found.sort(key=lambda s: (-(s.conversations * s.seconds), s.id))
    return found[:limit]
