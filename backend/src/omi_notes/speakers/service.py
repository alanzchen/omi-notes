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
import os
import threading
import time
from dataclasses import dataclass
from datetime import UTC, datetime

import numpy as np
import soundfile as sf

from .. import operations
from ..audio import pitch
from ..ingest import ApiError
from ..util import UUID_RE, iso_utc_epoch
from . import enroll
from . import match as speaker_match
from . import suggest as speaker_suggest
from . import journal
from .review import Review, status_line
from .store import FROZEN, same_clips, sample_eligible, voices_name
from ..vault import Vault
from .voices import Clip, LabelVoice, embed_voices

log = logging.getLogger(__name__)

MAX_CLIP_SECONDS = 10.0
# The worker re-reads People notes at least this often (an edit inside a note doesn't change its folder's mtime).
PEOPLE_RECONCILE_SECONDS = 300.0
# legacy suggestions kept in the snapshot: the endpoint's largest page
SUGGESTIONS_KEPT = 20
EXCERPT_CHARS = 140
# A person card's voice fields with no voice behind them (a forgotten voice, or a stored card the index can't vouch for)
NO_VOICE = {"samples": 0, "sessions": 0, "samples_active": 0, "samples_flagged": 0, "samples_removed": 0, "review_count": 0,
            "auto_active": False, "voice_ready": False, "measured": None, "status_line": None}
CLIP_TEXT_CHARS = 240


@dataclass
class Outcome:
    revision: int
    labels: list[dict]
    relabeled: list[str]
    sample: str  # created | exists | not_acknowledged | not_attested | no_audio | none


@dataclass(frozen=True)
class PeopleSnapshot:
    """What GET /v1/people and GET /v1/speakers/suggestions serve. `generation` is taken when its build started."""

    people: list
    suggestions: list | None
    generation: int
    built_at: float | None
    inputs: tuple | None
    ready: bool
    stale: bool = False
    wearer: str | None = None  # the "me" person's id, so a suggestions page needn't scan people (Astra IT2B-07)
    by_id: dict | None = None  # people by id: one person's answer without copying every card (Astra IT3-06)
    calibration_stale: bool | None = None  # computed by the build (the GET never gathers calibration inputs)


class SpeakerService:
    def __init__(self, pipeline) -> None:
        self.pipeline = pipeline
        self.store = pipeline.speakers
        self.db = pipeline.db
        self.vault = pipeline.vault
        self.review = Review(self)
        self._set_aside_key = None
        # the people snapshot (IT1-01): built only by the worker (`warm`) and by mutations, read by GETs
        self._people_lock = threading.Lock()
        self._people_seq = 0  # the last generation handed to a build
        self._people_floor = 0  # builds that started at or before a failed post-mutation build can't publish
        self._people_reconciled_at: float | None = None
        self._people_cache = self.db.path.parent / "people.json"  # operational cache beside the index, never vault data
        self._people = self._load_people_cache()
        self._served_prefs = self.store.settings()  # the settings served outputs apply at once (`served_blocked`)
        # Read-your-write overlays (metadata and suppression only, never identity math), each tagged with the generation
        # current at its mutation and dropped once a build that started after it publishes: a PUT person's fields, a
        # forgotten person, a suggestion dismissed or acted on.
        self._people_overlay: dict[str, tuple[int, dict]] = {}
        self._forgotten: dict[str, int] = {}
        self._hidden_suggestions: dict[str, int] = {}

    # -- people ----------------------------------------------------------------------------------

    def people(self) -> list[dict]:
        return self.people_answer()["people"]

    def people_answer(self) -> dict:
        """GET /v1/people: the published snapshot, never a scan. `ready` false: no build in this process yet (the
        stored copy, or nothing) or the last post-mutation build failed (`stale`: the worker rebuilds it next tick).
        Older clients read only `people`."""
        snap, overlay, forgotten, wearer = self._view()
        people = [p for p in snap.people if p["id"] not in forgotten and p["id"] not in overlay]
        people += [(snap.by_id or {}).get(pid, {}) | f for pid, (_, f) in overlay.items()]
        people = [self._served_person(p, wearer) for p in people]
        out = {"people": people, "ready": snap.ready and not snap.stale, "generation": snap.generation,
               "as_of": iso_utc_epoch(snap.built_at) if snap.built_at else None}  # fmt: skip
        if snap.stale:
            out["stale"] = True
        return out

    def _view(self) -> tuple:
        """The snapshot and the overlays, read together, and the one wearer they imply (Astra IT3-03): the latest PUT
        that set "me", else the snapshot's wearer unless a PUT cleared it or it was forgotten since."""
        with self._people_lock:
            snap, overlay, forgotten = self._people, dict(self._people_overlay), set(self._forgotten)
        mine = [(tag, pid) for pid, (tag, f) in overlay.items() if f.get("me")]
        wearer = max(mine)[1] if mine else snap.wearer
        if wearer in forgotten or (not mine and wearer in overlay):
            wearer = None
        return snap, overlay, forgotten, wearer

    def _served_person(self, p: dict, wearer: str | None) -> dict:
        """A card as served: "me" is the effective wearer, then the settings in memory (`served_blocked`)."""
        p = p | {"me": p["id"] == wearer}
        if p.get("auto_active") and self.served_blocked(p["id"], p["me"], automatic=True):
            p |= {"auto_active": False, "status_line": "自动命名已关闭"}
        return p

    def _load_people_cache(self) -> PeopleSnapshot:
        """The stored snapshot, served until this process's first build (not ready). It is never authoritative over the
        index for privacy (Carbon IT2-01): who exists, their name and "me" come from `people`, a person without sample
        rows has no voice fields, automatic naming shows off and no suggestion is served until a build decides them."""
        try:
            data = json.loads(self._people_cache.read_text())
            if not isinstance(data["people"], list) or not isinstance(data.get("suggestions") or [], list):
                raise ValueError("people.json: people is not a list")  # C2-04
            stored, built_at = {p.get("id"): p for p in data["people"] if isinstance(p, dict)}, float(data["built_at"])
        except (OSError, ValueError, KeyError, TypeError):
            stored, built_at = None, None
        voiced = {r[0] for r in self.db.query("SELECT DISTINCT person_id FROM samples")}
        people = [(stored or {}).get(r["id"], {}) | {"id": r["id"], "name": r["name"], "me": bool(r["me"]), "note_path": r["note_path"]}
                  | ({"auto_active": False, "status_line": None} if r["id"] in voiced else NO_VOICE)
                  for r in self.db.query("SELECT id, name, me, note_path FROM people ORDER BY me DESC, name")] if stored is not None else []
        return PeopleSnapshot(people=people, suggestions=None, generation=0, by_id={p["id"]: p for p in people},
                              wearer=next((p["id"] for p in people if p["me"]), None), built_at=built_at, inputs=None, ready=False)

    def _people_inputs(self) -> tuple:
        """What the snapshot depends on, cheaply (worker only): the evidence digest (samples, labels, people, consent,
        speaker settings), the calibration file and the People folders' own mtimes (a note added, removed or renamed)."""
        embedder = self.pipeline.providers.embedder
        key = self.store.evidence_key(embedder.model if embedder else "", embedder.model_sha if embedder else "")

        def stat(path):
            try:
                st = path.stat()
                return (st.st_mtime_ns, st.st_size)
            except OSError:
                return None

        from .store import PEOPLE_DIR

        skipped = tuple(sorted((stem, bad) for stem, (_, _, bad) in self.store.skipped_samples.items()))  # D1-03
        # who may be named (I1): a consent file torn or withdrawn changes no index row, but changes the snapshot (IT2B-04)
        return (key, stat(self.vault.speakers / "calibration.json"), stat(self.vault.root / PEOPLE_DIR),
                stat(self.vault.people), skipped, self.store.naming_people())  # fmt: skip

    def refresh_people(self, now: float | None = None) -> bool:
        """Build and publish the snapshot; never raises. The generation is taken before any input is read, so a build
        that started later saw every change committed before it, and a slower, earlier build finishing afterwards is
        dropped. A failure marks the served snapshot stale (not ready) and bars every build that started before it,
        so a build that can't contain the change that just committed never publishes; the worker retries."""
        # Under the speaker lock, which every mutation holds while it writes (C2-01): the generation is taken, the
        # People notes scanned and the answer computed with no mutation in between, so generation N reflects every
        # mutation that finished before N was taken, and no earlier build's index write can land inside this one.
        with self.store.lock:
            with self._people_lock:
                self._people_seq += 1
                gen = self._people_seq
            problems: list[str] = []
            try:
                self.store.scan_people()
                self.store.sync_samples()
                inputs = self._people_inputs()
                people = self._compute_people(problems)
                suggestions = self._compute_suggestions(time.time() if now is None else now, problems=problems)
                calibration_stale = self._calibration_stale()
                self._publish_problems(problems)
            except Exception:
                log.exception("could not build the people snapshot (generation %s)", gen)
                self._mark_people_stale(gen)
                return False
            built = PeopleSnapshot(people=people, suggestions=suggestions, generation=gen, built_at=time.time(),
                                   inputs=inputs, ready=True, wearer=next((p["id"] for p in people if p["me"]), None),
                                   by_id={p["id"]: p for p in people}, calibration_stale=calibration_stale)  # fmt: skip
            with self._people_lock:  # the file is written under the lock too, so it never goes back to an older build
                if gen <= self._people.generation or gen <= self._people_floor:
                    return False
                self._people = built
                # an overlay is served until a build that started after its mutation publishes
                self._people_overlay = {pid: (tag, f) for pid, (tag, f) in self._people_overlay.items() if tag >= gen}
                self._forgotten = {pid: tag for pid, tag in self._forgotten.items() if tag >= gen}
                self._hidden_suggestions = {sid: tag for sid, tag in self._hidden_suggestions.items() if tag >= gen}
                try:
                    self._write_people_cache(built)
                except OSError:
                    log.exception("could not write %s (cache only: the snapshot in memory is current)", self._people_cache)
        return True

    def _publish_problems(self, extra: list[str]) -> None:
        """The speaker files this build skipped (C2-02), as a count and five examples for /v1/issues: a sample, consent,
        calibration or transcript file that can't be read never stops People, and is never silent."""
        bad = sorted({rel for rel, _, unreadable in self.store.skipped_samples.values() if unreadable}
                     | set(self.store.unreadable_consent.values()) | set(self.store.prune_failures.values()) | set(extra))  # fmt: skip
        value = json.dumps({"count": len(bad), "examples": bad[:5]}) if bad else None
        if self.db.meta("speaker_files_unreadable") != value:
            self.db.set_meta("speaker_files_unreadable", value)
            if bad:
                log.warning("speaker files unreadable, skipped: %d (%s)", len(bad), ", ".join(bad[:5]))

    def _mark_people_stale(self, gen: int | None = None) -> None:
        """The served snapshot may hide a change: not ready until a build that started after this point publishes
        (every build that started before it is barred: it may predate the change)."""
        with self._people_lock:
            if gen is None:
                self._people_seq += 1
                gen = self._people_seq
            self._people_floor = max(self._people_floor, gen)
            if not self._people.stale:
                self._people = PeopleSnapshot(**{**self._people.__dict__, "stale": True})

    def _write_people_cache(self, snap: PeopleSnapshot) -> None:
        """Temp file and rename: a reader or a crash sees the old copy or the new one, never part of one."""
        tmp = self._people_cache.with_name(f"people.json.{os.getpid()}.{threading.get_ident()}.tmp")
        try:
            tmp.write_text(json.dumps({"generation": snap.generation, "built_at": snap.built_at, "people": snap.people,
                                       "suggestions": snap.suggestions}))  # fmt: skip
            os.replace(tmp, self._people_cache)
        finally:
            tmp.unlink(missing_ok=True)

    def warm_people(self, now: float | None = None) -> None:
        """The worker's part (each tick): rebuild when there's no current snapshot, it's stale, its inputs changed, or
        the reconcile interval passed (a note's content edited in Obsidian)."""
        now = time.time() if now is None else now
        with self._people_lock:
            snap = self._people
        due = self._people_reconciled_at is None or now - self._people_reconciled_at >= PEOPLE_RECONCILE_SECONDS
        if snap.ready and not snap.stale and not due and snap.inputs == self._people_inputs():
            return
        if due:
            self._people_reconciled_at = now
        self.refresh_people(now)

    def _compute_people(self, problems: list[str] | None = None) -> list[dict]:
        """Today's answer, computed (a build; never a GET). `problems` collects files it skipped."""
        embedder = self.pipeline.providers.embedder
        key = (embedder.model, embedder.model_sha) if embedder else None
        models = self.store.models(*key, self.pipeline.operating) if key else {}  # naming people only (I1)
        auto_assign = self.store.settings()["auto_assign"]
        calibration = self.calibration_people(problems)
        naming = self.store.naming_people()
        out = []
        for p in self.store.people():
            rows = [r for r in self.db.query("SELECT * FROM samples WHERE person_id=?", (p["id"],)) if sample_eligible(r)]
            model = models.get(p["id"])
            counts = self.review.counts(p["id"])
            measured = calibration.get("people", {}).get(p["id"], {}).get("measured")
            out.append({
                "id": p["id"], "name": p["name"], "me": bool(p["me"]), "note_path": p["note_path"],
                "samples": len(rows), "sessions": len({r["session"] for r in rows if r["session"]}),
                "auto_active": bool(model and model.active),
                "voice_ready": bool(model and model.centroid is not None),
                **counts, "status_line": (status_line(model, counts["samples_active"], auto_assign)
                                          if p["id"] in naming or not rows else "自动命名已关闭"),
                "calibrated_at": calibration.get("computed_at"), "measured": measured,
            })  # fmt: skip
        return out

    def import_enrollment(self, person_id: str, fields: dict, upload) -> tuple[int, dict]:
        """`POST /v1/people/{id}/enrollments/import` (`speakers.imports`)."""
        from .imports import Importer

        return Importer(self).run(person_id, fields, upload)

    def calibration_people(self, problems: list[str] | None = None) -> dict:
        """The last published calibration (`speakers.calibration`), {} before the first, or when it can't be read (then
        recorded in `problems`: the people list doesn't wait for it)."""
        path = self.vault.speakers / "calibration.json"
        try:
            data = Vault.read_json(path) or {}
            if not isinstance(data, dict):
                raise ValueError("not an object")
            return data
        except (OSError, ValueError) as exc:
            if problems is None:
                raise
            log.warning("speaker file unreadable, skipped: %s (%s)", self.vault.relpath(path), exc)
            problems.append(self.vault.relpath(path))
            return {}

    def calibration(self) -> dict:
        """`GET /v1/speakers/calibration`: the last published calibration and whether its inputs changed since, as the
        worker's last build found (no inputs gathered on the request)."""
        from .calibration import Calibrator

        current = Calibrator(self.pipeline).current()
        pending = self.db.meta("calibrate_pending") is not None
        with self._people_lock:
            stale = self._people.calibration_stale
        return {"calibration": current, "stale": current is None or pending or bool(stale), "pending": pending}

    def _calibration_stale(self) -> bool | None:
        from .calibration import Calibrator

        calibrator = Calibrator(self.pipeline)
        try:
            current = calibrator.current()
            return current is None or current.get("fingerprint") != calibrator.fingerprint()
        except Exception:  # an unreadable input: not known to be current
            log.exception("could not compare the calibration with its inputs")
            return True

    # -- review and samples (`speakers.review`) ---------------------------------------------------

    def warm(self, now: float | None = None) -> None:
        """Rebuild what changed since the last request (the review queue's order and, through it, the voice
        space) so requests only slice cached results; a no-op when nothing changed. Called by the worker."""
        self._served_prefs = self.store.settings()  # each tick too: a settings file changed another way is served
        embedder = self.pipeline.providers.embedder
        if embedder is not None:
            try:
                key = self.store.evidence_key(embedder.model, embedder.model_sha)
                if key != self._set_aside_key:  # flagged samples nobody can listen to leave the queue (once per change)
                    self.review.set_aside_unplayable()
                    self._set_aside_key = self.store.evidence_key(embedder.model, embedder.model_sha)
                self.review.entries()
            except Exception:  # the review queue failing doesn't hold People back (C2-02)
                log.exception("could not warm the voice review queue")
        self.warm_people(now)

    def review_items(self, limit: int, offset: int = 0) -> dict:
        return self.review.page(limit, offset)

    def review_decide(self, item_id: str, body: dict) -> dict:
        return self.review.decide(item_id, body)

    def person_samples(self, person_id: str, state: str | None) -> list[dict]:
        return self.review.person_samples(person_id, state)

    def sample_action(self, sample_id: str, action: str, body: dict) -> dict:
        if not UUID_RE.match(sample_id):
            raise ApiError(404, "not_found", "unknown sample")
        request_id = body.get("request_id")
        if not isinstance(request_id, str) or not request_id or len(request_id) > 100:
            raise ApiError(422, "invalid_body", "request_id is required")
        expected = body.get("expected_revision")
        if expected is not None and (not isinstance(expected, int) or isinstance(expected, bool)):
            raise ApiError(422, "invalid_body", "expected_revision must be an integer")
        person_id = body.get("person_id")
        if action == "move" and (not isinstance(person_id, str) or not UUID_RE.match(person_id)):
            raise ApiError(422, "invalid_body", "a move needs person_id (a lowercase UUID)")
        result = self.review.sample_decision(sample_id, action, request_id, expected_revision=expected, person_id=person_id)
        return result | {"request_id": request_id, "undo_token": request_id}

    def put_person(self, person_id: str, body: dict) -> tuple[int, dict]:
        """Intent only (I4 for PUT person; Astra IT2B-08): the note and this person's index row are written, a relabel
        is marked, and this person's fields are served from an overlay until the worker's next build publishes. No
        global rebuild on the request: the snapshot rebuild is the worker's. The answer is the person as now served."""
        with self.store.lock:  # the overlay too (Carbon IT2-01): a forget can't land between the write and it
            created = self._put_person_write(person_id, body)
            row = self.store.person(person_id)
            fields = {"id": person_id, "name": row["name"], "me": bool(row["me"]), "note_path": row["note_path"]}
            with self._people_lock:
                if fields["me"]:  # at most one wearer: the latest PUT wins in the overlay too
                    self._people_overlay = {pid: (tag, f | {"me": False}) for pid, (tag, f) in self._people_overlay.items()}
                # merged: a forgotten voice's zeroed fields stay until a build
                self._people_overlay[person_id] = (self._people_seq, self._people_overlay.get(person_id, (0, {}))[1] | fields)
                self._forgotten.pop(person_id, None)
        snap, overlay, _, wearer = self._view()
        return (201 if created else 200), self._served_person((snap.by_id or {}).get(person_id, {}) | overlay[person_id][1], wearer)

    def _put_person_write(self, person_id: str, body: dict) -> bool:
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
            self.store.samples_changed()  # consent or the wearer may have changed: recalibrate
        return created

    def forget(self, person_id: str, *, delete_note: bool) -> list[str]:
        with self.store.lock:
            if self.store.person(person_id) is None and not self.store.person_dir(person_id).exists():
                raise ApiError(404, "not_found", "unknown person")
            # 1. the index agrees with every speakers.json; 2. the person's labels are marked
            # forgotten, before anything can move them (a pending or in-flight move to a new
            # transcript carries the marker instead of dropping the association); 3. pending moves
            # finish and voices generations nothing depends on go; 4. vectors, then the voice data.
            # A retry after a crash finishes whatever is left. An interrupted journaled operation finishes first; one
            # touching this person that can't is cancelled (with the forget's durable start), or the forget stops.
            self.store.reconcile()
            self.store.begin_forget(person_id)
            self.pipeline.sync_labels_everywhere()
            affected = self.store.labeled_with(person_id)
            for conv_id in affected:
                states = {
                    label: (s | {"person_id": None, "source": None, "forgotten": True} if s.get("person_id") == person_id else s)
                    | {"not": [x for x in s.get("not") or [] if x != person_id]}
                    for label, s in self.store.labels(conv_id).items()
                }
                row = self.db.one("SELECT transcript_sha, note_path FROM conversations WHERE id=?", (conv_id,))
                self.store.write_labels(conv_id, states)
                if row and row["note_path"]:
                    self.pipeline._set(conv_id, needs_render=1, next_attempt_at=None)
            self.pipeline.finish_migrations()
            self.store.remove_obsolete_voices_everywhere()
            self.store.reconcile_vectors()
            self.store.forget_voice(person_id, delete_note=delete_note)
            self.store.samples_changed()
            self.db.set_meta("relabel_pending", "1")
            kept = self.store.person(person_id)  # the note kept: the person stays, with no voice (Carbon IT2-01)
            with self._people_lock:  # served now; the worker's next build agrees
                self._people_overlay.pop(person_id, None)
                if kept is None:
                    self._forgotten[person_id] = self._people_seq
                else:
                    self._people_overlay[person_id] = (self._people_seq, NO_VOICE | {
                        "id": person_id, "name": kept["name"], "me": bool(kept["me"]), "note_path": kept["note_path"]})
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
        stored = {label: v.clips for label, v in self.store.voices(conv_id).items() if v.clips and self._current(v, transcript)}
        return stored | {k: v for k, v in (transcript.get("speaker_clips") or {}).items() if k not in stored}

    @staticmethod
    def _current(voice, transcript: dict) -> bool:
        """A stored voice still describes this transcript: embedded from its clip bounds (a transcript from
        before `speaker_clips` has nothing to compare). Otherwise (an interrupted reprocess with corrected
        bounds) it is never offered or confirmed: the transcript's clips are, and the voice is rebuilt."""
        if "speaker_clips" not in transcript:
            return True
        return same_clips(voice.clips, (transcript.get("speaker_clips") or {}).get(voice.label) or [])

    def audio_available(self, row) -> bool:
        return self.store.raw_available(row)

    def conversation_speakers(self, conv_id: str) -> dict:
        """Side-effect free (Astra IT3-05): recovery and label moves are the worker's; while a move is pending the labels
        are served without names (`_label_list`), and a change accepts the revision shown here (`assign`)."""
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
        states = {} if self.store.move_pending(conv_id) else self.store.labels(conv_id)  # no names across generations
        ids = sorted({st["person_id"] for st in states.values() if st.get("person_id")})
        people = {p["id"]: p for p in self.db.query(f"SELECT * FROM people WHERE id IN ({','.join('?' * len(ids))})", ids)}
        clips = self._clips(conv_id, transcript)
        out = []
        for label in labels:
            st = states.get(label, {})
            person = people.get(st.get("person_id")) if st.get("person_id") else None
            if person is not None and st.get("source") == "auto" and self.served_blocked(person["id"], bool(person["me"]), automatic=True):
                person = None  # an automatic name the settings no longer allow, before the worker's relabel (Astra IT2B-05)
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
                "clips": self._clip_list(conv_id, transcript, label, clips.get(label) or []),
                "excerpt": text[:EXCERPT_CHARS],
                "kept_unknown": st.get("source") == "unknown",
            })  # fmt: skip
        return out

    def _clip_list(self, conv_id: str, transcript: dict, label: str, spans: list) -> list[dict]:
        """Each playable clip with the transcript text it overlaps (phrase level: the transcript has
        no word timing to align with, so nothing is highlighted); "" when nothing overlaps it."""
        timemap = transcript.get("timemap") or []

        def wall(t: float) -> float:
            for out_start, wall_start, duration in timemap:
                if out_start <= t <= out_start + duration:
                    return wall_start + (t - out_start)
            near = min(timemap, key=lambda m: min(abs(t - m[0]), abs(t - m[0] - m[2])), default=None)
            return near[1] + min(max(t - near[0], 0.0), near[2]) if near else t

        segments = [seg for seg in transcript.get("segments") or [] if seg["speaker"] == label]
        out = []
        for i, (a, b) in enumerate(spans):
            b = min(b, a + MAX_CLIP_SECONDS)
            lo, hi = wall(a), wall(b)
            # only what overlaps the clip; no overlap means no text, never a sentence from another moment
            text = " ".join(seg["text"] for seg in segments if seg["start"] < hi and seg["end"] > lo)
            out.append({"id": f"{conv_id}.{label}.{i}", "seconds": round(b - a, 2), "started_at": iso_utc_epoch(lo),
                        "text": text[:CLIP_TEXT_CHARS] + ("…" if len(text) > CLIP_TEXT_CHARS else "")})  # fmt: skip
        return out

    def assign(self, conv_id: str, label: str, body: dict) -> Outcome:
        person_id = body.get("person_id")
        not_person = body.get("not_person_id")
        keep_unknown = body.get("keep_unknown", False)
        expected = body.get("expected_revision")
        request_id = body.get("request_id")
        if not isinstance(expected, int) or isinstance(expected, bool):
            raise ApiError(422, "invalid_body", "expected_revision (integer) is required")
        if not isinstance(request_id, str) or not request_id or len(request_id) > 100:
            raise ApiError(422, "invalid_body", "request_id is required")
        for value, what in ((person_id, "person_id"), (not_person, "not_person_id")):
            if value is not None and (not isinstance(value, str) or not UUID_RE.match(value)):
                raise ApiError(422, "invalid_body", f"{what} must be a lowercase UUID or null")
        if not isinstance(keep_unknown, bool) or (keep_unknown and person_id):
            raise ApiError(422, "invalid_body", "keep_unknown is a boolean and excludes person_id")
        with self.store.lock:
            self.store.sync_conversation(conv_id)  # an earlier attempt may have failed after its file write
            # recovery first: it may change this label (and its revision); everything below reads after it
            self.store.reconcile()
            shown = self._conversation(conv_id)["speakers_revision"]
            # a move to another transcript makes a revision read before it stale (Carbon IT2-03); adopting this
            # transcript's own voices file (crash recovery, same labels) doesn't
            same_transcript = not self.store.move_pending(conv_id)
            transcript = self._transcript(conv_id)
            self.pipeline.move_labels(conv_id, transcript)  # states of an earlier transcript don't apply
            if self.store.move_pending(conv_id):  # deferred (a FROZEN person): never one transcript's label on another's
                raise ApiError(409, "recovery_pending", "this conversation's speakers are waiting to move to its new transcript")
            row = self._conversation(conv_id)
            if label not in {s["speaker"] for s in transcript.get("segments") or []}:
                raise ApiError(404, "not_found", f"conversation has no speaker {label}")
            # before anything (a retry's answer included): an unfinished operation on this label or these people, or
            # an unfinished forget of the person named, must not be built on or raced
            current = (self.store.labels(conv_id).get(label) or {}).get("person_id")
            journal.blocking(self.store, {not_person, current}, labels={(conv_id, label)})
            journal.forgetting(self.store, {person_id})
            done = self.store.request_result(conv_id, request_id)
            if done is not None:  # a retry of an applied request: finish its work, answer with the current state
                self.db.set_meta("relabel_pending", "1")
                return Outcome(row["speakers_revision"], self._label_list(conv_id, transcript), [], done.get("sample", "none"))
            if expected != row["speakers_revision"] and not (same_transcript and expected == shown):
                raise ApiError(409, "stale_revision", f"speakers are at revision {row['speakers_revision']}")
            for pid in (person_id, not_person):
                if pid is not None and self.store.person(pid) is None:
                    raise ApiError(404, "not_found", f"unknown person {pid}")
            states = self.store.labels(conv_id)
            before = dict(states.get(label) or {})
            state = dict(before)
            blocked = set(state.get("not") or [])
            sample, sample_id = "none", None
            if not_person:
                blocked.add(not_person)
                if state.get("person_id") == not_person:
                    state |= {"person_id": None, "source": None}
            if person_id:
                blocked.discard(person_id)
                state |= {"person_id": person_id, "source": "user", "forgotten": False}
                sample, sample_id = self._sample_for(row, transcript, label, person_id, request_id)
            elif keep_unknown:
                # durable: an older backend would recompute this state away, so it must refuse the vault
                self.vault.raise_format(4)
                state |= {"person_id": None, "source": "unknown"}
            elif not not_person:
                state |= {"person_id": None, "source": None}
            state["not"] = sorted(blocked)
            previous = before.get("person_id")
            withdrawn: dict = {}
            if previous and previous != state.get("person_id"):
                # the user took this label back from `previous`: so are the voiceprints it gave them,
                # the ones the state lists (they moved with it across re-transcriptions) — never by
                # the label number, which may have belonged to another assignment then. Withdrawn,
                # not deleted, for an undo window (`SpeakerStore.withdraw_samples`).
                withdrawn = {"person_id": previous, "samples": sorted(before.get("samples") or [])}
                state["samples"] = []
            if sample_id:
                state["samples"] = sorted(set(state.get("samples") or []) | {sample_id})
            states[label] = state
            # what this request changed, so an undo can put back exactly that (and only while it stands)
            change = {"before": self.store.persisted({label: before}).get(label),
                      "after": self.store.persisted({label: state}).get(label)}  # fmt: skip
            revision = self.store.write_labels(conv_id, states, request=(request_id, {
                "label": label, "person_id": person_id, "sample": sample, "keep_unknown": keep_unknown,
                "withdrawn": withdrawn or None} | change))  # fmt: skip
            # after the record that names them, so a crash in between leaves them in use, never lost
            removed = len(self.store.withdraw_samples(withdrawn["person_id"], withdrawn["samples"], request_id)) if withdrawn else 0
            self.store.purge_withdrawn()
            if row["note_path"]:
                self.pipeline._set(conv_id, needs_render=1, next_attempt_at=None)
            # people's voices changed (a sample added or taken back): every assignment is re-run
            relabeled = self._relabel(exclude={conv_id}) if sample in ("created", "exists") or person_id or removed else []
            # the relabel pass may also refresh this conversation's other labels: report the latest
            revision = self.db.one("SELECT speakers_revision FROM conversations WHERE id=?", (conv_id,))[0]
            return Outcome(revision, self._label_list(conv_id, transcript), relabeled, sample)

    def _relabel(self, exclude: set[str] = frozenset()) -> list[str]:
        """People's voices changed: the assignment everywhere is re-run by the worker's next pass (never on a request;
        the phone doesn't read `relabeled_conversations`). Nothing is relabeled here."""
        self.db.set_meta("relabel_pending", "1")
        return []

    def _sample_for(self, row, transcript: dict, label: str, person_id: str, request_id: str) -> tuple[str, str | None]:
        """A confirmed voiceprint from this label (deduplicated by request_id), if consented:
        (outcome, sample id)."""
        done = self.store.sample_for_request(request_id)
        if done is not None:
            return "exists", done["id"]
        prefs = self.store.settings()
        if not self.store.may_gain(person_id, prefs):  # current, readable consent (I2), never the cached attestation
            return ("not_acknowledged" if not prefs["acknowledged_at"] else "not_attested"), None
        embedder = self.pipeline.providers.embedder
        if embedder is None:
            return "no_model", None
        voice = self._label_voice(row, transcript, label, embedder)
        if voice is None or voice.vector is None:
            return "no_audio", None
        day = datetime.fromtimestamp(row["start"], self.pipeline.tz).date().isoformat()
        sample_id = self.store.add_sample(person_id, voice.vector, model=embedder.model, model_sha=embedder.model_sha,
                                          source="user", seconds=voice.seconds, day=day, session=row["id"],
                                          conversation_id=row["id"], label=label, request_id=request_id,
                                          extra=self._provenance(row, transcript, label, voice))  # fmt: skip
        return "created", sample_id

    def _provenance(self, row, transcript: dict, label: str, voice) -> dict:
        """What a new sample keeps besides its vector: the clip bounds and voices file it was embedded from
        (so it can be played and re-measured), the phrase it overlaps (a caption that outlives the audio)
        and its F0, measured at the voices stage while the PCM was in hand (`audio.pitch`)."""
        spans = [[c.start, c.end] if isinstance(c, Clip) else [float(c[0]), float(c[1])] for c in voice.clips]
        clips = self._clip_list(row["id"], transcript, label, spans)
        out = {"clips": spans, "voices_file": getattr(voice, "file", None), "audio_sha": row["audio_sha"],
               "caption": next((c["text"] for c in clips if c["text"]), None)}  # fmt: skip
        if getattr(voice, "f0", None) is not None:
            out |= {"f0": voice.f0, "f0_voiced": voice.f0_voiced, "f0_source": "voices-stage", "f0_estimator": pitch.ESTIMATOR}
        return out

    def _label_voice(self, row, transcript: dict, label: str, embedder):
        """The label's voice: stored, else recomputed from raw audio (kept in the voices file)."""
        stored = self.store.voices(row["id"]).get(label)
        if stored is not None and stored.vector is not None and (stored.model, stored.model_sha) == (embedder.model, embedder.model_sha) \
                and self._current(stored, transcript):
            return stored
        clips = transcript.get("speaker_clips") or {}
        if not clips.get(label) or not self.audio_available(row):
            return None
        audio = self.pipeline.conversation_audio(row)
        # Only the label being confirmed is embedded (Astra IT2B-02, IT3-01): every other speaker's stored voice (vector,
        # F0) is carried over unchanged, so a FROZEN co-participant gains and loses nothing, and if this embedding fails
        # nothing is written or retired.
        model = (embedder.model, embedder.model_sha)
        existing = {lab: old for lab, old in self.store.voices(row["id"]).items() if lab != label and lab in clips}
        prefs, memo, states = self.store.settings(), {}, self.store.labels(row["id"])
        frozen = any(st.get("person_id") and self.store.person_policy(st["person_id"], prefs, memo) == FROZEN
                     for lab, st in states.items() if lab != label)  # fmt: skip
        # A new generation would hold one model's vectors: with a bystander embedded by another model, or a FROZEN
        # bystander (whose evidence is neither re-embedded nor moved), none is written and the generation stays.
        new_generation = not frozen and all((old.model, old.model_sha) == model for old in existing.values())
        # speakers without any stored voice are embedded too when a generation is written (new evidence, nothing changed)
        todo = {lab: [Clip(a, b, i) for i, (a, b) in enumerate(spans)] for lab, spans in clips.items()
                if lab == label or (new_generation and lab not in existing)}  # fmt: skip
        fresh = embed_voices(todo, audio.pcm, embedder)
        if label not in fresh or fresh[label].vector is None:
            return None
        if not new_generation:
            return fresh[label]  # the sample's evidence, in memory; the stored generation is untouched
        voices = dict(fresh)
        for lab, old in existing.items():
            turns = max(1, int(old.turns or 1))
            voices[lab] = LabelVoice(lab, [Clip(float(a), float(b), min(i, turns - 1)) for i, (a, b) in enumerate(old.clips)],
                                         vector=old.vector, spread=old.spread, rms_db=old.rms_db, f0=old.f0,
                                         f0_voiced=old.f0_voiced)  # fmt: skip
        # `label` is about to be confirmed for someone who passed the consent checks (`_sample_for`)
        keep = {label} | self.store.vector_labels(states, set(voices), raw=True, prefs=prefs, memo=memo)
        name = voices_name(embedder, row["audio_sha"], row["transcript_sha"], clips)
        self.store.write_voices(row["id"], name, embedder.model, embedder.model_sha, voices, keep)
        self.store.reference_voices(row["id"], name)
        self.store.remove_other_voices(row["id"], name)
        return self.store.voices(row["id"]).get(label)  # as stored (with its file), or None

    def resummarize(self, conv_id: str) -> None:
        if self._conversation(conv_id)["enrollment_id"]:
            raise ApiError(409, "voice_enrollment", "a voice-enrollment reading has no transcript or summary")
        # a queued app retry decides this conversation's next attempt; its lock covers acceptance too
        with operations.lock(self.vault):
            queued = self.db.execute(
                "UPDATE conversations SET reprocess_request = reprocess_request + 1, force_llm = 1 "
                "WHERE id=? AND retry_op IS NULL",
                (conv_id,),
            ).rowcount
        if not queued:
            raise ApiError(409, "retry_in_progress", "a retry of this conversation is queued; try again when it finishes")

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
               WHERE v.vector IS NOT NULL AND (l.person_id IS NULL) AND COALESCE(l.source, '') <> 'unknown'"""
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
        models = self.store.models(*key, self.pipeline.operating) if key else {}
        dismissed = {k: float(v) for k, v in prefs["dismissed"].items()}
        found = speaker_suggest.suggestions(candidates, models, me_exists=self.store.me() is not None, dismissed=dismissed,
                                            now=now, limit=len(candidates) or 1,
                                            space=self.store.rm_space(*key) if key else None)  # fmt: skip
        del excerpts
        return found, prefs

    def suggestions(self, limit: int, now: float | None = None) -> list[dict]:
        """A slice of the snapshot's list (built with the people snapshot)."""
        return self.suggestions_answer(limit)["suggestions"]

    def suggestions_answer(self, limit: int) -> dict:
        """GET /v1/speakers/suggestions: the slice plus the snapshot's ready/stale/generation/as_of, as /v1/people. The
        overlays apply first (a dismissed or acted-on suggestion, a forgotten person, the current wearer), then policy."""
        snap, _, forgotten, wearer = self._view()
        with self._people_lock:
            hidden = set(self._hidden_suggestions)
        kept = []
        for x in snap.suggestions or []:  # O(limit) past the blocked ones
            if len(kept) >= limit:
                break
            pid = x.get("person_id")
            if x["id"] not in hidden and pid not in forgotten and not self.served_blocked(pid, pid == wearer, unknown=True):
                kept.append({k: v for k, v in x.items() if k != "members"})
        out = {"suggestions": kept, "ready": snap.ready and not snap.stale,
               "generation": snap.generation, "as_of": iso_utc_epoch(snap.built_at) if snap.built_at else None}  # fmt: skip
        if snap.stale:
            out["stale"] = True
        return out

    def _built_suggestion(self, suggestion_id: str) -> dict:
        """A suggestion the last build published and nobody acted on since; its members come from the build (the
        request never clusters)."""
        snap, _, forgotten, _ = self._view()
        with self._people_lock:
            hidden = set(self._hidden_suggestions)
        found = next((x for x in snap.suggestions or [] if x.get("id") == suggestion_id and x.get("members")), None)
        if found is None or suggestion_id in hidden or found.get("person_id") in forgotten:
            raise ApiError(404, "not_found", "the suggestion no longer exists")
        return found

    def _hide_suggestion(self, suggestion_id: str) -> None:
        with self._people_lock:
            self._hidden_suggestions[suggestion_id] = self._people_seq

    def _compute_suggestions(self, now: float, limit: int = SUGGESTIONS_KEPT, problems: list[str] | None = None) -> list[dict]:
        found, _ = self._suggestions(now)
        out = []
        for s in found[:limit]:
            rep = s.representative
            try:  # a conversation whose transcript can't be read drops its suggestion, not the list (C2-02)
                transcript = self._transcript(rep.conversation_id)
            except (ApiError, OSError, ValueError) as exc:
                rel = f"conversations/{rep.conversation_id}/transcript.json"
                log.warning("speaker file unreadable, skipped: %s (%s)", rel, exc)
                if problems is not None:
                    problems.append(rel)
                continue
            excerpt = next((seg["text"] for seg in transcript.get("segments") or [] if seg["speaker"] == rep.label), "")
            clips = self._clip_list(rep.conversation_id, transcript, rep.label,
                                    self._clips(rep.conversation_id, transcript).get(rep.label) or [])  # fmt: skip
            out.append({"id": s.id, "kind": s.kind, "person_id": s.person_id,
                        "clip_id": f"{rep.conversation_id}.{rep.label}.0", "seconds": s.seconds,
                        "excerpt": (clips[0]["text"] if clips else excerpt)[:EXCERPT_CHARS],
                        "conversations": s.conversations, "days": s.days,
                        "conversation": self._context(rep.conversation_id),
                        "clips": [c | {"conversation_id": rep.conversation_id} for c in clips],
                        "other_day": self._other_day(s, rep),
                        "scope": [self._context(c) for c in sorted({m.conversation_id for m in s.members})],
                        "members": [[m.conversation_id, m.label] for m in s.members]})  # fmt: skip
        return out

    def _context(self, conv_id: str) -> dict:
        row = self.db.one("SELECT id, start, title, note_path FROM conversations WHERE id=?", (conv_id,))
        return {"id": conv_id, "started_at": iso_utc_epoch(row["start"]) if row else None,
                "title": row["title"] if row and row["note_path"] else None}  # fmt: skip

    def _other_day(self, s, rep) -> dict | None:
        """A clip of the same voice from another day, when the suggestion has one."""
        for m in sorted(s.members, key=lambda m: (-m.seconds, m.key)):
            if m.day == rep.day:
                continue
            transcript = self._transcript(m.conversation_id)
            clips = self._clip_list(m.conversation_id, transcript, m.label,
                                    self._clips(m.conversation_id, transcript).get(m.label) or [])  # fmt: skip
            if clips:
                return clips[0] | {"conversation_id": m.conversation_id, "conversation": self._context(m.conversation_id)}
        return None

    def dismiss(self, suggestion_id: str, now: float | None = None) -> None:
        now = time.time() if now is None else now
        prefs = self.store.settings()
        dismissed = {k: v for k, v in prefs["dismissed"].items() if float(v) > now}
        dismissed[suggestion_id] = now + speaker_suggest.COOLDOWN
        self.store.update_settings(dismissed=dismissed)
        self._hide_suggestion(suggestion_id)

    def assign_suggestion(self, suggestion_id: str, body: dict, now: float | None = None) -> list[str]:
        now = time.time() if now is None else now
        person_id, request_id = body.get("person_id"), body.get("request_id")
        if not isinstance(person_id, str) or not UUID_RE.match(person_id):
            raise ApiError(422, "invalid_body", "person_id must be a lowercase UUID")
        if not isinstance(request_id, str) or not request_id:
            raise ApiError(422, "invalid_body", "request_id is required")
        with self.store.lock:
            members = self._open_members(self._built_suggestion(suggestion_id))
            if self.store.person(person_id) is None:
                raise ApiError(404, "not_found", f"unknown person {person_id}")
            touched = []
            for conv_id, label in members:
                row = self.db.one("SELECT * FROM conversations WHERE id=?", (conv_id,))
                self.assign(conv_id, label, {"person_id": person_id, "expected_revision": row["speakers_revision"],
                                             "request_id": f"{request_id}:{conv_id}:{label}"})  # fmt: skip
                touched.append(conv_id)
            self._hide_suggestion(suggestion_id)
            return sorted(set(touched))

    def keep_unknown_suggestion(self, suggestion_id: str, body: dict, now: float | None = None) -> list[str]:
        """The owner keeps this recurring voice unknown, in every conversation it covers: durable
        (speakers.json), unlike the 7-day `dismiss`."""
        now = time.time() if now is None else now
        request_id = body.get("request_id")
        if not isinstance(request_id, str) or not request_id:
            raise ApiError(422, "invalid_body", "request_id is required")
        with self.store.lock:
            members = self._open_members(self._built_suggestion(suggestion_id))
            for conv_id, label in members:
                row = self.db.one("SELECT * FROM conversations WHERE id=?", (conv_id,))
                self.assign(conv_id, label, {"person_id": None, "keep_unknown": True, "expected_revision": row["speakers_revision"],
                                             "request_id": f"{request_id}:{conv_id}:{label}"})  # fmt: skip
            self._hide_suggestion(suggestion_id)
            return sorted({c for c, _ in members})

    def _open_members(self, suggestion: dict) -> list[tuple[str, str]]:
        """The suggestion's voices still unnamed and not kept unknown (a decision since the build stands)."""
        out = []
        for conv_id, label in suggestion["members"]:
            state = self.store.labels(conv_id).get(label) or {}
            if not state.get("person_id") and state.get("source") != "unknown":
                out.append((conv_id, label))
        if not out:
            raise ApiError(404, "not_found", "the suggestion no longer exists")
        return out

    def undo(self, body: dict) -> dict:
        """Put back what one naming request (a label, or every label of a suggestion) changed, label
        by label, only where that change still stands; voiceprints it created are removed, the
        ones it withdrew from a previously named person are put back, and the person and their
        other confirmations stay. Each label is all or nothing: one whose earlier person was
        forgotten, or whose withdrawn voiceprints are gone, is skipped unchanged. Repeating the same
        undo answers the same."""
        request_id, undo_id = body.get("request_id"), body.get("undo_request_id")
        for value, what in ((request_id, "request_id"), (undo_id, "undo_request_id")):
            if not isinstance(value, str) or not value or len(value) > 100:
                raise ApiError(422, "invalid_body", f"{what} is required")
        undone: set[str] = set()
        skipped: set[str] = set()
        with self.store.lock:
            self.store.reconcile()
            if journal.pending(self.store):  # an undo reads the state those operations would still change
                raise ApiError(409, "recovery_pending", "an earlier change to voices is still being recovered; try again later")
            for path in sorted(self.vault.conversations.glob("*/*/speakers.json")):
                conv_id = path.parent.name
                requests = (Vault.read_json(path) or {}).get("requests") or {}
                mine = {k: v for k, v in requests.items() if k == request_id or k.startswith(request_id + ":")}
                for key, rec in mine.items():
                    if "after" not in rec:
                        continue  # made before undo existed: nothing recorded to put back
                    done_key = f"{undo_id}:{key}"
                    if done_key in requests:
                        undone.add(conv_id)
                        continue
                    self.store.sync_conversation(conv_id)
                    if rec.get("moved") or rec.get("rejected"):  # a journaled sample operation (`speakers.review`)
                        why = self.review.undo_label_op(conv_id, key, rec, undo_id)
                        (skipped if why else undone).add(conv_id)
                        continue
                    states = self.store.labels(conv_id)
                    label = rec["label"]
                    current = self.store.persisted({label: states.get(label) or {}}).get(label)
                    after = rec["after"] or {}
                    if (current or {}).get("person_id") != after.get("person_id") or (current or {}).get("source") != after.get("source"):
                        skipped.add(conv_id)  # changed since: the later decision stands
                        continue
                    before = dict(rec["before"] or {})
                    withdrawn = rec.get("withdrawn") or {}
                    if any(self.store.forgetting_path(p).exists() for p in (before.get("person_id"), withdrawn.get("person_id")) if p):
                        skipped.add(conv_id)  # that person's forget hasn't finished: nothing of theirs comes back
                        continue
                    if before.get("person_id") and self.store.person(before["person_id"]) is None:
                        skipped.add(conv_id)  # that person was forgotten since: never brought back
                        continue
                    if withdrawn.get("samples") and not self.store.may_gain(withdrawn["person_id"]):  # I2
                        skipped.add(conv_id)  # their voiceprints come back only with their current consent
                        continue
                    if withdrawn.get("samples") and not self.store.can_restore(withdrawn["person_id"], withdrawn["samples"], key):
                        skipped.add(conv_id)  # their voiceprints are gone (forgotten, or past the window): no partial undo
                        continue
                    created = set((after.get("samples") or [])) - set(before.get("samples") or [])
                    if created and after.get("person_id"):
                        self.store.remove_sample_ids(after["person_id"], sorted(created))
                    if withdrawn.get("samples"):
                        self.store.restore_samples(withdrawn["person_id"], withdrawn["samples"], key)
                    states[label] = before
                    self.store.write_labels(conv_id, states, request=(done_key, {"label": label, "undo_of": key}))
                    row = self.db.one("SELECT note_path FROM conversations WHERE id=?", (conv_id,))
                    if row and row["note_path"]:
                        self.pipeline._set(conv_id, needs_render=1, next_attempt_at=None)
                    undone.add(conv_id)
            samples = self.review.undo(request_id, undo_id)  # sample decisions (review, remove, restore, move)
            if undone or samples["undone"]:
                self._relabel()
        return {"undone": sorted(undone), "skipped": sorted(skipped - undone), "samples": samples}

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
        # intent only (I4, 2026-11-26): the settings file and a marked relabel. The worker's relabel pass prunes vectors
        # and rebuilds the snapshots; until then every served output applies these settings itself (`served_blocked`)
        with self.store.lock:
            before = self.store.settings()
            self.store.update_settings(**changes)
            self.store.samples_changed()
            if any(k in changes and changes[k] != before[k] for k in ("auto_assign", "acknowledged_at", "unknown_voices_enabled")):
                self.db.set_meta("relabel_pending", "1")
            self._served_prefs = self.store.settings()
        return self.get_settings()

    def served_blocked(self, person_id: str | None, me: bool, *, automatic: bool = False, unknown: bool = False) -> bool:
        """Whether a served output must not name this person now, from the settings in memory (no file read, no
        query): the acknowledgment withdrawn for a non-wearer blocks everything; automatic naming off blocks only
        automatic names (`automatic`), not a hint or suggestion that asks the owner. The snapshots are built with
        the policy already (I1); this covers the moments between a settings change and the worker's rebuild."""
        prefs = self._served_prefs
        if unknown and not prefs["unknown_voices_enabled"]:
            return True  # an output drawn from unnamed voices, with unknown voices off (Carbon C2B-02)
        if not person_id:
            return False
        return (not me and not prefs["acknowledged_at"]) or (automatic and not prefs["auto_assign"])

    # -- clips -----------------------------------------------------------------------------------

    def clip_wav(self, clip_id: str) -> bytes:
        if clip_id.startswith("sample."):
            return self.review.clip_wav(clip_id)
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
