"""How well each person's voice is recognized, measured on held-out conversations (informational only).

docs/speaker-learning.md, "Calibration"; voices-hub plan, Revisions 2-4. Calibration **never changes
activation**: automatic naming stays behind the existing gate (`match.activation`), and nothing here is
fed back into thresholds. What it reports, per person:

- consistency: each eligible sample's raw cosine to the person's robust centroid (median, MAD, minimum);
- held-out evaluation of the actual matcher decision, leaving one conversation out at a time: models
  (and the recording-mean space) are rebuilt without that conversation's samples and voices, and
  `match.assign` runs on its stored voices exactly as a relabel would. The conversation's user-named
  labels are the truth. Listed separately: positive conversations (the person was named there: a miss
  is an error), named-other-person negatives (only other people were named there: naming this person
  is an error), and target-absent conversations (only conversations a user reviewed as not containing
  the person count; there is no such review yet, so 0);
- errors and one-sided 95 % Clopper–Pearson upper bounds. `measured` is given only when those counts
  exist. There is no pooled accuracy.

`_omi/speakers/calibration.json` (atomic, vault-first) records an input fingerprint (eligible sample ids
and states, consent, the wearer, the model and algorithm versions, and the user-named labels evaluated),
computed outside the speaker lock and published under it only if the fingerprint still matches. Each run
is appended to `calibration-log.jsonl`. It runs debounced after any sample or consent change, nightly at
03:10 local, and on startup (or after an index rebuild) when the file is missing or stale.
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import time
from datetime import datetime

import numpy as np

from ..util import iso_utc_epoch
from ..vault import Vault
from . import flags as speaker_flags
from . import match as speaker_match
from .space import build_space

log = logging.getLogger(__name__)

VERSION = 1
DEBOUNCE_SECONDS = 60.0
NIGHTLY = (3, 10)  # local time
CONFIDENCE = 0.95


# -- statistics -------------------------------------------------------------------------------------


def _binom_cdf(k: int, n: int, p: float) -> float:
    if p <= 0.0:
        return 1.0
    if p >= 1.0:
        return 1.0 if k >= n else 0.0
    lp, lq = math.log(p), math.log1p(-p)
    terms = [math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1) + i * lp + (n - i) * lq for i in range(k + 1)]
    top = max(terms)
    return min(1.0, math.exp(top) * sum(math.exp(t - top) for t in terms))


def cp_upper(errors: int, n: int, confidence: float = CONFIDENCE) -> float | None:
    """One-sided Clopper–Pearson upper bound on an error rate (None without trials)."""
    if n <= 0:
        return None
    if errors >= n:
        return 1.0
    lo, hi = errors / n, 1.0
    for _ in range(80):
        mid = (lo + hi) / 2
        if _binom_cdf(errors, n, mid) > 1 - confidence:
            lo = mid
        else:
            hi = mid
    return round(hi, 4)


def _counts(n: int, errors: int) -> dict:
    return {"conversations": n, "errors": errors, "upper": cp_upper(errors, n)}


# -- inputs -----------------------------------------------------------------------------------------


def gather(pipeline) -> dict | None:
    """Everything a calibration depends on, read from the index (None without a speaker model)."""
    embedder = pipeline.providers.embedder
    if embedder is None:
        return None
    store, db = pipeline.speakers, pipeline.db
    key = (embedder.model, embedder.model_sha)
    samples = store.samples(*key)
    me = store.me()
    prefs = store.settings()
    attested = sorted(p["id"] for p in store.people() if p["attested_at"])
    truth: dict[str, dict[str, str]] = {}
    for r in db.query("SELECT conversation_id, label, person_id FROM speaker_labels WHERE source='user' AND person_id IS NOT NULL"):
        truth.setdefault(r["conversation_id"], {})[r["label"]] = r["person_id"]
    conversations = {}
    for conv_id, labels in truth.items():
        voices = {lab: v for lab, v in store.voices(conv_id).items() if (v.model, v.model_sha) == key}
        if any(v.vector is not None for v in voices.values()):
            conversations[conv_id] = {"truth": labels, "voices": voices}
    stored = []
    for r in db.query("SELECT conversation_id, vector FROM voices WHERE vector IS NOT NULL AND model=? AND model_sha=?", key):
        stored.append((r["conversation_id"], np.frombuffer(r["vector"], dtype="<f4").astype(np.float32)))
    return {"model": key, "samples": samples, "wearer": me["id"] if me else None,
            "consent": {"acknowledged_at": prefs["acknowledged_at"], "attested": attested},
            "conversations": conversations, "stored": stored}  # fmt: skip


def fingerprint(inputs: dict | None) -> str | None:
    if inputs is None:
        return None
    basis = {
        "version": VERSION, "owner_rule": speaker_match.OWNER_RULE.version, "flags": speaker_flags.VERSION,
        "model": list(inputs["model"]), "wearer": inputs["wearer"], "consent": inputs["consent"],
        "samples": sorted([s.id, s.state] for s in inputs["samples"]),
        "labels": sorted([c, lab, pid, (data["voices"][lab].file if lab in data["voices"] else None)]
                         for c, data in inputs["conversations"].items() for lab, pid in data["truth"].items()),
    }  # fmt: skip
    return hashlib.sha256(json.dumps(basis, sort_keys=True).encode()).hexdigest()[:32]


# -- evaluation (pure) ------------------------------------------------------------------------------


def _session(sample) -> str | None:
    return sample.session


def evaluate(inputs: dict, op: speaker_match.Operating) -> dict:
    """person → consistency and held-out counts (see the module docstring)."""
    samples = inputs["samples"]
    wearer = inputs["wearer"]
    people: dict[str, dict] = {}
    by_person: dict[str, list] = {}
    for s in samples:
        by_person.setdefault(s.person_id, []).append(s)
    for pid, items in by_person.items():
        centre = speaker_flags.robust_centroid([s.vector for s in items], [2.0 if s.source == "enrollment" else 1.0 for s in items])
        scores = [float(np.asarray(s.vector, dtype=np.float64) @ centre / (np.linalg.norm(s.vector) or 1.0)) for s in items]
        med, spread = speaker_flags.mad(scores)
        people[pid] = {"consistency": {"samples": len(items), "median": round(med, 4), "mad": round(spread, 4),
                                       "min": round(min(scores), 4)},
                       "sessions": len({_session(s) for s in items if _session(s)})}  # fmt: skip
    tallies = {pid: {"pos": [0, 0], "neg": [0, 0]} for pid in people}
    for conv_id, data in sorted(inputs["conversations"].items()):
        held = [s for s in samples if _session(s) != conv_id]
        models = speaker_match.build_models(held, op, wearer_id=wearer)
        vectors = [v for c, v in inputs["stored"] if c != conv_id] + [s.vector for s in held]
        space = build_space(vectors, _centroid_samples(held))
        states = speaker_match.assign(data["voices"], {}, models, auto_assign=True, op=op, space=space) if models else {}
        decided = {lab: (states.get(lab) or {}).get("person_id") for lab in data["truth"]}
        present = set(data["truth"].values())
        for pid in tallies:
            if pid in present:
                tallies[pid]["pos"][0] += 1
                found = any(decided[lab] == pid for lab, truth in data["truth"].items() if truth == pid)
                tallies[pid]["pos"][1] += 0 if found else 1
            else:
                tallies[pid]["neg"][0] += 1
                tallies[pid]["neg"][1] += int(any(named == pid for named in decided.values()))
    for pid, info in people.items():
        pos, neg = tallies[pid]["pos"], tallies[pid]["neg"]
        info["held_out"] = {"positives": _counts(*pos), "named_other": _counts(*neg), "target_absent": _counts(0, 0)}
        info["measured"] = measured(info["held_out"])
    return people


def _centroid_samples(samples: list) -> dict[str, list]:
    out: dict[str, list] = {}
    for s in speaker_match.centroid_basis(samples):
        out.setdefault(s.person_id, []).append(s.vector)
    return out


def measured(held_out: dict) -> dict | None:
    """What the app may show ("held-out: n conversations, ≥ x % found, ≤ y % wrong (95 %)"), only when counted."""
    pos, neg = held_out["positives"], held_out["named_other"]
    if not pos["conversations"] and not neg["conversations"]:
        return None
    return {"conversations": pos["conversations"],
            "found_at_least": None if pos["upper"] is None else round(1 - pos["upper"], 4),
            "negative_conversations": neg["conversations"], "wrong_at_most": neg["upper"],
            "target_absent_conversations": held_out["target_absent"]["conversations"], "confidence": CONFIDENCE}  # fmt: skip


# -- the worker step --------------------------------------------------------------------------------


class Calibrator:
    def __init__(self, pipeline) -> None:
        self.pipeline = pipeline
        self.db = pipeline.db
        self.store = pipeline.speakers
        self.vault = pipeline.vault

    @property
    def path(self):
        return self.vault.speakers / "calibration.json"

    @property
    def log_path(self):
        return self.vault.speakers / "calibration-log.jsonl"

    def current(self) -> dict | None:
        return Vault.read_json(self.path)

    def fingerprint(self) -> str | None:
        return fingerprint(gather(self.pipeline))

    def reconcile(self) -> None:
        """On startup and after a rebuild: a missing or stale calibration is recomputed (soon)."""
        if not self.store.any_samples():
            return
        data = self.current()
        if data is None or data.get("fingerprint") != self.fingerprint():
            self.db.set_meta("calibrate_pending", "0")

    def _nightly_due(self, now: float) -> bool:
        """Past today's 03:10 local and the last published calibration is older (read from the vault, so an index
        rebuild doesn't repeat it)."""
        local = datetime.fromtimestamp(now, self.pipeline.tz)
        if (local.hour, local.minute) < NIGHTLY:
            return False
        mark = local.replace(hour=NIGHTLY[0], minute=NIGHTLY[1], second=0, microsecond=0).timestamp()
        last = (self.current() or {}).get("computed_epoch")
        return not isinstance(last, (int, float)) or last < mark

    def run(self, now: float | None = None, *, force: bool = False) -> bool:
        """Flags, then the calibration, when due. True when a calibration was published."""
        now = time.time() if now is None else now
        pending = self.db.meta("calibrate_pending")
        due = force or self._nightly_due(now) or (pending is not None and now - float(pending) >= DEBOUNCE_SECONDS)
        if not due:
            return False
        with self.store.lock:
            self.store.apply_flags(now)
        inputs = gather(self.pipeline)
        if inputs is None or (not inputs["samples"] and self.current() is None):
            if pending is not None and self.db.meta("calibrate_pending") == pending:
                self.db.set_meta("calibrate_pending", None)  # nothing to calibrate (yet)
            return False
        expected = fingerprint(inputs)
        people = evaluate(inputs, self.pipeline.operating)  # outside the lock: the slow part
        with self.store.lock:
            if fingerprint(gather(self.pipeline)) != expected:
                log.info("calibration inputs changed while computing; it runs again")
                self.db.set_meta("calibrate_pending", repr(now - DEBOUNCE_SECONDS))
                return False
            result = {"version": VERSION, "computed_at": iso_utc_epoch(now), "computed_epoch": now, "fingerprint": expected,
                      "model": list(inputs["model"]), "owner_rule": speaker_match.OWNER_RULE.version,
                      "algorithm": {"calibration": VERSION, "flags": speaker_flags.VERSION}, "people": people}  # fmt: skip
            Vault.write_json(self.path, result)
            Vault.append_jsonl(self.log_path, {"computed_at": result["computed_at"], "fingerprint": expected,
                                               "people": {pid: {"measured": p["measured"], "consistency": p["consistency"]}
                                                          for pid, p in people.items()}})  # fmt: skip
            if self.db.meta("calibrate_pending") == pending:
                self.db.set_meta("calibrate_pending", None)
        log.info("speaker calibration published for %d people", len(people))
        return True
