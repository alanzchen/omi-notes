"""Voice enrollment through the pendant (docs/speaker-learning.md, "Enrollment").

The phone marks a window on a live capture with `voice_enrollment_start` / `voice_enrollment_end`
events (monotonic offsets). The window:

- splits conversations at both ends (like a double tap);
- makes a conversation that lies inside it a "voice enrollment": finalized as discarded **without
  STT** (`decision.enrollment_id` in its record, so a rebuild keeps it that way);
- keeps a conversation that overlaps a window whose end hasn't arrived yet open (at most
  `OPEN_MAX_SECONDS`), so enrollment speech can't reach STT before the end is known;
- protects its raw audio from retention until the enrollment is decided.

Once the capture's audio through the end is processed, the window's speech is judged: ≥ 20 s of
speech, level/clipping, ≥ 80 % of 3 s windows within 0.5 of their centroid (one voice), and a
disjoint held-out clip matching that centroid. The result is a vault file
(`_omi/speakers/enrollments/<id>.json`); an accepted enrollment also becomes an `enrollment`
sample of the "me" person (created as "Me" if missing) with the wearer's audio saved for
re-embedding. "Accepted" means enrolled, not calibrated: enrollment alone never activates
automatic naming (see `speakers/match.py`).
"""

from __future__ import annotations

import io
import json
import logging
import uuid
from dataclasses import dataclass, replace
from datetime import datetime
from pathlib import Path

import numpy as np
import soundfile as sf

from ..audio.embed import normalized
from ..vault import Vault
from .voices import cosine_distance

log = logging.getLogger(__name__)

SR = 16000
MIN_SPEECH_SECONDS = 20.0
WINDOW_SECONDS = 3.0
CONSISTENT_FRACTION = 0.8
CONSISTENCY_DISTANCE = 0.5
HELD_OUT_FRACTION = 0.2
HELD_OUT_MIN_SECONDS = 3.0
MIN_RMS_DBFS = -45.0
MAX_CLIPPED_FRACTION = 0.01
OPEN_MAX_SECONDS = 900.0  # a start without an end this long (on a finished capture) is interrupted
EDGE = 0.5  # seconds of slack when deciding whether a conversation lies inside a window


@dataclass(frozen=True)
class Window:
    enrollment_id: str
    device_id: str
    capture_id: str | None
    start: float
    end: float | None
    outcome: str | None
    received_at: float  # when the start event arrived


def windows(db, device_id: str | None = None) -> list[Window]:
    """Enrollment windows from the indexed events (start and end joined by enrollment id)."""
    where, args = ("AND device_id=?", (device_id,)) if device_id else ("", ())
    starts: dict[str, dict] = {}
    ends: dict[str, dict] = {}
    for ev in db.query(
        f"""SELECT * FROM event_times WHERE type IN ('voice_enrollment_start','voice_enrollment_end') {where}
            ORDER BY received_at""",
        args,
    ):
        data = (json.loads(ev["body_json"]).get("data") or {})
        eid = data.get("enrollment_id")
        if not eid:
            continue
        target = starts if ev["type"] == "voice_enrollment_start" else ends
        target.setdefault(eid, {"ev": ev, "data": data})
    out = []
    for eid, s in starts.items():
        ev, end = s["ev"], ends.get(eid)
        end_t = outcome = None
        if end is not None:
            outcome = end["data"].get("outcome")
            e = end["ev"]
            end_t = e["t"] if e["capture_id"] == ev["capture_id"] else None
        out.append(Window(eid, ev["device_id"], ev["capture_id"], float(ev["t"]),
                          None if end_t is None else float(end_t), outcome, float(ev["received_at"])))  # fmt: skip
    return out


def settle(ws: list[Window], now: float, capture_finished, capture_end) -> list[Window]:
    """Windows whose end will never come (the phone crashed, the end landed in another capture):
    once stale they end with their capture's audio — the reading stays excluded whatever the
    enrollment result. Without a capture, the window is bounded by OPEN_MAX_SECONDS."""
    out = []
    for w in ws:
        if w.end is None and stale(w, now, capture_finished):
            end = capture_end(w.capture_id) if w.capture_id else None
            w = replace(w, end=max(w.start, end if end is not None else w.start + OPEN_MAX_SECONDS),
                        outcome=w.outcome or "interrupted")  # fmt: skip
        out.append(w)
    return out


def boundaries(ws: list[Window]) -> list[tuple[float, str | None]]:
    """(time, capture) split points: every window start and every known end."""
    points = []
    for w in ws:
        points.append((w.start, w.capture_id))
        if w.end is not None:
            points.append((w.end, w.capture_id))
    return points


def classify(ws: list[Window], start: float, end: float, now: float, capture_finished) -> tuple[str, str] | None:
    """For a conversation about to close: ("inside", id) → finalize as a voice enrollment;
    ("wait", id) → keep it open (its window's end isn't known yet); None → normal."""
    for w in ws:
        if w.end is not None and start >= w.start - EDGE and end <= w.end + EDGE:
            return "inside", w.enrollment_id
    for w in ws:
        if w.end is None and w.start <= end + EDGE and not stale(w, now, capture_finished):
            return "wait", w.enrollment_id
    return None


def stale(w: Window, now: float, capture_finished) -> bool:
    return now - w.received_at > OPEN_MAX_SECONDS and (w.capture_id is None or capture_finished(w.capture_id))


# -- judging the audio ------------------------------------------------------------------------------


def evaluate(speech: np.ndarray, embedder) -> dict:
    """Judge the window's speech (int16 PCM at 16 kHz, speech only). Pure apart from `embedder`.
    Returns {state, speech_s, reason?, vector?, enroll_pcm?, consistency, held_out_distance}."""
    seconds = len(speech) / SR
    result: dict = {"speech_s": round(seconds, 2)}
    if seconds < MIN_SPEECH_SECONDS:
        return result | {"state": "needs_another_sample",
                         "reason": f"Only {seconds:.0f} s of clear speech reached the server (20 s needed). "
                                   "Read every sentence in your normal voice, in a quiet place."}  # fmt: skip
    x = speech.astype(np.float64) / 32768.0
    rms = float(np.sqrt(np.mean(x**2))) or 1e-9
    dbfs = 20 * np.log10(rms)
    clipped = float(np.mean(np.abs(speech.astype(np.int32)) >= 32000))
    result |= {"level_dbfs": round(dbfs, 1), "clipped_fraction": round(clipped, 4)}
    if dbfs < MIN_RMS_DBFS:
        return result | {"state": "needs_another_sample",
                         "reason": "The recording was too quiet. Wear the pendant as usual and speak normally."}
    if clipped > MAX_CLIPPED_FRACTION:
        return result | {"state": "needs_another_sample",
                         "reason": "The recording was distorted (too loud or too close). Try again a little quieter."}
    held_n = max(int(len(speech) * HELD_OUT_FRACTION), int(HELD_OUT_MIN_SECONDS * SR))
    enroll, held = speech[:-held_n], speech[-held_n:]
    step = int(WINDOW_SECONDS * SR)
    windows_ = [enroll[i : i + step] for i in range(0, len(enroll) - step + 1, step)]
    vectors = [normalized(embedder.embed(w)) for w in windows_]
    centroid = normalized(np.mean(vectors, axis=0))
    distances = [cosine_distance(v, centroid) for v in vectors]
    consistency = float(np.mean([d <= CONSISTENCY_DISTANCE for d in distances]))
    held_distance = cosine_distance(normalized(embedder.embed(held)), centroid)
    result |= {"consistency": round(consistency, 3), "held_out_distance": round(held_distance, 3), "windows": len(vectors)}
    if consistency < CONSISTENT_FRACTION:
        return result | {"state": "needs_another_sample",
                         "reason": "More than one voice was heard. Read the sentences alone, somewhere quiet."}
    if held_distance > CONSISTENCY_DISTANCE:
        return result | {"state": "needs_another_sample",
                         "reason": "The last sentences didn't match the first ones. Please try again."}
    return result | {"state": "accepted", "vector": centroid, "enroll_pcm": enroll}


def flac_bytes(pcm: np.ndarray) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, pcm.astype(np.int16), SR, format="FLAC", subtype="PCM_16")
    return buf.getvalue()


# -- results ----------------------------------------------------------------------------------------


def result_path(vault: Vault, enrollment_id: str) -> Path:
    return vault.omi / "speakers" / "enrollments" / f"{enrollment_id}.json"


def read_result(vault: Vault, enrollment_id: str) -> dict | None:
    path = result_path(vault, enrollment_id)
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None


def status(vault: Vault, db, enrollment_id: str) -> dict | None:
    """What `GET /v1/speakers/enrollments/{id}` reports; None for an unknown id."""
    result = read_result(vault, enrollment_id)
    if result is not None:
        return {k: result.get(k) for k in ("state", "speech_s", "reason") if result.get(k) is not None}
    for w in windows(db):
        if w.enrollment_id == enrollment_id:
            return {"state": "processing" if w.end is not None and w.outcome == "completed" else "waiting_audio"}
    return None


class EnrollmentProcessor:
    """Decides finished windows (worker tick). Each enrollment is decided once: its result file."""

    def __init__(self, worker) -> None:
        self.worker = worker
        self.db = worker.db
        self.vault = worker.vault
        self.pipeline = worker.pipeline

    def capture_finished(self, capture_id: str) -> bool:
        cap = self.db.one("SELECT last_chunk_sequence, processed_through FROM captures WHERE capture_id=?", (capture_id,))
        return cap is not None and cap["last_chunk_sequence"] is not None and cap["processed_through"] >= cap["last_chunk_sequence"]

    def undecided(self) -> list[Window]:
        return [w for w in windows(self.db) if read_result(self.vault, w.enrollment_id) is None]

    def run(self, now: float) -> int:
        decided = 0
        for w in self.undecided():
            try:
                if self._decide(w, now):
                    decided += 1
            except Exception:  # one enrollment's problem must not stop the worker
                log.exception("enrollment %s could not be decided", w.enrollment_id)
        return decided

    def _decide(self, w: Window, now: float) -> bool:
        if w.end is None:
            if not stale(w, now, self.capture_finished):
                return False
            return self._write(w, {"state": "interrupted", "reason": "The enrollment never finished."}, now)
        if w.outcome != "completed":
            return self._write(w, {"state": w.outcome or "interrupted", "reason": "The enrollment was not completed."}, now)
        if w.capture_id is None or not self.worker.capture_reached(w.capture_id, w.end):
            return False  # waiting for the window's audio to be processed
        embedder = self.pipeline.providers.embedder
        if embedder is None:
            return self._write(w, {"state": "needs_another_sample",
                                   "reason": "The speaker model isn't installed on the server "
                                             "(run `omi-notes fetch-models --speakers`)."}, now)  # fmt: skip
        verdict = evaluate(self.speech_pcm(w), embedder)
        vector, enroll_pcm = verdict.pop("vector", None), verdict.pop("enroll_pcm", None)
        extra: dict = {}
        store = self.pipeline.speakers
        with store.lock:
            if verdict["state"] == "accepted":
                request = f"enrollment:{w.enrollment_id}"  # a crash before the result: reuse the sample
                store.sync_samples()  # (including one whose index write failed)
                done = store.sample_for_request(request)
                me = store.me()
                if done is not None:
                    person_id, sample_id = done["person_id"], done["id"]
                else:
                    if me is None:
                        person_id = str(uuid.uuid4())
                        store.put_person(person_id, "Me", me=True, now=now)
                    else:
                        person_id = me["id"]
                    day = datetime.fromtimestamp(w.start, self.pipeline.tz).date().isoformat()
                    sample_id = store.add_sample(person_id, vector, model=embedder.model, model_sha=embedder.model_sha,
                                                 source="enrollment", seconds=verdict["speech_s"], day=day,
                                                 session=w.enrollment_id, enrollment_id=w.enrollment_id,
                                                 request_id=request, now=now)  # fmt: skip
                extra = {"person_id": person_id, "sample_id": sample_id, "model": embedder.model, "model_sha": embedder.model_sha}
                store.save_enrollment(person_id, w.enrollment_id, flac_bytes(enroll_pcm), verdict | extra | {"decided_at": now})
            self._write(w, verdict | extra, now)
        if verdict["state"] == "accepted":
            self.db.set_meta("relabel_pending", "1")
        log.info("voice enrollment %s: %s (%.0f s)", w.enrollment_id, verdict["state"], verdict.get("speech_s", 0))
        return True

    def _write(self, w: Window, result: dict, now: float) -> bool:
        Vault.write_json(result_path(self.vault, w.enrollment_id), {
            "enrollment_id": w.enrollment_id, "device_id": w.device_id, "capture_id": w.capture_id,
            "start": w.start, "end": w.end, "decided_at": now, **result,
        })  # fmt: skip
        return True

    def speech_pcm(self, w: Window) -> np.ndarray:
        """The window's detected speech, decoded from the raw chunks (speech only, in order)."""
        chunks = self.db.query(
            """SELECT chunk_sequence FROM chunks WHERE capture_id=? AND status='processed' AND audio_start IS NOT NULL
               AND audio_start <= ? AND audio_end >= ? ORDER BY chunk_sequence""",
            (w.capture_id, w.end, w.start),
        )
        if not chunks:
            return np.zeros(0, np.int16)
        capture = self.db.one("SELECT * FROM captures WHERE capture_id=?", (w.capture_id,))
        pieces = self.pipeline.decode_range(capture, chunks[0]["chunk_sequence"], chunks[-1]["chunk_sequence"])
        speech = self.db.query(
            "SELECT start, end FROM speech WHERE capture_id=? AND end > ? AND start < ? ORDER BY start",
            (w.capture_id, w.start, w.end),
        )
        parts = []
        for s in speech:
            lo, hi = max(s["start"], w.start), min(s["end"], w.end)
            for p in pieces:
                a, b = max(lo, p.start), min(hi, p.end)
                if b > a:
                    parts.append(p.pcm[round((a - p.start) * SR) : round((b - p.start) * SR)])
        return np.concatenate(parts).astype(np.int16) if parts else np.zeros(0, np.int16)

