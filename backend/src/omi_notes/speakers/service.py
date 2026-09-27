"""What the People & Voices API does (docs/speaker-learning.md, "API"); the HTTP layer is thin.

Consent (design as if BIPA / Texas CUBI apply): a voiceprint of anyone but the wearer is only
created by an explicit naming action, after the one-time acknowledgment
(`settings.acknowledged_at`) and with a person-level attestation (`attest_knows`). Unknown-voice
vectors are kept only with the separate opt-in, and only while the conversation's raw audio exists.
"""

from __future__ import annotations

import io
import json
import logging
import time
from dataclasses import dataclass
from datetime import UTC, datetime

import numpy as np
import soundfile as sf

from ..ingest import ApiError
from ..util import UUID_RE, iso_utc_epoch
from . import enroll
from . import match as speaker_match
from . import suggest as speaker_suggest
from .store import voices_name
from .voices import Clip, embed_voices

log = logging.getLogger(__name__)

MAX_CLIP_SECONDS = 10.0
EXCERPT_CHARS = 140


@dataclass
class Outcome:
    revision: int
    labels: list[dict]
    relabeled: list[str]
    sample: str  # created | exists | not_acknowledged | not_attested | no_audio | none


class SpeakerService:
    def __init__(self, pipeline) -> None:
        self.pipeline = pipeline
        self.store = pipeline.speakers
        self.db = pipeline.db
        self.vault = pipeline.vault

    # -- people ----------------------------------------------------------------------------------

    def people(self) -> list[dict]:
        self.store.scan_people()
        embedder = self.pipeline.providers.embedder
        key = (embedder.model, embedder.model_sha) if embedder else None
        samples = self.store.samples(*key) if key else []
        models = speaker_match.build_models(samples, self.pipeline.operating) if samples else {}
        out = []
        for p in self.store.people():
            rows = self.db.query("SELECT * FROM samples WHERE person_id=?", (p["id"],))
            model = models.get(p["id"])
            out.append({
                "id": p["id"], "name": p["name"], "me": bool(p["me"]), "note_path": p["note_path"],
                "samples": len(rows), "sessions": len({r["session"] for r in rows if r["session"]}),
                "auto_active": bool(model and model.active),
                "voice_ready": bool(model and model.centroid is not None),
            })  # fmt: skip
        return out

    def put_person(self, person_id: str, body: dict) -> tuple[int, dict]:
        if not UUID_RE.match(person_id):
            raise ApiError(422, "invalid_person_id", "person id must be a lowercase UUID")
        name = body.get("name")
        if not isinstance(name, str) or not name.strip() or len(name) > 80:
            raise ApiError(422, "invalid_body", "name is required (1-80 characters)")
        me = body.get("me")
        if me is not None and not isinstance(me, bool):
            raise ApiError(422, "invalid_body", "me must be a boolean")
        attest = body.get("attest_knows", False)
        if not isinstance(attest, bool):
            raise ApiError(422, "invalid_body", "attest_knows must be a boolean")
        with self.store.lock:
            created = self.store.put_person(person_id, name.strip(), me=me, attest=attest)
            self.db.set_meta("relabel_pending", "1")  # names/me shape rendering and prompts
        person = next(p for p in self.people() if p["id"] == person_id)
        return (201 if created else 200), person

    def forget(self, person_id: str, *, delete_note: bool) -> list[str]:
        with self.store.lock:
            if self.store.person(person_id) is None and not self.store.person_dir(person_id).exists():
                raise ApiError(404, "not_found", "unknown person")
            # Labels first (marked forgotten: their voice is never stored again), then their vectors,
            # then the voice data itself; a retry after a crash finishes whatever is left.
            affected = self.store.labeled_with(person_id)
            for conv_id in affected:
                states = {
                    label: (s | {"person_id": None, "source": None, "forgotten": True} if s.get("person_id") == person_id else s)
                    | {"not": [x for x in s.get("not") or [] if x != person_id]}
                    for label, s in self.store.labels(conv_id).items()
                }
                row = self.db.one("SELECT transcript_sha, note_path FROM conversations WHERE id=?", (conv_id,))
                self.store.write_labels(conv_id, states, transcript_sha=row["transcript_sha"] if row else None)
                if row and row["note_path"]:
                    self.pipeline._set(conv_id, needs_render=1, next_attempt_at=None)
            self.store.reconcile_vectors()
            self.store.forget_voice(person_id, delete_note=delete_note)
            self.db.set_meta("relabel_pending", "1")
        return affected

    # -- conversation speakers -------------------------------------------------------------------

    def _conversation(self, conv_id: str):
        row = self.db.one("SELECT * FROM conversations WHERE id=?", (conv_id,))
        if row is None or row["status"] == "open":
            raise ApiError(404, "not_found", "unknown conversation")
        return row

    def _transcript(self, conv_id: str) -> dict:
        path = self.pipeline.conv_dir(conv_id) / "transcript.json"
        if not path.exists():
            raise ApiError(409, "not_transcribed", "the conversation has no transcript yet")
        return json.loads(path.read_text())

    def _clips(self, conv_id: str, transcript: dict) -> dict[str, list[list[float]]]:
        stored = {label: v.clips for label, v in self.store.voices(conv_id).items() if v.clips}
        return stored | {k: v for k, v in (transcript.get("speaker_clips") or {}).items() if k not in stored}

    def audio_available(self, row) -> bool:
        return self.store.raw_available(row)

    def conversation_speakers(self, conv_id: str) -> dict:
        row = self._conversation(conv_id)
        transcript = self._transcript(conv_id)
        return {
            "revision": row["speakers_revision"],
            "transcript_sha": row["transcript_sha"],
            "labels": self._label_list(conv_id, transcript),
            "audio_available": self.audio_available(row),
        }

    def _label_list(self, conv_id: str, transcript: dict) -> list[dict]:
        segments = transcript.get("segments") or []
        labels = sorted({s["speaker"] for s in segments}, key=speaker_match._label_key)
        states = self.store.labels(conv_id)
        people = {p["id"]: p for p in self.store.people()}
        clips = self._clips(conv_id, transcript)
        out = []
        for label in labels:
            st = states.get(label, {})
            person = people.get(st.get("person_id")) if st.get("person_id") else None
            text = next((s["text"] for s in segments if s["speaker"] == label), "")
            out.append({
                "label": label,
                "person_id": person["id"] if person else None,
                "name": person["name"] if person else None,
                "source": st.get("source") if person else None,
                "distance": st.get("distance"),
                "margin": st.get("margin"),
                "evidence_s": st.get("evidence_s"),
                "clip_id": f"{conv_id}.{label}.0" if clips.get(label) else None,
                "excerpt": text[:EXCERPT_CHARS],
            })  # fmt: skip
        return out

    def assign(self, conv_id: str, label: str, body: dict) -> Outcome:
        person_id = body.get("person_id")
        not_person = body.get("not_person_id")
        expected = body.get("expected_revision")
        request_id = body.get("request_id")
        if not isinstance(expected, int) or isinstance(expected, bool):
            raise ApiError(422, "invalid_body", "expected_revision (integer) is required")
        if not isinstance(request_id, str) or not request_id or len(request_id) > 100:
            raise ApiError(422, "invalid_body", "request_id is required")
        for value, what in ((person_id, "person_id"), (not_person, "not_person_id")):
            if value is not None and (not isinstance(value, str) or not UUID_RE.match(value)):
                raise ApiError(422, "invalid_body", f"{what} must be a lowercase UUID or null")
        with self.store.lock:
            self.store.sync_conversation(conv_id)  # an earlier attempt may have failed after its file write
            self.store.sync_samples()
            row = self._conversation(conv_id)
            transcript = self._transcript(conv_id)
            if label not in {s["speaker"] for s in transcript.get("segments") or []}:
                raise ApiError(404, "not_found", f"conversation has no speaker {label}")
            done = self.store.request_result(conv_id, request_id)
            if done is not None:  # a retry of an applied request: answer with the current state
                return Outcome(row["speakers_revision"], self._label_list(conv_id, transcript), [], done.get("sample", "none"))
            if expected != row["speakers_revision"]:
                raise ApiError(409, "stale_revision", f"speakers are at revision {row['speakers_revision']}")
            for pid in (person_id, not_person):
                if pid is not None and self.store.person(pid) is None:
                    raise ApiError(404, "not_found", f"unknown person {pid}")
            states = self.store.labels(conv_id)
            state = dict(states.get(label) or {})
            blocked = set(state.get("not") or [])
            sample = "none"
            if not_person:
                blocked.add(not_person)
                if state.get("person_id") == not_person:
                    state |= {"person_id": None, "source": None}
            if person_id:
                blocked.discard(person_id)
                state |= {"person_id": person_id, "source": "user", "forgotten": False}
                sample = self._sample_for(row, transcript, label, person_id, request_id)
            elif not not_person:
                state |= {"person_id": None, "source": None}
            state["not"] = sorted(blocked)
            previous = (states.get(label) or {}).get("person_id")
            if previous and previous != state.get("person_id"):
                # the user took this label back from `previous`: so is the voiceprint it gave them
                self.store.remove_samples(conv_id, label, previous)
            states[label] = state
            revision = self.store.write_labels(conv_id, states, transcript_sha=row["transcript_sha"],
                                               request=(request_id, {"label": label, "person_id": person_id, "sample": sample}))  # fmt: skip
            if row["note_path"]:
                self.pipeline._set(conv_id, needs_render=1, next_attempt_at=None)
            relabeled = self._relabel(exclude={conv_id}) if sample in ("created", "exists") or person_id else []
            # the relabel pass may also refresh this conversation's other labels: report the latest
            revision = self.db.one("SELECT speakers_revision FROM conversations WHERE id=?", (conv_id,))[0]
            return Outcome(revision, self._label_list(conv_id, transcript), relabeled, sample)

    def _relabel(self, exclude: set[str] = frozenset()) -> list[str]:
        """Re-run the assignment everywhere (people/samples changed); the conversations it relabeled."""
        self.db.set_meta("relabel_pending", "1")
        return sorted(set(self.pipeline.relabel(time.time())) - set(exclude))

    def _sample_for(self, row, transcript: dict, label: str, person_id: str, request_id: str) -> str:
        """A confirmed voiceprint from this label (deduplicated by request_id), if consented."""
        if self.store.sample_for_request(request_id) is not None:
            return "exists"
        person = self.store.person(person_id)
        prefs = self.store.settings()
        if not person["me"]:
            if not prefs["acknowledged_at"]:
                return "not_acknowledged"
            if not self.store.attested(person_id):
                return "not_attested"
        embedder = self.pipeline.providers.embedder
        if embedder is None:
            return "no_model"
        voice = self._label_voice(row, transcript, label, embedder)
        if voice is None or voice.vector is None:
            return "no_audio"
        day = datetime.fromtimestamp(row["start"], self.pipeline.tz).date().isoformat()
        self.store.add_sample(person_id, voice.vector, model=embedder.model, model_sha=embedder.model_sha, source="user",
                              seconds=voice.seconds, day=day, session=row["id"], conversation_id=row["id"], label=label,
                              request_id=request_id)  # fmt: skip
        return "created"

    def _label_voice(self, row, transcript: dict, label: str, embedder):
        """The label's voice: stored, else recomputed from raw audio (kept in the voices file)."""
        stored = self.store.voices(row["id"]).get(label)
        if stored is not None and stored.vector is not None and (stored.model, stored.model_sha) == (embedder.model, embedder.model_sha):
            return stored
        clips = transcript.get("speaker_clips") or {}
        if not clips.get(label) or not self.audio_available(row):
            return None
        audio = self.pipeline.conversation_audio(row)
        all_clips = {lab: [Clip(a, b, i) for i, (a, b) in enumerate(spans)] for lab, spans in clips.items()}
        voices = embed_voices(all_clips, audio.pcm, embedder)
        # `label` is about to be confirmed for someone who passed the consent checks (`_sample_for`)
        keep = {label} | self.store.vector_labels(self.store.labels(row["id"]), set(voices), raw=True)
        name = voices_name(embedder, row["audio_sha"], row["transcript_sha"])
        self.store.write_voices(row["id"], name, embedder.model, embedder.model_sha, voices, keep)
        self.store.remove_other_voices(row["id"], name)
        return voices.get(label)

    def resummarize(self, conv_id: str) -> None:
        if self._conversation(conv_id)["enrollment_id"]:
            raise ApiError(409, "voice_enrollment", "a voice-enrollment reading has no transcript or summary")
        self.db.execute(
            "UPDATE conversations SET reprocess_request = reprocess_request + 1, force_llm = 1 WHERE id=?", (conv_id,)
        )

    # -- suggestions -----------------------------------------------------------------------------

    def _suggestions(self, now: float) -> tuple[list[speaker_suggest.Suggestion], dict]:
        prefs = self.store.settings()
        if not prefs["unknown_voices_enabled"]:
            return [], prefs
        embedder = self.pipeline.providers.embedder
        candidates = []
        excerpts: dict[str, str] = {}
        for r in self.db.query(
            """SELECT v.*, c.start, c.blocks_json, c.device_id FROM voices v JOIN conversations c ON c.id = v.conversation_id
               LEFT JOIN speaker_labels l ON l.conversation_id = v.conversation_id AND l.label = v.label
               WHERE v.vector IS NOT NULL AND (l.person_id IS NULL)"""
        ):
            if embedder and (r["model"], r["model_sha"]) != (embedder.model, embedder.model_sha):
                continue
            if not self.audio_available(r):
                continue
            day = datetime.fromtimestamp(r["start"], self.pipeline.tz).date().isoformat()
            candidates.append(speaker_suggest.Candidate(r["conversation_id"], r["label"],
                                                        np.frombuffer(r["vector"], dtype="<f4").astype(np.float32),
                                                        r["seconds"], day, r["rms_db"]))  # fmt: skip
        key = (embedder.model, embedder.model_sha) if embedder else None
        models = speaker_match.build_models(self.store.samples(*key), self.pipeline.operating) if key else {}
        dismissed = {k: float(v) for k, v in prefs["dismissed"].items()}
        found = speaker_suggest.suggestions(candidates, models, me_exists=self.store.me() is not None, dismissed=dismissed,
                                            now=now, limit=len(candidates) or 1)  # fmt: skip
        del excerpts
        return found, prefs

    def suggestions(self, limit: int, now: float | None = None) -> list[dict]:
        now = time.time() if now is None else now
        found, _ = self._suggestions(now)
        out = []
        for s in found[:limit]:
            rep = s.representative
            transcript = self._transcript(rep.conversation_id)
            excerpt = next((seg["text"] for seg in transcript.get("segments") or [] if seg["speaker"] == rep.label), "")
            out.append({"id": s.id, "kind": s.kind, "person_id": s.person_id,
                        "clip_id": f"{rep.conversation_id}.{rep.label}.0", "seconds": s.seconds,
                        "excerpt": excerpt[:EXCERPT_CHARS], "conversations": s.conversations, "days": s.days})  # fmt: skip
        return out

    def dismiss(self, suggestion_id: str, now: float | None = None) -> None:
        now = time.time() if now is None else now
        prefs = self.store.settings()
        dismissed = {k: v for k, v in prefs["dismissed"].items() if float(v) > now}
        dismissed[suggestion_id] = now + speaker_suggest.COOLDOWN
        self.store.update_settings(dismissed=dismissed)

    def assign_suggestion(self, suggestion_id: str, body: dict, now: float | None = None) -> list[str]:
        now = time.time() if now is None else now
        person_id, request_id = body.get("person_id"), body.get("request_id")
        if not isinstance(person_id, str) or not UUID_RE.match(person_id):
            raise ApiError(422, "invalid_body", "person_id must be a lowercase UUID")
        if not isinstance(request_id, str) or not request_id:
            raise ApiError(422, "invalid_body", "request_id is required")
        with self.store.lock:
            found, _ = self._suggestions(now)
            suggestion = next((s for s in found if s.id == suggestion_id), None)
            if suggestion is None:
                raise ApiError(404, "not_found", "the suggestion no longer exists")
            if self.store.person(person_id) is None:
                raise ApiError(404, "not_found", f"unknown person {person_id}")
            touched = []
            for member in suggestion.members:
                row = self.db.one("SELECT * FROM conversations WHERE id=?", (member.conversation_id,))
                self.assign(member.conversation_id, member.label,
                            {"person_id": person_id, "expected_revision": row["speakers_revision"],
                             "request_id": f"{request_id}:{member.conversation_id}:{member.label}"})  # fmt: skip
                touched.append(member.conversation_id)
            return sorted(set(touched) | set(self._relabel()))

    # -- settings --------------------------------------------------------------------------------

    def enrollment_status(self, enrollment_id: str) -> dict | None:
        return enroll.status(self.pipeline.vault, self.db, enrollment_id)

    def get_settings(self) -> dict:
        prefs = self.store.settings()
        return {"acknowledged_at": prefs["acknowledged_at"], "unknown_voices_enabled": prefs["unknown_voices_enabled"],
                "auto_assign": prefs["auto_assign"]}  # fmt: skip

    def put_settings(self, body: dict) -> dict:
        changes: dict = {}
        if "acknowledged_at" in body:
            value = body["acknowledged_at"]
            if value is not None:
                if not isinstance(value, str):
                    raise ApiError(422, "invalid_body", "acknowledged_at must be an ISO-8601 string or null")
                try:
                    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                except ValueError as exc:
                    raise ApiError(422, "invalid_body", "acknowledged_at must be an ISO-8601 string or null") from exc
                if parsed.tzinfo is None:
                    raise ApiError(422, "invalid_body", "acknowledged_at must include a timezone")
                value = iso_utc_epoch(parsed.astimezone(UTC).timestamp())
            changes["acknowledged_at"] = value
        for key in ("unknown_voices_enabled", "auto_assign"):
            if key in body:
                if not isinstance(body[key], bool):
                    raise ApiError(422, "invalid_body", f"{key} must be a boolean")
                changes[key] = body[key]
        with self.store.lock:
            before = self.store.settings()
            self.store.update_settings(**changes)
            self.store.reconcile_vectors()  # e.g. unknown voices off or the acknowledgment withdrawn
            if "auto_assign" in changes and changes["auto_assign"] != before["auto_assign"]:
                self.db.set_meta("relabel_pending", "1")
        return self.get_settings()

    # -- clips -----------------------------------------------------------------------------------

    def clip_wav(self, clip_id: str) -> bytes:
        conv_id, _, rest = clip_id.partition(".")
        label, _, index = rest.partition(".")
        if not UUID_RE.match(conv_id) or not label or not index.isdigit():
            raise ApiError(404, "not_found", "unknown clip")
        row = self._conversation(conv_id)
        transcript = self._transcript(conv_id)
        spans = self._clips(conv_id, transcript).get(label) or []
        if int(index) >= len(spans):
            raise ApiError(404, "not_found", "unknown clip")
        start, end = spans[int(index)]
        end = min(end, start + MAX_CLIP_SECONDS)
        if not self.audio_available(row):
            raise ApiError(410, "audio_expired", "the raw audio of this conversation has expired")
        audio = self.pipeline.conversation_audio(row)
        pcm = audio.pcm[int(round(start * 16000)) : int(round(end * 16000))]
        if not len(pcm):
            raise ApiError(410, "audio_expired", "no audio for this clip")
        buf = io.BytesIO()
        sf.write(buf, pcm, 16000, format="WAV", subtype="PCM_16")
        return buf.getvalue()

