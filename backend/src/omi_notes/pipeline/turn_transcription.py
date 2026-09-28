"""Text-only STT: local speaker windows supply timing, with one cached request per window.

Partition all submitted audio, including gaps at diarizer boundaries: no speech is dropped just
because the diarizer missed it. Times are window boundaries, not invented word timestamps.
Overlapping turns cannot be separated acoustically; keep their audio, but exclude it from voiceprints.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

from ..audio.diarize import Turn
from ..providers import ProviderError, SttRequest
from ..providers.openai_stt import _flac, split_request
from ..spool import atomic_write_bytes

SR = 16000


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
        for sub_index, (offset, piece) in enumerate(parts):
            path = cache_path.with_name(f"{cache_path.stem}-window-{index}-{sub_index}.json")
            if path.exists():
                response = json.loads(path.read_text())
            else:
                response = provider.transcribe(piece)
                atomic_write_bytes(path, json.dumps(response).encode())
            channels = channels or response["results"].get("channels", [])
            for utt in response["results"]["utterances"]:
                utterances.append(dict(utt, start=start + offset + utt["start"],
                                       end=start + offset + utt["end"], speaker=window.speaker))
    return {"results": {"channels": channels, "utterances": utterances},
            "omi_notes": {"timing_source": "local_speaker_windows", "overlap_spans": overlaps}}
