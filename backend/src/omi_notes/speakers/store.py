"""Speaker-learning state in the vault, mirrored in the index (docs/speaker-learning.md, "People").

Vault files (the index tables `people`, `samples`, `voices`, `speaker_labels` are caches of them):
- `People/<Name>.md`: frontmatter `omi_person_id`, `name`, `aliases`, `omi_me`; created once by
  the server, then the user's (rename freely: identity is the id, the file name is the link).
- `_omi/people/<id>/samples/<sample_id>.json`: a confirmed voiceprint {model, model_sha, dim,
  vector_b64, source, seconds, created_at, ...}, from vault format 6 also `state` (active | removed |
  moved), `revision`, `history` and a review `flag`; `consent.json`: the person-level attestation;
  `enrollment/<id>.omiaudio` + `enrollments/<id>.json`: the wearer's enrollment.
- `_omi/speakers/settings.json`: acknowledgment, unknown-voice opt-in, auto naming, dismissals.
- per conversation: `voices-<model>-<model_sha8>-<audio_sha16>-c<clip bounds8>-<transcript_sha8>.json` (clips, and vectors of assigned labels —
  of every label only with unknown-voice storage) and `speakers.json` (assignments + evidence).
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
import sqlite3
import time
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import yaml

from ..db import Database
from ..lock import SpeakerLock
from ..notes.writer import remove, sanitize_title, write_if_changed
from ..spool import atomic_write_bytes, fsync_dir, make_dirs_durable
from ..util import canonical_json, sha256_hex
from ..vault import Vault
from .match import Operating, Sample, build_models, centroid_basis
from .voices import LabelVoice, decode_vector, encode_vector

log = logging.getLogger(__name__)

PEOPLE_DIR = "People"
REQUEST_MEMORY = 200
ACTIVE, REMOVED, MOVED = "active", "removed", "moved"
SAMPLE_STATES = (ACTIVE, REMOVED, MOVED)
SAMPLE_FORMAT = 6  # vault format whose samples may carry a state, history and flag
_FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)


def sample_eligible(sample) -> bool:
    """The one rule for which voiceprints teach anything (matching, activation, hints, suggestions and
    calibration): an active sample. A review flag never changes it; only the owner's remove or move does."""
    if isinstance(sample, Mapping):
        state = sample.get("state")
    elif isinstance(sample, sqlite3.Row):
        state = sample["state"] if "state" in sample.keys() else None
    else:
        state = getattr(sample, "state", None)
    return (state or ACTIVE) == ACTIVE


def flag_open(flag: dict | None) -> bool:
    """A review flag the owner hasn't resolved for this evidence."""
    if not flag or not flag.get("reasons"):
        return False
    resolved = flag.get("resolved") or {}
    return resolved.get("fingerprint") != flag.get("evidence_fingerprint")


@dataclass
class VoiceRow:
    """A stored label voice (vector None when not kept)."""

    label: str
    vector: np.ndarray | None
    seconds: float
    turns: int
    spread: float
    rms_db: float | None
    clips: list[list[float]]
    model: str
    model_sha: str

    @property
    def mixed(self) -> bool:
        return self.spread > 0.6


def read_frontmatter(text: str) -> dict:
    match = _FRONTMATTER.match(text)
    if not match:
        return {}
    try:
        data = yaml.safe_load(match.group(1))
    except yaml.YAMLError:
        return {}
    return data if isinstance(data, dict) else {}


def voices_name(embedder, audio_sha: str, transcript_sha: str, clips: dict[str, list[list[float]]]) -> str:
    """A conversation's voices file, keyed by everything the voices depend on: a new transcript may
    number the voices differently, and other clip bounds (a corrected selection, same words and labels)
    make other voices. The transcript's part stays last (`voices-*-<transcript8>.json` finds it)."""
    model = re.sub(r"[^A-Za-z0-9._-]+", "-", embedder.model).strip("-")[:40]
    return f"voices-{model}-{embedder.model_sha[:8]}-{(audio_sha or '')[:16]}-c{clip_bounds(clips)}-{(transcript_sha or '')[:8]}.json"


def _spans(clips: list) -> list[list[float]]:
    return [[round(float(a), 3), round(float(b), 3)] for a, b in clips]


def clip_bounds(clips: dict[str, list[list[float]]]) -> str:
    """A fingerprint of every label's clip bounds (`voices_name`'s `c…` part)."""
    spans = {label: _spans(v) for label, v in sorted(clips.items()) if v}
    return hashlib.sha256(json.dumps(spans, sort_keys=True).encode()).hexdigest()[:8]


def same_clips(stored: list, current: list) -> bool:
    """Whether a stored voice was embedded from these clip bounds: every clip it used is one of them
    (embedding skips fragments too short to use, so it may hold fewer)."""
    allowed = {tuple(c) for c in _spans(current or [])}
    return all(tuple(c) in allowed for c in _spans(stored or []))


def current_voices_file(names, transcript: dict) -> str | None:
    """Of these voices file names, the one made from this transcript and its clip bounds, if any."""
    sha = sha256_hex(canonical_json(transcript.get("segments") or []).encode())
    tail = f"-c{clip_bounds(transcript.get('speaker_clips') or {})}-{sha[:8]}.json"
    return next((n for n in sorted(names) if n.endswith(tail)), None)


_KEEP = object()


class SpeakerStore:
    def __init__(self, vault: Vault, db: Database, *, auto_assign_default: bool = True) -> None:
        self.vault = vault
        self.db = db
        self.auto_assign_default = auto_assign_default
        # every read-modify-write of label states, in the API and in the worker (any process)
        self.lock = SpeakerLock(vault)

    # -- settings --------------------------------------------------------------------------------

    @property
    def settings_path(self) -> Path:
        return self.vault.speakers / "settings.json"

    def settings(self) -> dict:
        stored = Vault.read_json(self.settings_path) or {}
        return {
            "acknowledged_at": stored.get("acknowledged_at"),
            "unknown_voices_enabled": bool(stored.get("unknown_voices_enabled", False)),
            "auto_assign": bool(stored.get("auto_assign", self.auto_assign_default)),
            "dismissed": dict(stored.get("dismissed") or {}),
        }

    def update_settings(self, **changes) -> dict:
        current = Vault.read_json(self.settings_path) or {}
        current |= changes
        Vault.write_json(self.settings_path, current)
        return self.settings()

    # -- people ----------------------------------------------------------------------------------

    def person_dir(self, person_id: str) -> Path:
        return self.vault.person_dir(person_id)

    def scan_people(self) -> bool:
        """Refresh the `people` cache from People notes and voice folders; True when anything
        that rendering depends on (names, me) changed."""
        found: dict[str, dict] = {}
        people_root = self.vault.root / PEOPLE_DIR
        if people_root.exists():
            for path in sorted(people_root.rglob("*.md")):
                try:
                    front = read_frontmatter(path.read_text(encoding="utf-8"))
                except (OSError, UnicodeDecodeError):
                    continue
                pid = front.get("omi_person_id")
                if not isinstance(pid, str) or pid in found:
                    continue
                aliases = front.get("aliases") if isinstance(front.get("aliases"), list) else []
                found[pid] = {"id": pid, "name": path.stem, "me": int(front.get("omi_me") is True),
                              "note_path": self.vault.relpath(path), "aliases_json": json.dumps([str(a) for a in aliases])}  # fmt: skip
        if self.vault.people.exists():
            for folder in sorted(self.vault.people.iterdir()):
                if folder.is_dir() and folder.name not in found:
                    name = self._name_from_samples(folder) or "Unnamed person"
                    found[folder.name] = {"id": folder.name, "name": name, "me": 0, "note_path": None, "aliases_json": "[]"}
        for person in found.values():
            consent = Vault.read_json(self.person_dir(person["id"]) / "consent.json") or {}
            person["attested_at"] = consent.get("attested_at")
        before = {r["id"]: (r["name"], r["me"], r["note_path"]) for r in self.db.query("SELECT * FROM people")}
        after = {p["id"]: (p["name"], p["me"], p["note_path"]) for p in found.values()}
        if before != after or len(before) != len(found):
            with self.db.tx() as conn:
                conn.execute("DELETE FROM people")
                conn.executemany(
                    "INSERT INTO people (id, name, me, note_path, aliases_json, attested_at) VALUES (?,?,?,?,?,?)",
                    [(p["id"], p["name"], p["me"], p["note_path"], p["aliases_json"], p["attested_at"]) for p in found.values()],
                )
        else:
            for p in found.values():
                self.db.execute("UPDATE people SET attested_at=?, aliases_json=? WHERE id=?", (p["attested_at"], p["aliases_json"], p["id"]))
        return before != after

    def _name_from_samples(self, folder: Path) -> str | None:
        names = []
        for path in sorted((folder / "samples").glob("*.json")) if (folder / "samples").exists() else []:
            data = Vault.read_json(path) or {}
            if data.get("person_name"):
                names.append((data.get("created_at") or 0, data["person_name"]))
        return max(names)[1] if names else None

    def names_digest(self) -> str:
        """What rendering depends on about people (ids, names, me), as one hash."""
        rows = [(r["id"], r["name"], r["me"]) for r in self.db.query("SELECT id, name, me FROM people ORDER BY id")]
        return hashlib.sha256(json.dumps(rows).encode()).hexdigest()

    def people(self) -> list:
        return self.db.query("SELECT * FROM people ORDER BY me DESC, name")

    def person(self, person_id: str):
        return self.db.one("SELECT * FROM people WHERE id=?", (person_id,))

    def me(self):
        return self.db.one("SELECT * FROM people WHERE me=1 ORDER BY name LIMIT 1")

    def models(self, model: str, model_sha: str, op: Operating):
        me = self.me()
        return build_models(self.samples(model, model_sha), op, wearer_id=me["id"] if me else None)

    def rm_space(self, model: str, model_sha: str):
        """GA and people's GA-centred centroids (`speakers.space`), in memory only: GA over the stored label
        vectors `vector_labels` allows now (named for me or a consented person; others only with unknown-voice
        storage on; never a forgotten label) plus every eligible sample. None without any vector."""
        from .space import build_space

        prefs = self.settings()
        people = {r["id"]: r for r in self.people()}
        vectors = []
        for r in self.db.query(
            """SELECT v.vector, l.person_id, COALESCE(l.forgotten, 0) AS forgotten FROM voices v
               LEFT JOIN speaker_labels l ON l.conversation_id = v.conversation_id AND l.label = v.label
               WHERE v.vector IS NOT NULL AND v.model=? AND v.model_sha=?""",
            (model, model_sha),
        ):
            person = people.get(r["person_id"])
            consented = person is not None and (person["me"] or (prefs["acknowledged_at"] and person["attested_at"]))
            if not r["forgotten"] and (consented or prefs["unknown_voices_enabled"]):
                vectors.append(np.frombuffer(r["vector"], dtype="<f4").astype(np.float32))
        samples = self.samples(model, model_sha)
        by_person: dict[str, list] = {}
        for s in centroid_basis(samples):
            by_person.setdefault(s.person_id, []).append(s.vector)
        return build_space(vectors + [s.vector for s in samples], by_person)

    def put_person(self, person_id: str, name: str, *, me: bool | None = None, attest: bool = False,
                   now: float | None = None) -> bool:  # fmt: skip
        """Create (201 → True) or update (False) a person. The People note is created once;
        a new name renames it, `me` moves the flag (at most one person is "me")."""
        now = time.time() if now is None else now
        self.scan_people()
        current = self.person(person_id)
        created = current is None or current["note_path"] is None
        if me:
            for other in self.db.query("SELECT * FROM people WHERE me=1 AND id<>?", (person_id,)):
                if other["note_path"]:
                    self._set_front_line(self.vault.root / other["note_path"], "omi_me", "false")
        if created:
            path = self._free_note_path(name)
            front = yaml.safe_dump({"omi_person_id": person_id, "name": name, "aliases": [], "omi_me": bool(me)},
                                   sort_keys=False, allow_unicode=True)  # fmt: skip
            body = f"---\n{front}---\n# {path.stem}\n\nConversations with {path.stem} link here.\n"
            write_if_changed(path, body)
        else:
            path = self.vault.root / current["note_path"]
            if sanitize_title(name) != path.stem:
                target = self._free_note_path(name)
                target.parent.mkdir(parents=True, exist_ok=True)
                path.rename(target)
                path = target
                self._set_front_line(path, "name", json.dumps(name, ensure_ascii=False))
            if me is not None:
                self._set_front_line(path, "omi_me", "true" if me else "false")
        if attest:
            Vault.write_json(self.person_dir(person_id) / "consent.json", {"attested_at": now, "person_id": person_id})
        self.scan_people()
        return created

    def _free_note_path(self, name: str) -> Path:
        stem = sanitize_title(name, limit=60)
        root = self.vault.root / PEOPLE_DIR
        candidate, n = root / f"{stem}.md", 2
        while candidate.exists():
            candidate, n = root / f"{stem} {n}.md", n + 1
        return candidate

    @staticmethod
    def _set_front_line(path: Path, key: str, value: str) -> None:
        """Change one frontmatter line of a user-owned note (only our own `omi_`/`name` keys)."""
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return
        match = _FRONTMATTER.match(text)
        if not match:
            return
        block = match.group(1)
        line = re.compile(rf"^{re.escape(key)}:.*$", re.MULTILINE)
        block = line.sub(f"{key}: {value}", block, count=1) if line.search(block) else block + f"\n{key}: {value}"
        write_if_changed(path, f"---\n{block}\n---\n" + text[match.end():])

    def labeled_with(self, person_id: str) -> list[str]:
        """Conversations with a label assigned to (or blocked for) this person."""
        return [r["conversation_id"] for r in self.db.query(
            "SELECT DISTINCT conversation_id FROM speaker_labels WHERE person_id=? OR not_json LIKE ?",
            (person_id, f'%"{person_id}"%'))]  # fmt: skip

    def forget_voice(self, person_id: str, *, delete_note: bool = False) -> None:
        """Delete the person's voice data (samples, enrollment audio, consent). A global enrollment
        result keeps only its decision, so the reading is not learned again."""
        results = self.vault.speakers / "enrollments"
        for path in sorted(results.glob("*.json")) if results.exists() else []:
            data = Vault.read_json(path) or {}
            if data.get("person_id") == person_id:
                for key in ("person_id", "sample_id", "model", "model_sha"):
                    data.pop(key, None)
                Vault.write_json(path, data | {"forgotten": True})
        # a sample moved to this person left a `moved` record (with the vector) in the old person's folder:
        # it is this person's voice, so it goes with them (history and all)
        for path in sorted(self.vault.people.glob("*/samples/*.json")) if self.vault.people.exists() else []:
            if path.parent.parent.name == person_id:
                continue
            data = Vault.read_json(path) or {}
            if data.get("state") == MOVED and (data.get("moved_to") or {}).get("person_id") == person_id:
                remove(path)
                self.db.execute("DELETE FROM samples WHERE id=?", (path.stem,))
        folder = self.person_dir(person_id)
        if folder.exists():
            shutil.rmtree(folder)
            fsync_dir(folder.parent)
        person = self.person(person_id)
        if delete_note and person is not None and person["note_path"]:
            remove(self.vault.root / person["note_path"])
        self.db.execute("DELETE FROM samples WHERE person_id=?", (person_id,))
        self.scan_people()

    def attested(self, person_id: str) -> bool:
        row = self.person(person_id)
        return bool(row and row["attested_at"])

    # -- samples ---------------------------------------------------------------------------------

    def add_sample(self, person_id: str, vector: np.ndarray, *, model: str, model_sha: str, source: str, seconds: float,
                   day: str | None, session: str | None, conversation_id: str | None = None, label: str | None = None,
                   request_id: str | None = None, enrollment_id: str | None = None, now: float | None = None) -> str:  # fmt: skip
        now = time.time() if now is None else now
        sample_id = str(uuid.uuid4())
        person = self.person(person_id)
        data = {
            "sample_id": sample_id, "person_id": person_id, "person_name": person["name"] if person else None,
            "model": model, "model_sha": model_sha, "dim": int(len(vector)), "vector_b64": encode_vector(vector),
            "source": source, "seconds": round(float(seconds), 3), "created_at": now, "day": day, "session": session,
            "conversation_id": conversation_id, "label": label, "request_id": request_id, "enrollment_id": enrollment_id,
            "attested": self.attested(person_id) or source == "enrollment",
        }  # fmt: skip
        Vault.write_json(self.person_dir(person_id) / "samples" / f"{sample_id}.json", data)
        self._index_sample(data)
        return sample_id

    def _index_sample(self, data: dict) -> None:
        self.db.execute(
            """INSERT OR REPLACE INTO samples (id, person_id, model, model_sha, vector, source, seconds, day, session,
                   conversation_id, label, request_id, created_at, state, revision, flag_json, f0)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (data["sample_id"], data["person_id"], data["model"], data["model_sha"],
             np.asarray(decode_vector(data["vector_b64"]), dtype="<f4").tobytes(), data["source"], data.get("seconds"),
             data.get("day"), data.get("session"), data.get("conversation_id"), data.get("label"), data.get("request_id"),
             data.get("created_at") or 0.0, data.get("state") or ACTIVE, int(data.get("revision") or 0),
             json.dumps(data["flag"], sort_keys=True) if data.get("flag") else None, data.get("f0")),
        )  # fmt: skip

    def sample_path(self, person_id: str, sample_id: str) -> Path:
        return self.person_dir(person_id) / "samples" / f"{sample_id}.json"

    def read_sample(self, person_id: str, sample_id: str) -> dict | None:
        return Vault.read_json(self.sample_path(person_id, sample_id))

    def find_sample(self, sample_id: str) -> dict | None:
        """A sample file by id (the index says whose; the folders are the truth if it is behind)."""
        row = self.db.one("SELECT person_id FROM samples WHERE id=?", (sample_id,))
        if row is not None and (data := self.read_sample(row["person_id"], sample_id)) is not None:
            return data
        if not re.fullmatch(r"[0-9a-f-]{36}", sample_id or "") or not self.vault.people.exists():
            return None
        return next((Vault.read_json(p) for p in self.vault.people.glob(f"*/samples/{sample_id}.json")), None)

    def update_sample(self, person_id: str, sample_id: str, changes: dict, *, action: str, by: str,
                      request_id: str | None, now: float | None = None, record: dict | None = None) -> dict:  # fmt: skip
        """Change a sample file (the vault first, then the index; call under the speaker lock): `changes`
        are merged (None removes a key), the revision goes up, and `history` gains {at, action, by,
        request_id, ...record}. The vault is raised to format 6 before the first such write."""
        now = time.time() if now is None else now
        data = self.read_sample(person_id, sample_id)
        if data is None:
            raise KeyError(sample_id)
        self.vault.raise_format(SAMPLE_FORMAT)
        data = dict(data)
        for key, value in changes.items():
            if value is None:
                data.pop(key, None)
            else:
                data[key] = value
        data["revision"] = int(data.get("revision") or 0) + 1
        data["history"] = list(data.get("history") or []) + [{"at": now, "action": action, "by": by,
                                                               "request_id": request_id} | (record or {})]  # fmt: skip
        Vault.write_json(self.sample_path(person_id, sample_id), data)
        self._index_sample(data)
        self.samples_changed(now)
        return data

    def set_sample_state(self, person_id: str, sample_id: str, state: str, *, action: str, by: str,
                         request_id: str | None, now: float | None = None, extra: dict | None = None) -> dict:  # fmt: skip
        if state not in SAMPLE_STATES:
            raise ValueError(state)
        before = (self.read_sample(person_id, sample_id) or {}).get("state") or ACTIVE
        return self.update_sample(person_id, sample_id, {"state": state} | (extra or {}), action=action, by=by,
                                  request_id=request_id, now=now, record={"from": before, "to": state})  # fmt: skip

    def samples_changed(self, now: float | None = None) -> None:
        """People's voice evidence changed (a sample, a state, consent): recalibrate (debounced, `calibration`)."""
        self.db.set_meta("calibrate_pending", repr(time.time() if now is None else now))

    def load_samples(self) -> int:
        """Rebuild the `samples` cache from the vault."""
        self.db.execute("DELETE FROM samples")
        count = 0
        if self.vault.people.exists():
            for path in sorted(self.vault.people.glob("*/samples/*.json")):
                data = Vault.read_json(path)
                if data and data.get("vector_b64"):
                    self._index_sample(data)
                    count += 1
        return count

    def samples(self, model: str, model_sha: str, *, every_state: bool = False) -> list[Sample]:
        """This model's samples that may teach anything (`sample_eligible`); `every_state`: removed and moved ones too."""
        return [
            Sample(r["id"], r["person_id"], np.frombuffer(r["vector"], dtype="<f4").astype(np.float32), r["source"],
                   r["day"], r["session"], r["created_at"], seconds=r["seconds"] or 0.0, state=r["state"], f0=r["f0"])
            for r in self.db.query("SELECT * FROM samples WHERE model=? AND model_sha=? ORDER BY created_at, id", (model, model_sha))
            if every_state or sample_eligible(r)
        ]  # fmt: skip

    def remove_sample_ids(self, person_id: str, sample_ids: list[str]) -> int:
        """Delete these samples of a person (file first, then index)."""
        n = 0
        for sid in sample_ids:
            if remove(self.person_dir(person_id) / "samples" / f"{sid}.json") or self.db.one("SELECT 1 FROM samples WHERE id=?", (sid,)):
                n += 1
            self.db.execute("DELETE FROM samples WHERE id=?", (sid,))
        return n

    # A label taken back from a named person withdraws the voiceprints that naming gave them: kept
    # (inside the person's folder, so forgetting them deletes these too) only long enough for an
    # undo, then deleted for good.
    WITHDRAWN_SECONDS = 24 * 3600

    def _withdrawn_dir(self, person_id: str, request_id: str) -> Path:
        return self.person_dir(person_id) / "withdrawn" / hashlib.sha256(request_id.encode()).hexdigest()[:16]

    def withdraw_samples(self, person_id: str, sample_ids: list[str], request_id: str, now: float | None = None) -> list[str]:
        """Take these samples out of use for an undo window; the ids actually withdrawn."""
        folder = self._withdrawn_dir(person_id, request_id)
        moved = []
        for sid in sample_ids:
            src = self.person_dir(person_id) / "samples" / f"{sid}.json"
            if src.exists():
                make_dirs_durable(folder)
                os.replace(src, folder / src.name)
                fsync_dir(folder)
                fsync_dir(src.parent)
                moved.append(sid)
            elif (folder / f"{sid}.json").exists():
                moved.append(sid)  # a retry after a crash: already withdrawn
            self.db.execute("DELETE FROM samples WHERE id=?", (sid,))
        if moved:
            Vault.write_json(folder / "withdrawn.json", {"request_id": request_id, "at": time.time() if now is None else now})
        return moved

    def can_restore(self, person_id: str, sample_ids: list[str], request_id: str) -> bool:
        """Every one of these withdrawn samples is still kept (and the person still exists)."""
        if self.person(person_id) is None:
            return False
        folder = self._withdrawn_dir(person_id, request_id)
        live = self.person_dir(person_id) / "samples"
        return all((folder / f"{sid}.json").exists() or (live / f"{sid}.json").exists() for sid in sample_ids)

    def restore_samples(self, person_id: str, sample_ids: list[str], request_id: str) -> None:
        """Put withdrawn samples back in use (call after `can_restore`); idempotent."""
        folder = self._withdrawn_dir(person_id, request_id)
        live = self.person_dir(person_id) / "samples"
        make_dirs_durable(live)
        for sid in sample_ids:
            src = folder / f"{sid}.json"
            if src.exists():
                os.replace(src, live / src.name)
            data = Vault.read_json(live / f"{sid}.json")
            if data and data.get("vector_b64"):
                self._index_sample(data)
        fsync_dir(live)
        if folder.exists():
            shutil.rmtree(folder)
            fsync_dir(folder.parent)

    def purge_withdrawn(self, now: float | None = None) -> int:
        """Delete withdrawn voiceprints past the undo window; how many sets went."""
        now = time.time() if now is None else now
        gone = 0
        for marker in sorted(self.vault.people.glob("*/withdrawn/*/withdrawn.json")) if self.vault.people.exists() else []:
            at = (Vault.read_json(marker) or {}).get("at")
            if not isinstance(at, (int, float)) or now - at > self.WITHDRAWN_SECONDS:
                shutil.rmtree(marker.parent)
                fsync_dir(marker.parent.parent)
                gone += 1
        return gone

    def sample_for_request(self, request_id: str):
        return self.db.one("SELECT * FROM samples WHERE request_id=?", (request_id,))

    def any_samples(self) -> bool:
        return self.db.one("SELECT 1 FROM samples LIMIT 1") is not None

    # -- per-conversation voices and labels -------------------------------------------------------

    def conv_dir(self, conv_id: str) -> Path:
        return self.vault.conversation_dir(conv_id)

    def write_voices(self, conv_id: str, name: str, model: str, model_sha: str, voices: dict[str, LabelVoice],
                     keep_vectors: set[str]) -> None:  # fmt: skip
        labels = {}
        for label, voice in voices.items():
            entry = {"seconds": voice.seconds, "turns": voice.turns, "spread": voice.spread, "rms_db": voice.rms_db,
                     "clips": [[c.start, c.end] for c in voice.clips]}  # fmt: skip
            if voice.vector is not None and label in keep_vectors:
                entry["vector_b64"] = encode_vector(voice.vector)
            labels[label] = entry
        Vault.write_json(self.conv_dir(conv_id) / name, {"model": model, "model_sha": model_sha, "labels": labels})
        self.index_voices(conv_id, name)

    def index_voices(self, conv_id: str, name: str) -> None:
        data = Vault.read_json(self.conv_dir(conv_id) / name) or {}
        with self.db.tx() as conn:
            conn.execute("DELETE FROM voices WHERE conversation_id=?", (conv_id,))
            conn.executemany(
                """INSERT INTO voices (conversation_id, label, file, model, model_sha, vector, seconds, turns, spread, rms_db,
                       clips_json) VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                [(conv_id, label, name, data.get("model"), data.get("model_sha"),
                  np.asarray(decode_vector(e["vector_b64"]), dtype="<f4").tobytes() if e.get("vector_b64") else None,
                  e.get("seconds") or 0.0, e.get("turns") or 0, e.get("spread") or 0.0, e.get("rms_db"),
                  json.dumps(e.get("clips") or [])) for label, e in (data.get("labels") or {}).items()],
            )  # fmt: skip

    def keep_vectors(self, conv_id: str, labels: set[str]) -> bool:
        """Store the vectors of `labels` (now assigned) if the voices file lacks them; False when
        the vectors were never kept (they must be recomputed from raw audio)."""
        row = self.db.one("SELECT file FROM voices WHERE conversation_id=? LIMIT 1", (conv_id,))
        return row is not None and all(
            self.db.one("SELECT 1 FROM voices WHERE conversation_id=? AND label=? AND vector IS NOT NULL", (conv_id, label))
            for label in labels
        )

    def prune_vectors(self, conv_id: str, keep: set[str]) -> bool:
        """Drop stored vectors of labels not in `keep` (unknown voices expire with raw audio)."""
        row = self.db.one("SELECT file FROM voices WHERE conversation_id=? LIMIT 1", (conv_id,))
        if row is None:
            return False
        path = self.conv_dir(conv_id) / row["file"]
        data = Vault.read_json(path) or {}
        changed = False
        for label, entry in (data.get("labels") or {}).items():
            if label not in keep and entry.pop("vector_b64", None) is not None:
                changed = True
        if changed:
            Vault.write_json(path, data)
        stale = self.db.one(
            f"SELECT 1 FROM voices WHERE conversation_id=? AND vector IS NOT NULL AND label NOT IN ({','.join('?' * len(keep))})",
            (conv_id, *sorted(keep)),
        )  # fmt: skip
        if changed or stale:  # also heals an index a crash left behind the file
            self.index_voices(conv_id, row["file"])
        return changed

    def vector_labels(self, states: dict[str, dict], labels: set[str], *, raw: bool) -> set[str]:
        """Labels whose voice vector may be stored (docs/speaker-learning.md, "Privacy"): named for
        me, or for someone with consent (acknowledged and attested); any other label only while
        unknown voices are on and its raw audio exists. A forgotten label never."""
        prefs = self.settings()
        people = {r["id"]: r for r in self.people()}
        keep = set()
        for label in labels:
            state = states.get(label) or {}
            if state.get("forgotten"):
                continue
            person = people.get(state.get("person_id"))
            if person is not None and (person["me"] or (prefs["acknowledged_at"] and person["attested_at"])):
                keep.add(label)
            elif raw and prefs["unknown_voices_enabled"]:
                keep.add(label)
        return keep

    def raw_available(self, row) -> bool:
        """All raw audio under the conversation's speech still exists."""
        blocks = json.loads(row["blocks_json"])
        if not blocks:
            return False
        lo, hi = min(b[0] for b in blocks), max(b[1] for b in blocks)
        return self.db.one(
            """SELECT 1 FROM chunks WHERE device_id=? AND raw_deleted=1 AND audio_start IS NOT NULL
               AND audio_start <= ? AND audio_end >= ?""",
            (row["device_id"], hi + 1, lo - 1),
        ) is None

    def reconcile_vectors(self) -> int:
        """Drop every stored vector the rule no longer allows. Idempotent and independent of how
        we got here (a setting change, raw deletion, forgetting, or a crash in the middle of one)."""
        pruned = 0
        with self.lock:  # never publish a voices file read before a concurrent forget
            for r in self.db.query("SELECT DISTINCT conversation_id FROM voices WHERE vector IS NOT NULL"):
                conv_id = r["conversation_id"]
                row = self.db.one("SELECT * FROM conversations WHERE id=?", (conv_id,))
                stored = {v["label"] for v in self.db.query(
                    "SELECT label FROM voices WHERE conversation_id=? AND vector IS NOT NULL", (conv_id,))}  # fmt: skip
                keep = self.vector_labels(self.labels(conv_id), stored, raw=row is not None and self.raw_available(row))
                if stored - keep:
                    self.prune_vectors(conv_id, keep)
                    pruned += 1
        return pruned

    def voices(self, conv_id: str) -> dict[str, VoiceRow]:
        return {
            r["label"]: VoiceRow(r["label"], np.frombuffer(r["vector"], dtype="<f4").astype(np.float32) if r["vector"] else None,
                                 r["seconds"], r["turns"], r["spread"], r["rms_db"], json.loads(r["clips_json"]), r["model"],
                                 r["model_sha"])
            for r in self.db.query("SELECT * FROM voices WHERE conversation_id=?", (conv_id,))
        }  # fmt: skip

    def labels(self, conv_id: str) -> dict[str, dict]:
        return {
            r["label"]: {"person_id": r["person_id"], "source": r["source"], "distance": r["distance"], "margin": r["margin"],
                         "evidence_s": r["evidence_s"], "not": json.loads(r["not_json"]), "forgotten": bool(r["forgotten"]),
                         "samples": json.loads(r["samples_json"])} | ({"rm_basis": r["rm_basis"]} if r["rm_basis"] else {})
            for r in self.db.query("SELECT * FROM speaker_labels WHERE conversation_id=?", (conv_id,))
        }  # fmt: skip

    def write_labels(self, conv_id: str, states: dict[str, dict], *, transcript_sha: str | None = None,
                     voices: str | None | object = _KEEP, request: tuple[str, dict] | None = None) -> int:  # fmt: skip
        """Persist label assignments (speakers.json, then the index); returns the new revision.
        `transcript_sha` and `voices`: only when the states were made (`identify`) for that
        transcript and against that voices file (None: none); otherwise the stored ones stay.
        `request`: an app request id and its result, remembered so a retry is answered, not redone."""
        row = self.db.one("SELECT speakers_revision, transcript_sha FROM conversations WHERE id=?", (conv_id,))
        kept = self.persisted(states)
        path = self.conv_dir(conv_id) / "speakers.json"
        data = Vault.read_json(path) or {}
        # the file is the truth: its revision may be ahead of an index write that failed
        revision = max(row["speakers_revision"] if row else 0, int(data.get("revision") or 0)) + 1
        tag = transcript_sha or data.get("transcript_sha") or (row["transcript_sha"] if row else None)
        # once a voice here was forgotten, that stays true whatever later transcripts contain
        forgotten = bool(data.get("forgotten")) or any(s.get("forgotten") for s in kept.values())
        data.update(revision=revision, transcript_sha=tag, labels=kept, forgotten=forgotten)
        if voices is not _KEEP:
            data["voices"] = voices
        if request is not None:
            requests = dict(data.get("requests") or {})
            requests[request[0]] = request[1] | {"revision": revision}
            data["requests"] = dict(list(requests.items())[-REQUEST_MEMORY:])
        Vault.write_json(path, data)
        self.index_labels(conv_id, kept, revision)
        return revision

    @staticmethod
    def persisted(states: dict[str, dict]) -> dict[str, dict]:
        """What speakers.json keeps of label states: assignments, blocks, match evidence, and
        `forgotten` (the label's person was forgotten: its voice is never stored again)."""
        keys = ("person_id", "source", "distance", "margin", "evidence_s", "not")
        out = {}
        for label, state in sorted(states.items()):
            # `source: unknown`: the owner said this voice stays unknown (kept for good, never auto-named)
            if not (state.get("person_id") or state.get("not") or state.get("distance") is not None or state.get("forgotten")
                    or state.get("source") == "unknown"):  # fmt: skip
                continue
            out[label] = {k: (sorted(state.get(k) or []) if k == "not" else state.get(k)) for k in keys}
            if state.get("rm_basis"):  # how the label was centred for the recording-mean check (`speakers.space`)
                out[label]["rm_basis"] = state["rm_basis"]
            if state.get("forgotten"):
                out[label]["forgotten"] = True
            if state.get("samples"):  # the confirmations this assignment created: they move with it
                out[label]["samples"] = sorted(state["samples"])
        return out

    def request_result(self, conv_id: str, request_id: str) -> dict | None:
        data = Vault.read_json(self.conv_dir(conv_id) / "speakers.json") or {}
        return (data.get("requests") or {}).get(request_id)

    def index_labels(self, conv_id: str, states: dict[str, dict], revision: int) -> None:
        with self.db.tx() as conn:
            conn.execute("DELETE FROM speaker_labels WHERE conversation_id=?", (conv_id,))
            conn.executemany(
                """INSERT INTO speaker_labels (conversation_id, label, person_id, source, distance, margin, evidence_s, not_json,
                       forgotten, samples_json, rm_basis) VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                [(conv_id, label, s.get("person_id"), s.get("source"), s.get("distance"), s.get("margin"),
                  s.get("evidence_s"), json.dumps(sorted(s.get("not") or [])), int(bool(s.get("forgotten"))),
                  json.dumps(sorted(s.get("samples") or [])), s.get("rm_basis")) for label, s in states.items()],
            )  # fmt: skip
            conn.execute("UPDATE conversations SET speakers_revision=? WHERE id=?", (revision, conv_id))

    def sync_labels_index(self, conv_id: str) -> bool:
        """Re-index the label states if the index is behind speakers.json (a failed index write
        after the file was published): every read-modify-write starts from the file's states."""
        data = Vault.read_json(self.conv_dir(conv_id) / "speakers.json")
        row = self.db.one("SELECT speakers_revision FROM conversations WHERE id=?", (conv_id,))
        if data and row is not None and int(data.get("revision") or 0) != row["speakers_revision"]:
            self.index_labels(conv_id, data.get("labels") or {}, int(data.get("revision") or 0))
            return True
        return False

    def sync_conversation(self, conv_id: str) -> bool:
        """Re-index this conversation's speakers/voices files where the index is behind them (a
        crash or failed index write after the file was published). True if anything changed."""
        changed = self.sync_labels_index(conv_id)
        if self.remove_obsolete_voices(conv_id):
            changed = True
        name = self.voices_file(conv_id)
        indexed = self.db.one("SELECT file FROM voices WHERE conversation_id=? LIMIT 1", (conv_id,))
        if name and (indexed is None or indexed["file"] != name):
            self.index_voices(conv_id, name)
            changed = True
        return changed

    def sync_samples(self) -> bool:
        """Re-index voice samples if the index lost any (or kept a deleted one)."""
        files = {p.stem for p in self.vault.people.glob("*/samples/*.json")} if self.vault.people.exists() else set()
        indexed = {r["id"] for r in self.db.query("SELECT id FROM samples")}
        if files == indexed:
            return False
        self.load_samples()
        return True

    def reference_voices(self, conv_id: str, name: str) -> None:
        """Record which voices file the (unchanged) label states now go with."""
        path = self.conv_dir(conv_id) / "speakers.json"
        data = Vault.read_json(path) or {}
        if data.get("voices") == name:
            return
        if "transcript_sha" not in data:
            row = self.db.one("SELECT transcript_sha FROM conversations WHERE id=?", (conv_id,))
            data["transcript_sha"] = row["transcript_sha"] if row else None
        Vault.write_json(path, data | {"voices": name})

    def labels_to_move(self, conv_id: str, transcript: dict) -> bool:
        """Whether the label states need moving to this transcript (`move_labels`): they were made for
        another one, or a voices file of this transcript's own clip bounds isn't named by speakers.json yet
        (a crash after the voices file was written, before its reference: that file is the current evidence)."""
        sha = sha256_hex(canonical_json(transcript.get("segments") or []).encode())
        if self.labels_transcript(conv_id) not in (None, sha):
            return True
        _, referenced = self.referenced_voices(conv_id)
        matching = current_voices_file([p.name for p in self.conv_dir(conv_id).glob("voices-*.json")], transcript)
        return matching is not None and matching != referenced

    def referenced_voices(self, conv_id: str) -> tuple[bool, str | None]:
        """(speakers.json names its voices file, that file): the generation its labels were made against."""
        data = Vault.read_json(self.conv_dir(conv_id) / "speakers.json") or {}
        return "voices" in data, data.get("voices")

    def read_voices(self, conv_id: str, name: str) -> dict[str, VoiceRow]:
        data = Vault.read_json(self.conv_dir(conv_id) / name) or {}
        return {
            label: VoiceRow(label, decode_vector(e["vector_b64"]) if e.get("vector_b64") else None, e.get("seconds") or 0.0,
                            e.get("turns") or 0, e.get("spread") or 0.0, e.get("rms_db"), e.get("clips") or [],
                            data.get("model"), data.get("model_sha"))
            for label, e in (data.get("labels") or {}).items()
        }  # fmt: skip

    def voices_of_labels(self, conv_id: str, transcript_sha: str | None, *, not_file: str | None = None) -> dict[str, VoiceRow]:
        """The voices the stored label states were made against."""
        named, ref = self.referenced_voices(conv_id)
        if named:
            return self.read_voices(conv_id, ref) if ref and ref != not_file and (self.conv_dir(conv_id) / ref).exists() else {}
        return self.voices_for_transcript(conv_id, transcript_sha, not_file=not_file)  # speakers.json from before references

    def voices_file(self, conv_id: str) -> str | None:
        """The voices file speakers.json names; else (older files) the current transcript's, else the newest."""
        named, ref = self.referenced_voices(conv_id)
        if named:
            return ref if ref and (self.conv_dir(conv_id) / ref).exists() else None
        voices = sorted(self.conv_dir(conv_id).glob("voices-*.json"), key=lambda p: (p.stat().st_mtime, p.name))
        row = self.db.one("SELECT transcript_sha FROM conversations WHERE id=?", (conv_id,))
        if row is not None and row["transcript_sha"]:
            current = [p for p in voices if p.name.endswith(f"-{row['transcript_sha'][:8]}.json")]
            voices = current or voices
        return voices[-1].name if voices else None

    def remove_other_voices(self, conv_id: str, keep: str | None) -> None:
        """Voices of an earlier transcript (their labels no longer apply) are deleted."""
        for path in self.conv_dir(conv_id).glob("voices-*.json"):
            if path.name != keep:
                remove(path)
        if keep is None:
            self.db.execute("DELETE FROM voices WHERE conversation_id=?", (conv_id,))

    def voices_for_transcript(self, conv_id: str, transcript_sha: str | None, *, not_file: str | None = None) -> dict[str, VoiceRow]:
        """The stored voices made for an (earlier) transcript, read from its file (`not_file`: the
        new transcript's, which a crashed attempt may already have indexed)."""
        if not transcript_sha:
            return {}
        for path in self.conv_dir(conv_id).glob(f"voices-*-{transcript_sha[:8]}.json"):
            if path.name != not_file:
                return self.read_voices(conv_id, path.name)
        indexed = self.db.one("SELECT file FROM voices WHERE conversation_id=? LIMIT 1", (conv_id,))
        if indexed is None or indexed["file"] == not_file or re.search(r"-[0-9a-f]{8}\.json$", indexed["file"] or ""):
            return {}
        return self.voices(conv_id)  # a voices file from before transcript-keyed names

    def had_forgotten(self, conv_id: str) -> bool:
        """A voice in this conversation was forgotten (durable, independent of today's labels)."""
        data = Vault.read_json(self.conv_dir(conv_id) / "speakers.json")
        return bool(data and (data.get("forgotten") or any((s or {}).get("forgotten") for s in (data.get("labels") or {}).values())))

    def current_transcript_sha(self, conv_id: str) -> str | None:
        data = Vault.read_json(self.conv_dir(conv_id) / "transcript.json")
        return sha256_hex(canonical_json(data.get("segments") or []).encode()) if data else None

    def remove_obsolete_voices(self, conv_id: str) -> bool:
        """Voices files no label state depends on (an interrupted voices stage's leftovers): all but
        the one speakers.json names — and, while its labels still wait to be moved to a newer
        transcript, that transcript's (the move compares the two)."""
        files = list(self.conv_dir(conv_id).glob("voices-*.json"))
        if not files:
            return False
        data = Vault.read_json(self.conv_dir(conv_id) / "speakers.json") or {}
        sha = self.current_transcript_sha(conv_id)
        tag = re.compile(r"-([0-9a-f]{8})\.json$")
        if "voices" in data:
            keep = {data["voices"]} if data["voices"] else set()
            if sha and data.get("transcript_sha") not in (None, sha):
                keep |= {p.name for p in files if (m := tag.search(p.name)) and m.group(1) == sha[:8]}
            # the current transcript's own clip bounds, written before speakers.json could name it (a crash
            # in between): kept for the move to adopt, never deleted in favour of other bounds
            transcript = Vault.read_json(self.conv_dir(conv_id) / "transcript.json")
            if transcript and (matching := current_voices_file([p.name for p in files], transcript)):
                keep.add(matching)
        elif sha is None:
            return False
        else:  # speakers.json from before references: by transcript tag (its labels' own, while a move is pending)
            tags = {sha[:8]} | ({data["transcript_sha"][:8]} if data.get("transcript_sha") else set())
            current = any((m := tag.search(p.name)) and m.group(1) == sha[:8] for p in files)
            keep = {p.name for p in files if ((m := tag.search(p.name)) and m.group(1) in tags) or (not m and not current)}
        removed = False
        for path in files:
            if path.name not in keep:
                remove(path)
                removed = True
        if removed:
            name = self.voices_file(conv_id)
            if name:
                self.index_voices(conv_id, name)
            else:
                self.db.execute("DELETE FROM voices WHERE conversation_id=?", (conv_id,))
        return removed

    def remove_obsolete_voices_everywhere(self) -> int:
        with self.lock:
            return sum(self.remove_obsolete_voices(r["id"]) for r in self.db.query("SELECT id FROM conversations WHERE status <> 'open'"))

    def labels_transcript(self, conv_id: str) -> str | None:
        """The transcript the stored label states were made for (None: no states yet)."""
        data = Vault.read_json(self.conv_dir(conv_id) / "speakers.json")
        return data.get("transcript_sha") if data else None

    def load_conversation(self, conv_id: str) -> None:
        """Index a conversation's voices and speakers files (rebuild)."""
        conv_dir = self.conv_dir(conv_id)
        name = self.voices_file(conv_id)
        if name:
            self.index_voices(conv_id, name)
        data = Vault.read_json(conv_dir / "speakers.json")
        if data:
            self.index_labels(conv_id, data.get("labels") or {}, int(data.get("revision") or 0))

    def names(self, conv_id: str) -> dict[str, dict]:
        """label → {person_id, name, me, source} for named labels."""
        out = {}
        for r in self.db.query(
            """SELECT l.label, l.person_id, l.source, p.name, p.me FROM speaker_labels l JOIN people p ON p.id = l.person_id
               WHERE l.conversation_id=? AND l.person_id IS NOT NULL""",
            (conv_id,),
        ):
            out[r["label"]] = {"person_id": r["person_id"], "name": r["name"], "me": bool(r["me"]), "source": r["source"]}
        return out

    # -- enrollment audio -----------------------------------------------------------------------

    def save_enrollment(self, person_id: str, enrollment_id: str, flac: bytes, result: dict) -> None:
        atomic_write_bytes(self.person_dir(person_id) / "enrollment" / f"{enrollment_id}.omiaudio", flac)
        Vault.write_json(self.person_dir(person_id) / "enrollments" / f"{enrollment_id}.json", result)
