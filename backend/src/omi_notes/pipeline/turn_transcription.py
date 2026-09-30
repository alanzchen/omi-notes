"""Text-only STT: local speaker windows supply timing, with one cached request per window.

Partition all submitted audio, including gaps at diarizer boundaries: no speech is dropped just
because the diarizer missed it. Times are window boundaries, not invented word timestamps.
Overlapping turns cannot be separated acoustically; keep their audio, but exclude it from voiceprints.

Diarizer edges produce windows of a few frames (17-51 ms). The service rejects audio under 0.1 s
(the configured proxy answers 502; probe 2026-09-30), so such a request is sent as the window's own
samples followed by silence up to `MIN_REQUEST_SECONDS`: no other speaker's audio is added, and
the answer keeps the window's speaker and times (never the padded length).

A window's cached answer is keyed on exactly what was sent (samples, length, speech blocks,
language, keyterms, provider, model, request style), not on its position: a change in segmentation
or padding can never reuse text made from other audio. Older position-named caches are ignored
(this code doesn't delete them; the pipeline's usual clean-up of unreferenced result files removes
them once the conversation completes).
"""

from __future__ import annotations

import hashlib
import io
import json
import math
from pathlib import Path

import numpy as np
import soundfile as sf

from ..audio.diarize import Turn
from ..providers import ProviderError, SttRequest
from ..providers.openai_stt import _flac, split_request
from ..spool import atomic_write_bytes

SR = 16000
# Requests shorter than this are padded with trailing silence (the service minimum is 0.1 s).
MIN_REQUEST_SECONDS = 0.25
CACHE_FORMAT = 2


def _padded(piece: SttRequest) -> tuple[SttRequest, np.ndarray]:
    """The request to send (padded with silence when too short) and its samples."""
    pcm = sf.read(io.BytesIO(piece.flac), dtype="int16")[0]
    if piece.duration >= MIN_REQUEST_SECONDS:
        return piece, pcm
    padded = np.concatenate([pcm, np.zeros(round(MIN_REQUEST_SECONDS * SR) - len(pcm), np.int16)])
    return SttRequest(_flac(padded), len(padded) / SR, piece.blocks, piece.language, piece.keyterms), padded


def _cache_path(cache_path: Path, provider, sent: SttRequest, pcm: np.ndarray) -> Path:
    identity = {
        "format": CACHE_FORMAT, "samples": hashlib.sha256(pcm.tobytes()).hexdigest(), "rate": SR,
        "duration": round(sent.duration, 6), "blocks": [[round(a, 6), round(b, 6)] for a, b in sent.blocks],
        "language": sent.language, "keyterms": list(sent.keyterms or []),
        "provider": getattr(provider, "name", ""), "model": getattr(provider, "model", ""),
        "cache_tag": getattr(provider, "cache_tag", ""), "style": getattr(provider, "style", ""),
    }  # fmt: skip
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()[:24]
    return cache_path.with_name(f"{cache_path.stem}-win{CACHE_FORMAT}-{key}.json")


def speaker_windows(turns: list[Turn], duration: float) -> tuple[list[Turn], list[tuple[float, float]]]:
    if not turns or any(not math.isfinite(t.start) or not math.isfinite(t.end) or t.end <= t.start for t in turns):
        raise ProviderError("text-only transcription needs valid local speaker turns", kind="diarization")
    turns = [Turn(max(0.0, t.start), min(duration, t.end), t.speaker) for t in turns if t.end > 0 and t.start < duration]
    if not turns:
        raise ProviderError("local diarization found no turns in the speech audio", kind="diarization")
    edges = sorted({0.0, duration, *(t.start for t in turns), *(t.end for t in turns)})
    windows, overlaps = [], []
    for start, end in zip(edges, edges[1:]):
        middle = (start + end) / 2
        active = [t for t in turns if t.start <= middle < t.end]
        if len({t.speaker for t in active}) > 1:
            overlaps.append((start, end))
        chosen = max(active, key=lambda t: t.start) if active else min(
            turns, key=lambda t: min(abs(middle - t.start), abs(middle - t.end)))
        if windows and windows[-1].speaker == chosen.speaker:
            windows[-1] = Turn(windows[-1].start, end, chosen.speaker)
        else:
            windows.append(Turn(start, end, chosen.speaker))
    return windows, overlaps


def transcribe_windows(provider, audio, request: SttRequest, turns: list[Turn], cache_path: Path) -> dict:
    windows, overlaps = speaker_windows(turns, audio.duration)
    utterances, channels = [], []
    for index, window in enumerate(windows):
        first, last = round(window.start * SR), round(window.end * SR)
        start, end = first / SR, last / SR
        if last <= first:
            continue
        blocks = [(max(a, start) - start, min(b, end) - start) for a, b in request.blocks if b > start and a < end]
        part = SttRequest(_flac(audio.pcm[first:last]), end - start, blocks, request.language, request.keyterms)
        limit = getattr(provider, "max_seconds", 0.0)
        parts = split_request(part, limit) if limit and part.duration > limit else [(0.0, part)]
        for offset, piece in parts:
            sent, pcm = _padded(piece)
            path = _cache_path(cache_path, provider, sent, pcm)
            if path.exists():
                response = json.loads(path.read_text())
            else:
                response = provider.transcribe(sent)
                atomic_write_bytes(path, json.dumps(response).encode())
            channels = channels or response["results"].get("channels", [])
            real = piece.duration  # times beyond it would come from the padding
            for utt in response["results"]["utterances"]:
                a = min(max(0.0, float(utt["start"])), real)
                b = min(max(a, float(utt["end"])), real)
                utterances.append(dict(utt, start=start + offset + a, end=start + offset + b, speaker=window.speaker))
    return {"results": {"channels": channels, "utterances": utterances},
            "omi_notes": {"timing_source": "local_speaker_windows", "overlap_spans": overlaps}}
