"""Ground-truth enrollment from audio the owner points at (docs/speaker-learning.md, "Enrollment import").

`POST /v1/people/{id}/enrollments/import` takes either a range of an existing recording
({conversation_id, start, end}: seconds from the conversation's start, raw audio required) or an uploaded
file (multipart `file`: m4a or wav, ≤ 20 min), always with `confirm_person: true` and the person's name
echoed in `person_name`: an import says "this is X speaking", so it must be said explicitly.

- Consent: anyone but the wearer needs the acknowledgment and their attestation, checked here (an import
  is never treated as attested just because it is an enrollment).
- The same checks as a pendant enrollment (`enroll.evaluate`): ≥ 20 s of VAD speech, one consistent
  voice, a disjoint held-out clip that matches.
- Idempotent by (person, source sha256, start, end): the import id is derived from them. A range that an
  earlier import of the same source already covers returns that import; one that overlaps is merged:
  the union is judged as one enrollment and replaces the imports it covers (their samples soft-removed),
  so repeating audio can never add seconds.
- Kept: an `enrollment` sample (provenance under `import`, the conversation as its session, so a held-out
  evaluation leaves it out with its conversation) and the speech as `.omiaudio` in the person's folder,
  deleted when the person is forgotten, like the wearer's pendant enrollment.

Once a person holds ≥ 60 s of enrollment their centroid is enrollment-only (`match.enrollment_only`); the
activation gate is unchanged, and older samples that contradict it are flagged for review only.
"""

from __future__ import annotations

import email.parser
import email.policy
import hashlib
import io
import time
import uuid
from datetime import datetime

import numpy as np
import soundfile as sf

from ..audio import aac
from ..audio.vad import make_vad, speech_intervals
from ..ingest import ApiError
from ..util import UUID_RE
from . import enroll
from ..spool import atomic_write_bytes
from ..vault import Vault
from . import journal
from .store import ACTIVE
from .voices import encode_vector

SR = 16000
MAX_SECONDS = 20 * 60
MAX_UPLOAD_BYTES = 120 * 1024 * 1024  # a 20-minute 48 kHz stereo WAV is ~230 MB; m4a and 16 kHz mono fit easily


def parse_multipart(content_type: str, body: bytes) -> tuple[dict[str, str], tuple[str, bytes] | None]:
    """(form fields, (filename, bytes) of the `file` part) of a multipart/form-data body."""
    message = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\nMIME-Version: 1.0\r\n\r\n" + body
    )
    if not message.is_multipart():
        raise ApiError(422, "invalid_body", "expected multipart/form-data")
    fields: dict[str, str] = {}
    upload = None
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        payload = part.get_payload(decode=True) or b""
        if name == "file":
            upload = (part.get_filename() or "upload", payload)
        elif name:
            fields[name] = payload.decode("utf-8", errors="replace")
    return fields, upload


def decode_upload(filename: str, payload: bytes) -> np.ndarray:
    """16 kHz mono int16 of an uploaded m4a (ffmpeg, the Watch decoder) or wav (soundfile)."""
    lower = filename.lower()
    if lower.endswith((".m4a", ".mp4", ".aac")):
        try:
            return aac.decode(payload, None, max_samples=MAX_SECONDS * SR)
        except aac.AacError as exc:
            raise ApiError(422, "undecodable_audio", str(exc)) from exc
    try:
        data, rate = sf.read(io.BytesIO(payload), dtype="int16", always_2d=True)
    except Exception as exc:  # soundfile raises its own error types
        raise ApiError(422, "undecodable_audio", "expected an m4a or wav file") from exc
    if rate != SR:  # a band-limited resampler (ffmpeg's), never interpolation that aliases
        try:
            return aac.resample(payload, ".wav", MAX_SECONDS * SR)
        except aac.AacError as exc:
            raise ApiError(422, "undecodable_audio", str(exc)) from exc
    pcm = data.mean(axis=1) if data.shape[1] > 1 else data[:, 0].astype(np.float64)
    return np.clip(np.round(pcm), -32768, 32767).astype(np.int16)


def authorized(consent: tuple | None) -> bool:
    """The import's consent snapshot (`Importer._consent`) allows keeping this voice: the wearer, or attested after
    the acknowledgment."""
    return consent is not None and bool(consent[0] or (consent[1] and consent[2]))


def import_id(person_id: str, sha: str, start: float, end: float) -> str:
    digest = hashlib.sha256(f"{person_id}:{sha}:{start:.3f}:{end:.3f}".encode()).digest()
    return str(uuid.UUID(bytes=digest[:16], version=4))


class Importer:
    def __init__(self, service) -> None:
        self.service = service
        self.pipeline = service.pipeline
        self.store = service.store
        self.db = service.db
        self._vad = None

    @property
    def vad(self):
        if self._vad is None:
            s = self.pipeline.settings
            self._vad = make_vad(s.vad_backend, s.vad_model_path, s.vad_threshold).vad
        return self._vad

    # -- request ---------------------------------------------------------------------------------

    def run(self, person_id: str, fields: dict, upload: tuple[str, bytes] | None) -> tuple[int, dict]:
        if not UUID_RE.match(person_id):
            raise ApiError(404, "not_found", "unknown person")
        with self.store.lock:  # the authorization is the snapshot it was made from, taken together
            consent = self._consent(person_id)
            person = self.store.person(person_id)
        if consent is None or person is None:
            raise ApiError(404, "not_found", "unknown person")
        confirm = fields.get("confirm_person")
        if confirm not in (True, "true", "1"):
            raise ApiError(422, "confirm_person_required", "confirm_person: true is required (this audio is that person)")
        name = fields.get("person_name")
        if not isinstance(name, str) or name.strip().casefold() != person["name"].strip().casefold():
            raise ApiError(422, "person_name_mismatch", f"person_name must be this person's name ({person['name']})")
        if not authorized(consent):
            raise ApiError(409, "consent_required", "this person's voice can't be kept without the acknowledgment and their attestation")
        embedder = self.pipeline.providers.embedder
        if embedder is None:
            raise ApiError(409, "no_speaker_model", "the speaker model isn't installed (`omi-notes fetch-models --speakers`)")
        source, pcm, day, whole = self._source(fields, upload)
        return self._enroll(person_id, consent, source, pcm, day, embedder, whole)

    def _consent(self, person_id: str) -> tuple | None:
        """What the import was allowed by (None: the person is gone): rechecked before anything is written."""
        self.store.scan_people()
        person = self.store.person(person_id)
        if person is None:
            return None
        return (bool(person["me"]), person["attested_at"], self.store.settings()["acknowledged_at"], self.store.forget_count(person_id))

    def _range(self, fields: dict, total: float | None) -> tuple[float, float]:
        try:
            start = float(fields.get("start", 0.0) or 0.0)
            end = float(fields["end"]) if fields.get("end") not in (None, "") else total
        except (TypeError, ValueError) as exc:
            raise ApiError(422, "invalid_body", "start and end are seconds") from exc
        if end is None or not (0 <= start < end) or end - start > MAX_SECONDS:
            raise ApiError(422, "invalid_range", f"start < end, at most {MAX_SECONDS // 60} minutes apart")
        return round(start, 3), round(end, 3)

    def _source(self, fields: dict, upload) -> tuple[dict, np.ndarray, str, np.ndarray | None]:
        """(provenance, the range's PCM, the local day of the audio, an upload's whole PCM)."""
        if upload is not None:
            filename, payload = upload
            if len(payload) > MAX_UPLOAD_BYTES:
                raise ApiError(413, "too_large", "the file is larger than a 20-minute recording")
            pcm = decode_upload(filename, payload)
            if len(pcm) > MAX_SECONDS * SR + SR:
                raise ApiError(422, "too_long", "the recording is longer than 20 minutes")
            start, end = self._range(fields, len(pcm) / SR)
            source = {"kind": "upload", "filename": filename[:120], "sha256": hashlib.sha256(payload).hexdigest(),
                      "start": start, "end": end}  # fmt: skip
            return source, pcm[int(start * SR) : int(end * SR)], datetime.now(self.pipeline.tz).date().isoformat(), pcm
        conv_id = fields.get("conversation_id")
        if not isinstance(conv_id, str) or not UUID_RE.match(conv_id):
            raise ApiError(422, "invalid_body", "conversation_id (or a multipart file) is required")
        row = self.service._conversation(conv_id)
        if row["enrollment_id"]:
            raise ApiError(409, "voice_enrollment", "a voice-enrollment reading is enrolled by the pendant flow")
        if not self.store.raw_available(row):
            raise ApiError(410, "audio_expired", "the raw audio of this conversation is gone")
        start, end = self._range(fields, None)
        audio = self.pipeline.conversation_audio(row)
        lo, hi = row["start"] + start, row["start"] + end
        parts = []
        for m in audio.timemap:  # the conversation's speech blocks, on its wall clock
            a, b = max(lo, m.wall_start), min(hi, m.wall_start + m.duration)
            if b > a:
                i0 = int(round((m.out_start + a - m.wall_start) * SR))
                parts.append(audio.pcm[i0 : i0 + int(round((b - a) * SR))])
        pcm = np.concatenate(parts).astype(np.int16) if parts else np.zeros(0, np.int16)
        source = {"kind": "conversation", "conversation_id": conv_id, "sha256": row["audio_sha"], "start": start, "end": end}
        return source, pcm, datetime.fromtimestamp(row["start"], self.pipeline.tz).date().isoformat(), None

    def _speech(self, pcm: np.ndarray) -> np.ndarray:
        spans = speech_intervals(self.vad, pcm, 0.0) if len(pcm) else []
        parts = [pcm[int(a * SR) : int(b * SR)] for a, b in spans]
        return np.concatenate(parts).astype(np.int16) if parts else np.zeros(0, np.int16)

    # -- the enrollment --------------------------------------------------------------------------

    def _imports(self, person_id: str, sha: str) -> list[dict]:
        """Active imports of this source for this person: [{import_id, start, end, sample}]."""
        out = []
        for r in self.db.query("SELECT id FROM samples WHERE person_id=? AND source='enrollment'", (person_id,)):
            data = self.store.read_sample(person_id, r["id"]) or {}
            src = data.get("import") or {}
            if src.get("sha256") == sha and (data.get("state") or ACTIVE) == ACTIVE:
                out.append({"import_id": data.get("enrollment_id"), "start": src["start"], "end": src["end"], "sample": data})
        return out

    def _answer(self, person_id: str, iid: str) -> dict | None:
        result = Vault.read_json(self.store.person_dir(person_id) / "enrollments" / f"{iid}.json")
        if result is None or result.get("state") != "accepted":
            return None
        return {k: result.get(k) for k in ("import_id", "state", "speech_s", "sample_id", "person_id", "merged", "source")}

    def _enroll(self, person_id: str, consent: tuple | None, source: dict, pcm: np.ndarray, day: str, embedder,
                whole: np.ndarray | None) -> tuple[int, dict]:  # fmt: skip
        sha, start, end = source["sha256"], source["start"], source["end"]
        iid = import_id(person_id, sha, start, end)
        with self.store.lock:
            self.store.reconcile()  # an interrupted import finishes before it is answered
            done = self._answer(person_id, iid)
            if done is not None:
                return 200, done
            existing = self._imports(person_id, sha)
            covering = next((e for e in existing if e["start"] <= start and e["end"] >= end), None)
            if covering is not None and (answer := self._answer(person_id, covering["import_id"])):
                return 200, answer  # already enrolled from this audio: no new seconds
        overlapping = [e for e in existing if e["start"] < end and e["end"] > start]
        if overlapping:
            # one enrollment from the union: repeated audio never counts twice
            start, end = min([start] + [e["start"] for e in overlapping]), max([end] + [e["end"] for e in overlapping])
            if source["kind"] == "conversation":
                source, pcm, day, _ = self._source({"conversation_id": source["conversation_id"], "start": start, "end": end}, None)
            else:  # the same file (same sha256): the union is cut from the whole upload
                if whole is None or end * SR > len(whole) + SR:
                    raise ApiError(409, "import_conflict", "the earlier import of this file covers audio this upload doesn't have")
                source, pcm = source | {"start": start, "end": end}, whole[int(start * SR) : int(end * SR)]
            iid = import_id(person_id, sha, start, end)
        verdict = enroll.evaluate(self._speech(pcm), embedder)  # outside the lock: the slow part
        if verdict["state"] != "accepted":
            code = "not_enough_speech" if verdict.get("speech_s", 0) < enroll.MIN_SPEECH_SECONDS else "enrollment_rejected"
            raise ApiError(422, code, verdict.get("reason") or "the recording was not accepted")
        vector, enroll_pcm = verdict.pop("vector"), verdict.pop("enroll_pcm")
        now = time.time()
        with self.store.lock:
            self.store.reconcile()
            done = self._answer(person_id, iid)
            if done is not None:
                return 200, done
            # what was judged must still hold: the person and their consent (a forget meanwhile is final), and the
            # imports the union replaces
            current = self._consent(person_id)
            if current is None or current[3] != consent[3]:
                raise ApiError(404, "not_found", "the person's voice was forgotten while the import was judged")
            if current != consent or not authorized(current):
                raise ApiError(409, "consent_required", "the person's consent changed while the import was judged; try again")
            if {e["import_id"] for e in self._imports(person_id, sha) if e["start"] < end and e["end"] > start} != {
                    e["import_id"] for e in overlapping}:  # fmt: skip
                raise ApiError(409, "import_conflict", "another import of this audio finished meanwhile; try again")
            request = f"import:{iid}"
            sample_id = str(uuid.uuid5(uuid.NAMESPACE_URL, request))
            person = self.store.person(person_id)
            sample = {
                "sample_id": sample_id, "person_id": person_id, "person_name": person["name"], "model": embedder.model,
                "model_sha": embedder.model_sha, "dim": int(len(vector)), "vector_b64": encode_vector(vector),
                "source": "enrollment", "seconds": round(float(verdict["speech_s"]), 3), "created_at": now, "day": day,
                "session": source.get("conversation_id") or f"import:{iid}", "conversation_id": source.get("conversation_id"),
                "label": None, "request_id": request, "enrollment_id": iid, "attested": bool(consent[0] or consent[1]),
                "import": source, "imported_at": now,
            }  # fmt: skip
            replaced = sorted(e["sample"]["sample_id"] for e in overlapping if e["import_id"] != iid)
            result = verdict | {"import_id": iid, "enrollment_id": iid, "person_id": person_id, "sample_id": sample_id,
                                "model": embedder.model, "model_sha": embedder.model_sha, "source": source,
                                "merged": sorted({e["import_id"] for e in overlapping if e["import_id"] != iid}),
                                "decided_at": now}  # fmt: skip
            # the audio first (unreferenced until the operation completes), then one journaled operation
            atomic_write_bytes(self.store.person_dir(person_id) / "enrollment" / f"{iid}.omiaudio", enroll.flac_bytes(enroll_pcm))
            journal.run(self.store, {"kind": "merge", "person": person_id, "import_id": iid, "request_id": request,
                                     "sample": sample, "replaced": replaced, "result": result})  # fmt: skip
            self.db.set_meta("relabel_pending", "1")
        self.service._relabel()
        return 201, self._answer(person_id, iid)
