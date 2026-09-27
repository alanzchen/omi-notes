"""Speaker-learning state in the vault, mirrored in the index (docs/speaker-learning.md, "People").

Vault files (the index tables `people`, `samples`, `voices`, `speaker_labels` are caches of them):
- `People/<Name>.md`: frontmatter `omi_person_id`, `name`, `aliases`, `omi_me`; created once by
  the server, then the user's (rename freely: identity is the id, the file name is the link).
- `_omi/people/<id>/samples/<sample_id>.json`: a confirmed voiceprint {model, model_sha, dim,
  vector_b64, source, seconds, created_at, ...}; `consent.json`: the person-level attestation;
  `enrollment/<id>.omiaudio` + `enrollments/<id>.json`: the wearer's enrollment.
- `_omi/speakers/settings.json`: acknowledgment, unknown-voice opt-in, auto naming, dismissals.
- per conversation: `voices-<model>-<audio_sha16>.json` (clips, and vectors of assigned labels —
  of every label only with unknown-voice storage) and `speakers.json` (assignments + evidence).
"""

from __future__ import annotations

import json
import logging
import re
import shutil
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import yaml

from ..db import Database
from ..notes.writer import remove, sanitize_title, write_if_changed
from ..spool import atomic_write_bytes
from ..vault import Vault
from .match import Sample
from .voices import LabelVoice, decode_vector, encode_vector

log = logging.getLogger(__name__)

PEOPLE_DIR = "People"
REQUEST_MEMORY = 200
_FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)


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


class SpeakerStore:
    def __init__(self, vault: Vault, db: Database, *, auto_assign_default: bool = True) -> None:
        self.vault = vault
        self.db = db
        self.auto_assign_default = auto_assign_default

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

    def people(self) -> list:
        return self.db.query("SELECT * FROM people ORDER BY me DESC, name")

    def person(self, person_id: str):
        return self.db.one("SELECT * FROM people WHERE id=?", (person_id,))

    def me(self):
        return self.db.one("SELECT * FROM people WHERE me=1 ORDER BY name LIMIT 1")

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

    def forget_voice(self, person_id: str, *, delete_note: bool = False) -> list[str]:
        """Delete the person's voice data (samples, enrollment audio, consent); clear their label
        assignments. Returns the conversations whose labels changed."""
        folder = self.person_dir(person_id)
        if folder.exists():
            shutil.rmtree(folder)
        person = self.person(person_id)
        if delete_note and person is not None and person["note_path"]:
            remove(self.vault.root / person["note_path"])
        affected = [r["conversation_id"] for r in self.db.query(
            "SELECT DISTINCT conversation_id FROM speaker_labels WHERE person_id=? OR not_json LIKE ?",
            (person_id, f'%"{person_id}"%'))]  # fmt: skip
        self.db.execute("DELETE FROM samples WHERE person_id=?", (person_id,))
        self.scan_people()
        return affected

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
                   conversation_id, label, request_id, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (data["sample_id"], data["person_id"], data["model"], data["model_sha"],
             np.asarray(decode_vector(data["vector_b64"]), dtype="<f4").tobytes(), data["source"], data.get("seconds"),
             data.get("day"), data.get("session"), data.get("conversation_id"), data.get("label"), data.get("request_id"),
             data.get("created_at") or 0.0),
        )  # fmt: skip

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

    def samples(self, model: str, model_sha: str) -> list[Sample]:
        return [
            Sample(r["id"], r["person_id"], np.frombuffer(r["vector"], dtype="<f4").astype(np.float32), r["source"],
                   r["day"], r["session"], r["created_at"])
            for r in self.db.query("SELECT * FROM samples WHERE model=? AND model_sha=? ORDER BY created_at, id", (model, model_sha))
        ]  # fmt: skip

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
            self.index_voices(conv_id, row["file"])
        return changed

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
                         "evidence_s": r["evidence_s"], "not": json.loads(r["not_json"])}
            for r in self.db.query("SELECT * FROM speaker_labels WHERE conversation_id=?", (conv_id,))
        }  # fmt: skip

    def write_labels(self, conv_id: str, states: dict[str, dict], *, transcript_sha: str | None,
                     request: tuple[str, dict] | None = None) -> int:  # fmt: skip
        """Persist label assignments (speakers.json, then the index); returns the new revision.
        `request`: an app request id and its result, remembered so a retry is answered, not redone."""
        row = self.db.one("SELECT speakers_revision FROM conversations WHERE id=?", (conv_id,))
        revision = (row["speakers_revision"] if row else 0) + 1
        kept = self.persisted(states)
        path = self.conv_dir(conv_id) / "speakers.json"
        data = Vault.read_json(path) or {}
        data.update(revision=revision, transcript_sha=transcript_sha, labels=kept)
        if request is not None:
            requests = dict(data.get("requests") or {})
            requests[request[0]] = request[1] | {"revision": revision}
            data["requests"] = dict(list(requests.items())[-REQUEST_MEMORY:])
        Vault.write_json(path, data)
        self.index_labels(conv_id, kept, revision)
        return revision

    @staticmethod
    def persisted(states: dict[str, dict]) -> dict[str, dict]:
        """What speakers.json keeps of label states: assignments, blocks, match evidence."""
        keys = ("person_id", "source", "distance", "margin", "evidence_s", "not")
        return {label: {k: (sorted(state.get(k) or []) if k == "not" else state.get(k)) for k in keys}
                for label, state in sorted(states.items())
                if state.get("person_id") or state.get("not") or state.get("distance") is not None}  # fmt: skip

    def request_result(self, conv_id: str, request_id: str) -> dict | None:
        data = Vault.read_json(self.conv_dir(conv_id) / "speakers.json") or {}
        return (data.get("requests") or {}).get(request_id)

    def index_labels(self, conv_id: str, states: dict[str, dict], revision: int) -> None:
        with self.db.tx() as conn:
            conn.execute("DELETE FROM speaker_labels WHERE conversation_id=?", (conv_id,))
            conn.executemany(
                """INSERT INTO speaker_labels (conversation_id, label, person_id, source, distance, margin, evidence_s, not_json)
                   VALUES (?,?,?,?,?,?,?,?)""",
                [(conv_id, label, s.get("person_id"), s.get("source"), s.get("distance"), s.get("margin"),
                  s.get("evidence_s"), json.dumps(sorted(s.get("not") or []))) for label, s in states.items()],
            )  # fmt: skip
            conn.execute("UPDATE conversations SET speakers_revision=? WHERE id=?", (revision, conv_id))

    def load_conversation(self, conv_id: str) -> None:
        """Index a conversation's voices and speakers files (rebuild)."""
        conv_dir = self.conv_dir(conv_id)
        voices = sorted(conv_dir.glob("voices-*.json"))
        if voices:
            self.index_voices(conv_id, voices[-1].name)
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
