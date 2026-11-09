"""The Voices hub's review queue and sample actions (docs/speaker-learning.md, "Review").

Review items, most useful first:
1. `sample` items whose review flag is open (`speakers.flags`: pitch or score outliers, or samples that
   contradict an enrollment-only model);
2. `label` items: recent automatic names, and recent unnamed labels with a "possibly X" hint;
3. every other active sample, newest first.

An item id is bound to what it shows (`s.<sample>.<revision>`, `l.<conversation>.<label>.<speakers
revision>`): deciding on a changed one is `409 stale_review`. A decision is deduplicated durably by its
`request_id`: a sample's own `history`, or the conversation's `speakers.json` request entries for label
decisions (the existing naming path, `SpeakerService.assign`), and undone by `POST /v1/speakers/undo`
with the same conditional semantics (only where nothing changed since; never a forgotten person back).

- confirm: a sample's flag is resolved for its evidence fingerprint; a label is named (a user name).
- reject: a sample is soft-removed (state `removed`, restorable); a label gets "not X".
- move: the sample is copied to the other person first (an intent with `moved_from`; a retry reuses it),
  then marked `moved`; if a label in its conversation still lists it, that label is renamed too, so later
  retractions follow the moved sample.
"""

from __future__ import annotations

import io
import json
import time
import uuid

import soundfile as sf

from ..ingest import ApiError
from ..util import UUID_RE, iso_utc_epoch
from . import f0 as sample_f0
from . import journal
from .store import ACTIVE, MOVED, REMOVED, consent_ok, flag_open, sample_eligible

RECENT_CONVERSATIONS = 60  # how far back label items reach (newest conversations)
MAX_CLIP_SECONDS = 10.0


def sample_item_id(sample_id: str, revision: int) -> str:
    return f"s.{sample_id}.{revision}"


def label_item_id(conv_id: str, label: str, revision: int, person_id: str, evidence: str) -> str:
    """Bound to the label's revision, the person it proposes and the evidence that proposed them (`_evidence`)."""
    return f"l.{conv_id}.{label}.{revision}.{person_id}.{evidence}"


def _request_id(body: dict) -> str:
    request_id = body.get("request_id")
    if not isinstance(request_id, str) or not request_id or len(request_id) > 100:
        raise ApiError(422, "invalid_body", "request_id is required")
    return request_id


class Review:
    def __init__(self, service) -> None:
        self.service = service
        self.store = service.store
        self.db = service.db
        self.pipeline = service.pipeline

    # -- views -----------------------------------------------------------------------------------

    def _audio(self, data: dict) -> tuple[list, object] | None:
        """(clip bounds, conversation row) when the sample's audio can be cut from raw audio now."""
        conv_id = data.get("conversation_id")
        row = self.db.one("SELECT * FROM conversations WHERE id=?", (conv_id,)) if conv_id else None
        found = sample_f0.sample_spans(self.store, data) if row is not None else None
        if row is None or found is None or not self.store.raw_available(row):
            return None
        spans, voices_file = found
        expected = (data.get("audio_sha") or "")[:16] or sample_f0.audio16(voices_file)
        if expected and (row["audio_sha"] or "")[:16] != expected:
            return None  # the bounds belong to another assembly of the audio
        return spans, row

    def _enrollment_audio(self, data: dict):
        if data.get("source") != "enrollment" or not data.get("enrollment_id"):
            return None
        path = self.store.person_dir(data["person_id"]) / "enrollment" / f"{data['enrollment_id']}.omiaudio"
        return path if path.exists() else None

    def _caption(self, data: dict) -> str:
        """The transcript phrase overlapping the sample's first clip (recorded with it, else computed while the
        transcript is of the same audio); "" when nothing is known. Never another moment's sentence."""
        if data.get("caption"):
            return data["caption"]
        conv_id = data.get("conversation_id")
        found = sample_f0.sample_spans(self.store, data) if conv_id else None
        row = self.db.one("SELECT audio_sha FROM conversations WHERE id=?", (conv_id,)) if conv_id else None
        if found is None or row is None:
            return ""
        spans, voices_file = found
        expected = sample_f0.audio16(voices_file)
        if expected and (row["audio_sha"] or "")[:16] != expected:
            return ""
        try:
            transcript = self.service._transcript(conv_id)
        except ApiError:
            return ""
        label = data.get("label") or ""
        clips = self.service._clip_list(conv_id, transcript, label, spans)
        return next((c["text"] for c in clips if c["text"]), "")

    def _device(self, conv_id: str | None) -> str | None:
        row = self.db.one("SELECT device_id FROM conversations WHERE id=?", (conv_id,)) if conv_id else None
        return row["device_id"] if row else None

    def sample_view(self, data: dict) -> dict:
        flag = data.get("flag") or None
        audio = self._audio(data)
        playable = audio is not None or self._enrollment_audio(data) is not None
        view = {
            "id": data["sample_id"], "person_id": data["person_id"], "state": data.get("state") or ACTIVE,
            "revision": int(data.get("revision") or 0), "source": data.get("source"), "seconds": data.get("seconds"),
            "created_at": iso_utc_epoch(data["created_at"]) if data.get("created_at") else None, "day": data.get("day"),
            "label": data.get("label"), "f0": data.get("f0"), "f0_source": data.get("f0_source"),
            "flag": {"reasons": flag.get("reasons") or [], "open": flag_open(flag), "resolved": flag.get("resolved")} if flag else None,
            "moved_to": data.get("moved_to"), "moved_from": data.get("moved_from"),
            "playable": playable, "text": self._caption(data),
            "conversation": self.service._context(data["conversation_id"]) if data.get("conversation_id") else None,
            "device": self._device(data.get("conversation_id")),
            "review_id": sample_item_id(data["sample_id"], int(data.get("revision") or 0)),
        }  # fmt: skip
        if playable:
            if audio is not None:
                a, b = audio[0][0]
                started = self._wall(audio[1]["id"], a)
            else:
                a, b, started = 0.0, MAX_CLIP_SECONDS, None
            view["clip"] = {"id": f"sample.{data['sample_id']}.0", "seconds": round(min(b - a, MAX_CLIP_SECONDS), 2),
                            "started_at": started}  # fmt: skip
        return view

    def _wall(self, conv_id: str, t: float) -> str | None:
        try:
            transcript = self.service._transcript(conv_id)
        except ApiError:
            return None
        timemap = transcript.get("timemap") or []
        for out_start, wall_start, duration in timemap:
            if out_start <= t <= out_start + duration:
                return iso_utc_epoch(wall_start + (t - out_start))
        return None

    def _sample_item(self, data: dict) -> dict:
        view = self.sample_view(data)
        item = {"id": view["review_id"], "kind": "sample", "person_id": view["person_id"], "sample_id": view["id"],
                "reasons": (view["flag"] or {}).get("reasons", []) if (view["flag"] or {}).get("open") else [],
                "playable": view["playable"], "text": view["text"], "conversation": view["conversation"],
                "device": view["device"], "source": view["source"], "f0": view["f0"]}  # fmt: skip
        if "clip" in view:
            item["clip"] = view["clip"]
        return item

    # -- the queue -------------------------------------------------------------------------------

    def items(self, limit: int, now: float | None = None) -> list[dict]:
        now = time.time() if now is None else now
        self.store.sync_samples()
        flagged, rest = [], []
        for r in self.db.query("SELECT * FROM samples ORDER BY created_at DESC, id"):
            if not sample_eligible(r):
                continue
            data = self.store.read_sample(r["person_id"], r["id"])
            if data is None:
                continue
            if flag_open(data.get("flag")):
                flagged.append((-len(data["flag"].get("reasons") or []), -(data.get("created_at") or 0), data))
            elif not any(h.get("action") == "confirm" for h in data.get("history") or []):
                rest.append(data)
        out = [self._sample_item(d) for *_, d in sorted(flagged, key=lambda x: (x[0], x[1]))][:limit]
        if len(out) < limit:
            out += self.label_items(limit - len(out), now)
        for data in rest:
            if len(out) >= limit:
                break
            out.append(self._sample_item(data))
        return out

    def label_items(self, limit: int, now: float) -> list[dict]:
        """Recent automatic names and "possibly X" hints, newest conversation first."""
        people = {p["id"] for p in self.store.people()}
        out = []
        rows = self.db.query(
            """SELECT * FROM conversations WHERE status <> 'open' AND transcript_sha IS NOT NULL
               ORDER BY start DESC LIMIT ?""",
            (RECENT_CONVERSATIONS,),
        )
        for row in rows:
            if len(out) >= limit:
                break
            states = self.store.labels(row["id"])
            hints = self._hint_people(row) if not states or any(not s.get("person_id") for s in states.values()) else {}
            for label in sorted(set(states) | set(hints)):
                state = states.get(label) or {}
                if state.get("source") == "auto" and state.get("person_id") in people:
                    out.append(self._label_item(row, label, state["person_id"], ["auto"]))
                elif label in hints and hints[label] in people and not state.get("person_id"):
                    out.append(self._label_item(row, label, hints[label], ["possible"]))
        return out[:limit]

    def _hint_people(self, row) -> dict:
        """label → the person a "possibly X" hint names (the rule of `possible_voice_names`)."""
        embedder = self.pipeline.providers.embedder
        space = self.pipeline.voice_space(embedder) if embedder else None
        if space is None:
            return {}
        from ..pipeline.conversations import possible_names
        from .space import label_centre

        voices = self.store.voices_of_labels(row["id"], row["transcript_sha"])
        vectors = {lab: v.vector for lab, v in voices.items() if v.vector is not None and v.model_sha == embedder.model_sha}
        centres = {lab: label_centre(v, list(vectors.values()), space.ga, full=False)[0] for lab, v in vectors.items()}
        return possible_names(vectors, self.store.labels(row["id"]), space.centroids, background=centres)

    def _label_item(self, row, label: str, person_id: str, reasons: list[str]) -> dict:
        transcript = self.service._transcript(row["id"])
        spans = self.service._clips(row["id"], transcript).get(label) or []
        clips = self.service._clip_list(row["id"], transcript, label, spans)
        playable = bool(clips) and self.store.raw_available(row)
        item = {"id": label_item_id(row["id"], label, row["speakers_revision"], person_id, self._evidence()), "kind": "label",
                "person_id": person_id,
                "label": label, "reasons": reasons, "playable": playable,
                "text": next((c["text"] for c in clips if c["text"]), ""),
                "conversation": self.service._context(row["id"]), "device": row["device_id"]}  # fmt: skip
        if playable:
            item["clip"] = {k: clips[0][k] for k in ("id", "seconds", "started_at")}
        return item

    # -- decisions -------------------------------------------------------------------------------

    def decide(self, item_id: str, body: dict) -> dict:
        decision = body.get("decision")
        if decision not in ("confirm", "reject", "move"):
            raise ApiError(422, "invalid_body", "decision is confirm, reject or move")
        request_id = _request_id(body)
        person_id = body.get("person_id")
        if decision == "move" and (not isinstance(person_id, str) or not UUID_RE.match(person_id)):
            raise ApiError(422, "invalid_body", "a move needs person_id (a lowercase UUID)")
        kind, _, rest = item_id.partition(".")
        if kind == "s":
            sample_id, _, revision = rest.rpartition(".")
            if not revision.isdigit():
                raise ApiError(404, "not_found", "unknown review item")
            result = self.sample_decision(sample_id, decision, request_id, expected_revision=int(revision), person_id=person_id)
        elif kind == "l":
            parts = rest.split(".")
            if len(parts) != 5 or not UUID_RE.match(parts[0]) or not parts[1] or not parts[2].isdigit():
                raise ApiError(409, "stale_review", "this review item is from an older queue; fetch it again")
            conv_id, label, revision, proposed, evidence = parts
            result = self.label_decision(conv_id, label, int(revision), decision, request_id, person_id,
                                         proposed=proposed, evidence=evidence)  # fmt: skip
        else:
            raise ApiError(404, "not_found", "unknown review item")
        return {"item_id": item_id, "decision": decision, "request_id": request_id, "undo_token": request_id} | result

    def _evidence(self) -> str:
        """A digest of what proposes people for labels: the eligible samples and the consent behind them."""
        import hashlib

        prefs = self.store.settings()
        rows = sorted((r["id"], r["state"], r["revision"]) for r in self.db.query("SELECT id, state, revision FROM samples"))
        attested = sorted(r["id"] for r in self.store.people() if r["attested_at"])
        basis = json.dumps([rows, attested, prefs["acknowledged_at"], prefs["unknown_voices_enabled"]], sort_keys=True)
        return hashlib.sha256(basis.encode()).hexdigest()[:12]

    def label_decision(self, conv_id: str, label: str, revision: int, decision: str, request_id: str, person_id: str | None,
                       *, proposed: str, evidence: str) -> dict:  # fmt: skip
        with self.store.lock:
            self.store.sync_conversation(conv_id)
            self.store.reconcile()
            journal.blocking(self.store, {person_id}, labels={(conv_id, label)})
            if self.store.request_result(conv_id, request_id) is not None:  # a retry: the naming path answers it
                outcome = self.service.assign(conv_id, label, {"person_id": None, "expected_revision": -1, "request_id": request_id})
                return {"conversation_id": conv_id, "label": label, "revision": outcome.revision, "sample": outcome.sample}
            row = self.service._conversation(conv_id)
            if row["speakers_revision"] != revision:
                raise ApiError(409, "stale_review", "this voice changed since the review item was made")
            state = self.store.labels(conv_id).get(label) or {}
            target = state.get("person_id") if state.get("source") == "auto" else None
            if target is None and not state.get("person_id"):
                target = self._hint_people(row).get(label)
            if target is None:
                raise ApiError(409, "stale_review", "this voice has no suggested person any more")
            if target != proposed or evidence != self._evidence():
                raise ApiError(409, "stale_review", "what proposed this person changed since the review item was made")
            body = {"expected_revision": revision, "request_id": request_id}
            if decision == "confirm":
                body["person_id"] = target
            elif decision == "reject":
                body |= {"person_id": None, "not_person_id": target}
            else:
                body["person_id"] = person_id
            outcome = self.service.assign(conv_id, label, body)
            return {"conversation_id": conv_id, "label": label, "revision": outcome.revision, "sample": outcome.sample}

    def _history_entry(self, sample_id: str, request_id: str) -> tuple[dict, dict] | None:
        """(sample file, its history entry) for a request already applied to this sample."""
        data = self.store.find_sample(sample_id)
        for entry in (data or {}).get("history") or []:
            if entry.get("request_id") == request_id and entry.get("action") != "undo":
                return data, entry
        return None

    def sample_decision(self, sample_id: str, decision: str, request_id: str, *, expected_revision: int | None,
                        person_id: str | None = None) -> dict:  # fmt: skip
        """confirm | reject | remove | restore | move one sample (see the module docstring)."""
        with self.store.lock:
            self.store.reconcile()  # an interrupted operation finishes first (a retry of it is then answered)
            found = self.store.find_sample(sample_id)
            # before any answer, a retry's included: never report success on top of an unfinished operation
            journal.blocking(self.store, {(found or {}).get("person_id"), person_id}, {sample_id})
            done = self._history_entry(sample_id, request_id)
            if done is not None:
                data, _ = done
                return {"sample": self.sample_view(self.store.find_sample(sample_id) or data)}
            data = found
            if data is None:
                raise ApiError(404, "not_found", "unknown sample")
            if expected_revision is not None and int(data.get("revision") or 0) != expected_revision:
                raise ApiError(409, "stale_review", "this sample changed since the review item was made")
            state = data.get("state") or ACTIVE
            pid = data["person_id"]
            if decision == "confirm":
                if state != ACTIVE:
                    raise ApiError(409, "sample_not_active", f"the sample is {state}")
                data = self.store.resolve_flag(pid, sample_id, "confirm", request_id=request_id)
            elif decision == "reject":
                if state != ACTIVE:
                    raise ApiError(409, "sample_not_active", f"the sample is {state}")
                data = self._reject(data, request_id)
            elif decision == "remove":
                if state != ACTIVE:
                    raise ApiError(409, "sample_not_active", f"the sample is {state}")
                data = self.store.set_sample_state(pid, sample_id, REMOVED, action=decision, by="user", request_id=request_id)
            elif decision == "restore":
                if state != REMOVED:
                    raise ApiError(409, "sample_not_removed", f"the sample is {state}")
                journal.forgetting(self.store, {pid})
                self._consented(pid)  # never back into use without current consent
                self._not_superseded(data)
                data = self.store.set_sample_state(pid, sample_id, ACTIVE, action="restore", by="user", request_id=request_id)
            elif decision == "move":
                data = self._move(data, person_id, request_id)
            self.service._relabel()
            return {"sample": self.sample_view(data)}

    def _consented(self, person_id: str) -> None:
        person = self.store.person(person_id)
        if person is None:
            raise ApiError(404, "not_found", f"unknown person {person_id}")
        if not person["me"] and not (self.store.settings()["acknowledged_at"] and self.store.attested(person_id)):
            raise ApiError(409, "consent_required", "this person's voice can't be kept without the acknowledgment and their attestation")

    def _overlap_why(self, data: dict, person_id: str | None = None) -> str:
        """Why this imported enrollment can't count again ("" when it can): another active enrollment of the same
        person (`person_id`: of the person it would move to) holds audio from the same source over an overlapping
        range (whatever merged into what)."""
        source = data.get("import") or {}
        if data.get("source") != "enrollment" or not source.get("sha256"):
            return ""
        owner = person_id or data["person_id"]
        for r in self.db.query("SELECT id FROM samples WHERE person_id=? AND source='enrollment' AND id<>?",
                               (owner, data["sample_id"])):  # fmt: skip
            other = self.store.read_sample(owner, r["id"]) or {}
            theirs = other.get("import") or {}
            if (sample_eligible(other) and theirs.get("sha256") == source["sha256"]
                    and float(theirs["start"]) < float(source["end"]) and float(theirs["end"]) > float(source["start"])):  # fmt: skip
                return "superseded"
        return ""

    def _not_superseded(self, data: dict) -> None:
        if self._overlap_why(data):
            raise ApiError(409, "superseded", "an active import holds overlapping audio from the same source; remove it first")

    def _listing_label(self, data: dict) -> str | None:
        """The label in the sample's conversation whose state lists this sample under its person."""
        conv_id = data.get("conversation_id")
        if not conv_id or self.db.one("SELECT 1 FROM conversations WHERE id=?", (conv_id,)) is None:
            return None
        self.store.sync_conversation(conv_id)
        for label, state in self.store.labels(conv_id).items():
            if data["sample_id"] in (state.get("samples") or []) and state.get("person_id") == data["person_id"]:
                return label
        return None

    def _label_samples(self, data: dict, label: str | None) -> list[str]:
        """This sample and every other active one its label contributed to the same person (one voice, one decision)."""
        ids = {data["sample_id"]}
        if label is not None:
            state = self.store.labels(data["conversation_id"]).get(label) or {}
            for sid in state.get("samples") or []:
                other = self.store.read_sample(data["person_id"], sid)
                if other is not None and sample_eligible(other):
                    ids.add(sid)
        return sorted(ids)

    def _move(self, data: dict, person_id: str | None, request_id: str) -> dict:
        if (data.get("state") or ACTIVE) != ACTIVE:
            raise ApiError(409, "sample_not_active", f"the sample is {data.get('state')}")
        if person_id == data["person_id"]:
            raise ApiError(422, "invalid_body", "the sample already belongs to that person")
        self._consented(person_id)
        label = self._listing_label(data)
        pairs = [[sid, str(uuid.uuid4())] for sid in self._label_samples(data, label)]
        for src, _ in pairs:  # the same audio must not count twice for the person it moves to
            if self._overlap_why(self.store.read_sample(data["person_id"], src) or {}, person_id):
                raise ApiError(409, "superseded", "that person already has an active enrollment of the same audio")
        journal.run(self.store, {"kind": "move", "request_id": request_id, "by": "user", "from": data["person_id"], "to": person_id,
                                 "pairs": pairs, "label": {"conversation_id": data["conversation_id"], "label": label} if label else None})  # fmt: skip
        return self.store.read_sample(data["person_id"], data["sample_id"])

    def _reject(self, data: dict, request_id: str) -> dict:
        """Not this person's voice: the sample is soft-removed, and when its label still lists it under that person,
        so are the label's other samples of them and the label becomes "not X" (one journaled operation)."""
        label = self._listing_label(data)
        journal.run(self.store, {"kind": "reject", "request_id": request_id, "person": data["person_id"],
                                 "samples": self._label_samples(data, label),
                                 "label": {"conversation_id": data["conversation_id"], "label": label} if label else None})  # fmt: skip
        return self.store.read_sample(data["person_id"], data["sample_id"])

    # -- undo of sample decisions ----------------------------------------------------------------

    def undo(self, request_id: str, undo_id: str) -> dict:
        """Put back what sample decisions under `request_id` changed, where nothing changed since (call under the
        speaker lock). A move or reject whose label changed too is undone with its label (`undo_label_op`)."""
        undone, skipped = [], []
        for path in sorted(self.store.vault.people.glob("*/samples/*.json")) if self.store.vault.people.exists() else []:
            data = self.store.read_sample(path.parent.parent.name, path.stem) or {}
            history = data.get("history") or []
            if not any(h.get("request_id") == request_id for h in history):
                continue
            index, entry = next((i, h) for i, h in enumerate(history) if h.get("request_id") == request_id)
            if entry.get("label"):
                continue  # undone with its label (speakers.json)
            if any(h.get("action") == "undo" and h.get("request_id") == undo_id and h.get("undo_of") == request_id for h in history):
                undone.append(data["sample_id"])
                continue
            if _later(history, index):
                skipped.append({"id": data["sample_id"], "reason": "changed since"})
                continue
            why = self.revert(data, entry, undo_id, request_id)
            (skipped.append({"id": data["sample_id"], "reason": why}) if why else undone.append(data["sample_id"]))
        return {"undone": sorted(undone), "skipped": skipped}

    def revert(self, data: dict, entry: dict, undo_id: str, request_id: str) -> str:
        """Put one sample back as `entry` found it; "" when done, else why not."""
        pid, sid = data["person_id"], data["sample_id"]
        action = entry.get("action")
        record = {"undo_of": request_id}
        if action == "move":
            target = data.get("moved_to") or {}
            why = self._copies_unchanged(target.get("person_id"), [[sid, target.get("sample_id")]]) or self._consent_why(pid) or self._overlap_why(data)
            if why:
                return why
            journal.run(self.store, {"kind": "unmove", "request_id": undo_id, "undo_of": request_id, "from": pid,
                                     "to": target["person_id"], "pairs": [[sid, target["sample_id"]]], "label": None})  # fmt: skip
        elif action in ("reject", "remove", "restore"):
            back = entry.get("from") or ACTIVE
            if back == ACTIVE and (why := self._consent_why(pid) or self._overlap_why(data)):
                return why
            self.store.update_sample(pid, sid, {"state": back}, action="undo", by="user", request_id=undo_id,
                                     record=record | {"from": data.get("state") or ACTIVE, "to": back})  # fmt: skip
        elif action == "confirm":
            flag = dict(data.get("flag") or {})
            flag.pop("resolved", None)
            self.store.update_sample(pid, sid, {"flag": flag or None}, action="undo", by="user", request_id=undo_id,
                                     record=record, recalibrate=False)  # fmt: skip
        else:
            return "nothing to undo"
        return ""

    def _consent_why(self, person_id: str) -> str:
        """Why this person's voice data can't be put back into use now ("" when it can)."""
        if self.store.forgetting_path(person_id).exists():
            return "that person's forget hasn't finished"
        person = self.store.person(person_id)
        if person is None:
            return "that person was forgotten"
        return "" if consent_ok(person, self.store.settings()) else "that person's consent is withdrawn"

    def _copies_unchanged(self, person_id: str | None, pairs: list) -> str:
        """Why the copies a move made can't simply be taken back ("" when they can): each still exists, counts,
        and nothing was decided about it since."""
        for _, new in pairs:
            copy = self.store.read_sample(person_id or "", new or "")
            if copy is None:
                return "the moved copy was forgotten since"
            if copy.get("pending_op") or (copy.get("state") or ACTIVE) != ACTIVE or copy.get("history"):
                return "the moved copy changed since"
        return ""

    def undo_label_op(self, conv_id: str, key: str, rec: dict, undo_id: str) -> str:
        """Undo a journaled move or reject recorded in `speakers.json` under `key` (call under the speaker lock): ""
        when undone, else why not. All or nothing, and only where the label and every sample are as it left them."""
        states = self.store.labels(conv_id)
        label = rec["label"]
        current = self.store.persisted({label: states.get(label) or {}}).get(label) or {}
        after = rec.get("after") or {}
        if any(current.get(k) != after.get(k) for k in ("person_id", "source", "samples", "not")):
            return "the label changed since"
        if rec.get("moved"):
            moved = rec["moved"]
            a, b, pairs = moved["person_id"], moved["to_person"], moved["pairs"]
            for src, new in pairs:
                data = self.store.read_sample(a, src) or {}
                history = data.get("history") or []
                index = next((i for i, h in enumerate(history) if h.get("request_id") == key and h.get("action") == "move"), None)
                if data.get("state") != MOVED or (data.get("moved_to") or {}).get("sample_id") != new or index is None or _later(history, index):
                    return "a moved sample changed since"
                if self._overlap_why(data):
                    return "an active import holds overlapping audio from the same source"
            why = self._copies_unchanged(b, pairs) or self._consent_why(a)
            if why:
                return why
            journal.run(self.store, {"kind": "unmove", "request_id": undo_id, "undo_of": key, "from": a, "to": b, "pairs": pairs,
                                     "label": {"conversation_id": conv_id, "label": label}, "label_before": rec.get("before") or {}})  # fmt: skip
            return ""
        rejected = rec["rejected"]
        x = rejected["person_id"]
        for sid in rejected["samples"]:
            data = self.store.read_sample(x, sid) or {}
            history = data.get("history") or []
            index = next((i for i, h in enumerate(history) if h.get("request_id") == key and h.get("action") == "reject"), None)
            if data.get("state") != REMOVED or index is None or _later(history, index):
                return "a rejected sample changed since"
            if self._overlap_why(data):
                return "an active import holds overlapping audio from the same source"
        if why := self._consent_why(x):
            return why
        journal.run(self.store, {"kind": "unreject", "request_id": undo_id, "undo_of": key, "person": x, "samples": rejected["samples"],
                                 "label": {"conversation_id": conv_id, "label": label}, "label_before": rec.get("before") or {}})  # fmt: skip
        return ""

    # -- clips -----------------------------------------------------------------------------------

    def clip_wav(self, clip_id: str) -> bytes:
        """`sample.<sample id>.<i>`: the sample's own clip i (≤ 10 s), cut from raw audio while it exists (or from
        the person's stored enrollment audio); 410 when the audio is gone, never anything else."""
        _, _, rest = clip_id.partition(".")
        sample_id, _, index = rest.rpartition(".")
        if not UUID_RE.match(sample_id) or not index.isdigit():
            raise ApiError(404, "not_found", "unknown clip")
        data = self.store.find_sample(sample_id)
        if data is None:
            raise ApiError(404, "not_found", "unknown clip")
        audio = self._audio(data)
        if audio is not None:
            spans, row = audio
            if int(index) >= len(spans):
                raise ApiError(404, "not_found", "unknown clip")
            a, b = spans[int(index)]
            pcm = self.pipeline.conversation_audio(row).pcm[int(round(a * 16000)) : int(round(min(b, a + MAX_CLIP_SECONDS) * 16000))]
        elif (path := self._enrollment_audio(data)) is not None and index == "0":
            pcm, _ = sf.read(io.BytesIO(path.read_bytes()), dtype="int16")
            pcm = pcm[: int(MAX_CLIP_SECONDS * 16000)]
        else:
            raise ApiError(410, "audio_expired", "the raw audio of this sample is gone")
        if not len(pcm):
            raise ApiError(410, "audio_expired", "no audio for this clip")
        buf = io.BytesIO()
        sf.write(buf, pcm, 16000, format="WAV", subtype="PCM_16")
        return buf.getvalue()

    # -- per person ------------------------------------------------------------------------------

    def person_samples(self, person_id: str, state: str | None) -> list[dict]:
        if self.store.person(person_id) is None and not self.store.person_dir(person_id).exists():
            raise ApiError(404, "not_found", "unknown person")
        if state not in (None, "", "active", "flagged", "removed", "moved"):
            raise ApiError(422, "invalid_state", "state is active, flagged, removed or moved")
        self.store.sync_samples()
        out = []
        for r in self.db.query("SELECT * FROM samples WHERE person_id=? ORDER BY created_at DESC, id", (person_id,)):
            data = self.store.read_sample(person_id, r["id"])
            if data is None:
                continue
            current = data.get("state") or ACTIVE
            if state == "flagged" and not (current == ACTIVE and flag_open(data.get("flag"))):
                continue
            if state not in (None, "", "flagged") and current != state:
                continue
            out.append(self.sample_view(data))
        return out

    def counts(self, person_id: str) -> dict:
        active = flagged = removed = 0
        for r in self.db.query("SELECT state, flag_json FROM samples WHERE person_id=?", (person_id,)):
            if r["state"] == REMOVED:
                removed += 1
            elif sample_eligible(r):
                active += 1
                if r["flag_json"]:
                    flagged += int(flag_open(json.loads(r["flag_json"])))
        return {"samples_active": active, "samples_flagged": flagged, "samples_removed": removed, "review_count": flagged}


def status_line(model, active_samples: int, auto_assign: bool) -> str:
    """One plain line for a person card."""
    if model is not None and model.active:
        return "已启用" if auto_assign else "已就绪：自动命名已关闭"
    if active_samples and "leave-one-out" in (model.why_inactive if model else ""):
        return "停用：样本不一致"
    return "需要更多样本"


def _later(history: list[dict], index: int) -> bool:
    """Something was decided about the sample after `history[index]` (flags don't count)."""
    return any(h.get("action") not in ("flag", "unflag") for h in history[index + 1 :])
