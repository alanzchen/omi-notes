"""A note's recording, for listening on the phone (capture-format-v1.md, "Recording").

The playable audio is everything retained from the conversation's start to its end, cut from the
same raw chunks the transcript was made from (`ConversationPipeline.conversation_audio` with one
block for the whole span): quiet between speech included, never another conversation's audio.
Wall-clock time with no recorded audio (a phone or pendant gap) can't be played; it is reported as
a gap with a time map, never filled in. Rendered once as 16 kHz mono PCM WAV into a size-bounded
cache in the index directory (disposable, outside the vault) and served with byte ranges, so the
phone streams and seeks. Nothing here changes retention, the index or the vault.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
from pathlib import Path

import soundfile as sf

from .ingest import ApiError
from .providers import ProviderError
from .util import iso_utc_epoch
from .views import LISTED

log = logging.getLogger(__name__)

SAMPLE_RATE = 16000
MAX_SECONDS = 4 * 3600  # ~460 MB of PCM: longer is refused rather than rendered
CACHE_BYTES = 2 * 1024**3


def _row(pipeline, conv_id: str):
    row = pipeline.db.one(f"SELECT * FROM conversations WHERE id=? AND {LISTED}", (conv_id,))
    if row is None:
        raise ApiError(404, "not_found", "unknown conversation")
    return row


def _cache_dir(pipeline) -> Path:
    return Path(pipeline.settings.db_path).parent / "recordings"  # beside this vault's index: disposable


def _key(pipeline, row) -> str:
    """Changes whenever what would be decoded changes (new or deleted chunks, a new span)."""
    chunks = pipeline.db.query(
        """SELECT capture_id, chunk_sequence, raw_deleted FROM chunks
           WHERE device_id=? AND status='processed' AND audio_start IS NOT NULL
             AND audio_start <= ? AND audio_end >= ? ORDER BY capture_id, chunk_sequence""",
        (row["device_id"], row["end"] + 1, row["start"] - 1),
    )
    basis = [row["id"], row["start"], row["end"], [(c["capture_id"], c["chunk_sequence"], c["raw_deleted"]) for c in chunks]]
    return hashlib.sha256(json.dumps(basis).encode()).hexdigest()[:16]


def _unavailable(reason: str, row) -> dict:
    return {"available": False, "reason": reason, "duration_s": None, "span": _span(row), "gaps": [], "partial": False,
            "timemap": []}  # fmt: skip


def _span(row) -> dict:
    return {"started_at": iso_utc_epoch(row["start"]), "ended_at": iso_utc_epoch(row["end"]),
            "seconds": round(row["end"] - row["start"], 3)}  # fmt: skip


def render(pipeline, conv_id: str) -> tuple[dict, Path | None]:
    """(metadata, the WAV file when available). Renders on first use, then reuses the cache."""
    row = _row(pipeline, conv_id)
    if row["status"] == "open":
        return _unavailable("in_progress", row), None
    if row["end"] - row["start"] > MAX_SECONDS:
        return _unavailable("too_long", row), None
    if not pipeline.speakers.raw_available(row):
        return _unavailable("expired", row), None
    folder = _cache_dir(pipeline)
    base = folder / f"{conv_id}-{_key(pipeline, row)}"
    wav, info = base.with_suffix(".wav"), base.with_suffix(".json")
    if wav.exists() and info.exists():
        os.utime(wav)  # recently used
        return json.loads(info.read_text()), wav
    try:
        audio = pipeline.conversation_audio(row, blocks=[(row["start"], row["end"])])
    except ProviderError as exc:  # a chunk's raw audio went meanwhile
        log.info("recording of %s unavailable: %s", conv_id, exc)
        return _unavailable("expired", row), None
    if len(audio.pcm) == 0:
        return _unavailable("no_audio", row), None
    folder.mkdir(parents=True, exist_ok=True)
    tmp = base.with_suffix(f".{os.getpid()}.tmp")
    sf.write(tmp, audio.pcm, SAMPLE_RATE, format="WAV", subtype="PCM_16")
    gaps = [{"started_at": iso_utc_epoch(a), "ended_at": iso_utc_epoch(b), "seconds": round(b - a, 3)} for a, b in audio.missing]
    meta = {"available": True, "reason": None, "duration_s": round(audio.duration, 3), "span": _span(row), "gaps": gaps,
            "partial": bool(gaps), "timemap": [[round(m.out_start, 3), m.wall_start, round(m.duration, 3)] for m in audio.timemap]}  # fmt: skip
    info.write_text(json.dumps(meta))
    os.replace(tmp, wav)
    _prune(folder, keep=wav)
    return meta, wav


def _prune(folder: Path, keep: Path) -> None:
    """Least recently used first, down to CACHE_BYTES (the cache is disposable)."""
    files = sorted(folder.glob("*.wav"), key=lambda p: p.stat().st_mtime)
    total = sum(p.stat().st_size for p in files)
    for p in files:
        if total <= CACHE_BYTES:
            break
        if p == keep:
            continue
        total -= p.stat().st_size
        p.unlink(missing_ok=True)
        p.with_suffix(".json").unlink(missing_ok=True)


def describe(pipeline, conv_id: str) -> dict:
    meta, _ = render(pipeline, conv_id)
    return meta | {"url": f"/v1/conversations/{conv_id}/recording.wav" if meta["available"] else None}


def wav_file(pipeline, conv_id: str) -> Path:
    meta, path = render(pipeline, conv_id)
    if path is None:
        status = 410 if meta["reason"] == "expired" else 409
        code = {"expired": "audio_expired", "no_audio": "no_audio", "too_long": "too_long", "in_progress": "in_progress"}[meta["reason"]]
        raise ApiError(status, code, f"no recording to play ({meta['reason']})")
    return path

