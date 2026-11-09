"""F0 for samples made before it was measured at the voices stage (docs/speaker-learning.md, "Review").

- `measure`: from raw audio where it still exists (or from a person's stored enrollment audio), with the
  production estimator (`audio.pitch`), on the sample's own clip bounds.
- `import_bench`: once, from the 2026-11-08 speaker bench (`pitch.json` + `clips.json` + `manifest.json`),
  for samples whose audio was measured there: only where the sample's conversation, label, voices
  generation, audio and clip bounds (starts within 0.05 s) match the bench's clips.

Both only add fields: an existing measurement is never overwritten, a sample's state and revision are
untouched, and anything that doesn't match is skipped and counted. F0 is review evidence, never identity.
"""

from __future__ import annotations

import io
import json
import re
import time
from collections import Counter
from pathlib import Path

import numpy as np
import soundfile as sf

from ..audio import pitch
from ..vault import Vault
from .voices import cosine_distance, decode_vector

START_TOLERANCE = 0.05
BENCH_TAG = "bench-20261108"
BENCH_ESTIMATOR = ("torchaudio.functional.detect_pitch_frequency (bench scripts/pitch.py: 30 ms frames, 70-400 Hz, "
                   "median of energetic frames within 75-380 Hz, >= 5 frames)")  # fmt: skip
ENROLLMENT_WINDOW = 10.0
_AUDIO16 = re.compile(r"-([0-9a-f]{16})-(?:c[0-9a-f]{8}-)?[0-9a-f]{0,8}\.json$")


def audio16(voices_file: str | None) -> str | None:
    """The audio sha prefix a voices file name was made for."""
    match = _AUDIO16.search(voices_file or "")
    return match.group(1) if match else None


def sample_files(vault: Vault) -> list[Path]:
    return sorted(vault.people.glob("*/samples/*.json")) if vault.people.exists() else []


def sample_spans(store, data: dict) -> tuple[list[list[float]], str | None] | None:
    """(clip bounds on the submitted-audio clock, voices file) the sample was embedded from: recorded with it,
    else the stored voice in its conversation's voices files whose vector is exactly the sample's."""
    if data.get("clips"):
        return [[float(a), float(b)] for a, b in data["clips"]], data.get("voices_file")
    conv_id = data.get("conversation_id")
    if not conv_id or not data.get("vector_b64"):
        return None
    vector = decode_vector(data["vector_b64"])
    for path in sorted(store.conv_dir(conv_id).glob("voices-*.json")):
        for entry in ((Vault.read_json(path) or {}).get("labels") or {}).values():
            if entry.get("vector_b64") and entry.get("clips") and cosine_distance(decode_vector(entry["vector_b64"]), vector) < 1e-6:
                return [[float(a), float(b)] for a, b in entry["clips"]], path.name
    return None


def measure(pipeline, now: float | None = None) -> Counter:
    """Measure F0 for every sample that has none yet. Returns counts by outcome."""
    now = time.time() if now is None else now
    store, db = pipeline.speakers, pipeline.db
    counts: Counter = Counter()
    audio_cache: dict[str, object] = {}
    for path in sample_files(pipeline.vault):
        data = Vault.read_json(path) or {}
        person_id, sample_id = data.get("person_id"), data.get("sample_id")
        if not person_id or not sample_id:
            counts["unreadable"] += 1
            continue
        if data.get("f0") is not None or data.get("f0_measurement"):
            counts["already measured"] += 1
            continue
        enrollment = store.person_dir(person_id) / "enrollment" / f"{data.get('enrollment_id')}.omiaudio"
        if data.get("source") == "enrollment" and data.get("enrollment_id") and enrollment.exists():
            pcm, _ = sf.read(io.BytesIO(enrollment.read_bytes()), dtype="int16")
            seconds = len(pcm) / pitch.SR
            spans = [[t, min(t + ENROLLMENT_WINDOW, seconds)] for t in np.arange(0.0, seconds, ENROLLMENT_WINDOW)]
            source = "enrollment-audio"
        else:
            found = sample_spans(store, data)
            row = db.one("SELECT * FROM conversations WHERE id=?", (data.get("conversation_id"),)) if data.get("conversation_id") else None
            if found is None:
                counts["skipped (no clip bounds)"] += 1
                continue
            spans, voices_file = found
            if row is None or not store.raw_available(row):
                counts["skipped (no raw audio)"] += 1
                continue
            expected = (data.get("audio_sha") or "")[:16] or audio16(voices_file)
            if expected and (row["audio_sha"] or "")[:16] != expected:
                counts["skipped (audio changed since)"] += 1  # the bounds belong to another assembly of the audio
                continue
            if row["id"] not in audio_cache:
                audio_cache.clear()  # one conversation's audio at a time
                audio_cache[row["id"]] = pipeline.conversation_audio(row)
            pcm = audio_cache[row["id"]].pcm
            source = "raw-backfill"
        result = pitch.voice_f0(pcm, spans)
        if result["f0"] is not None:
            fields = {"f0": result["f0"], "f0_voiced": result["voiced"], "f0_source": source, "f0_estimator": result["estimator"],
                      "f0_measured_at": now}  # fmt: skip
        else:
            fields = {"f0_measurement": {"f0": None, "voiced": result["voiced"], "source": source,
                                         "estimator": result["estimator"], "at": now}}  # fmt: skip
        with store.lock:
            added = store.add_sample_fields(person_id, sample_id, fields)
        counts["measured" if added and result["f0"] is not None else "unknown (too little voiced speech)" if added else "already measured"] += 1
    return counts


def _bench_files(directory: Path) -> Path:
    if not (directory / "pitch.json").exists() and (directory / "data" / "pitch.json").exists():
        return directory / "data"
    return directory


def import_bench(store, db, directory: Path, *, tag: str = BENCH_TAG, now: float | None = None) -> Counter:
    """Import bench F0 (see the module docstring). Returns counts by outcome."""
    now = time.time() if now is None else now
    directory = _bench_files(Path(directory).expanduser())
    pitches = json.loads((directory / "pitch.json").read_text())
    clips = json.loads((directory / "clips.json").read_text())
    manifest_path = directory / "manifest.json"
    manifest = {m["id"]: m for m in json.loads(manifest_path.read_text())} if manifest_path.exists() else {}
    by_key: dict[tuple[str, str], list[dict]] = {}
    for clip in clips:
        by_key.setdefault((clip["cid"], clip["label"]), []).append(clip)
    counts: Counter = Counter()
    for path in sample_files(store.vault):
        data = Vault.read_json(path) or {}
        if data.get("f0") is not None:
            counts["skipped (already measured)"] += 1
            continue
        entries = by_key.get((data.get("conversation_id"), data.get("label")))
        if not entries:
            counts["skipped (not in the bench)"] += 1
            continue
        why, matched = _match(store, db, data, entries, manifest.get(data["conversation_id"]))
        if why:
            counts[f"skipped ({why})"] += 1
            continue
        values = [float(pitches[str(c["i"])]) for c in matched if pitches.get(str(c["i"])) is not None]
        if not values:
            counts["skipped (no pitch in the bench)"] += 1
            continue
        fields = {"f0": round(float(np.median(values)), 2), "f0_source": tag, "f0_estimator": BENCH_ESTIMATOR,
                  "f0_clips": [int(c["i"]) for c in matched], "f0_aggregation": "median of the clips' median F0",
                  "f0_imported_at": now}  # fmt: skip
        with store.lock:
            added = store.add_sample_fields(data["person_id"], data["sample_id"], fields)
        counts["imported" if added else "skipped (already measured)"] += 1
    return counts


def _match(store, db, data: dict, entries: list[dict], bench: dict | None) -> tuple[str, list[dict]]:
    """("", the bench clips in the sample's clip order) when the bench measured exactly this sample's audio."""
    row = db.one("SELECT id, start, audio_sha FROM conversations WHERE id=?", (data["conversation_id"],))
    if row is None:
        return "conversation not indexed", []
    if any(abs(float(c["start"]) - float(row["start"])) > START_TOLERANCE for c in entries):
        return "conversation start differs", []
    if bench is None:
        return "no clip bounds in the bench", []
    found = sample_spans(store, data)
    if found is None:
        return "no clip bounds", []
    spans, voices_file = found
    if bench.get("voices_file") and voices_file and bench["voices_file"] != voices_file:
        return "voices generation differs", []
    bench_audio = audio16(bench.get("voices_file"))
    if bench_audio and bench_audio != (data.get("audio_sha") or "")[:16] and bench_audio != audio16(voices_file):
        return "audio differs", []
    bounds = (bench.get("labels") or {}).get(data["label"], {}).get("clips") or []
    located = [(bounds[c["j"]], c) for c in entries if 0 <= int(c["j"]) < len(bounds)]
    if len(located) != len(spans):
        return "clip bounds differ", []
    matched = []
    for (a, _b), (bench_span, clip) in zip(sorted(spans), sorted(located, key=lambda x: float(x[0][0])), strict=True):
        if abs(float(a) - float(bench_span[0])) > START_TOLERANCE:
            return "clip bounds differ", []
        matched.append(clip)
    order = {tuple(s): i for i, s in enumerate(spans)}
    pairs = sorted(zip(sorted(spans), matched, strict=True), key=lambda p: order[tuple(p[0])])
    return "", [clip for _, clip in pairs]
