"""Speech-block audio for STT, the piecewise time map back to wall clock, and transcript segments.

Only VAD speech blocks are sent to the STT provider, concatenated with 0.5 s silent spacers. A
piecewise time map (Omi's `WallTimeMapper` idea in `backend/utils/stt/vad_gate.py`) converts
provider timestamps back to wall-clock epochs so silence removal never compresses the times shown
in notes. Same-speaker utterances are then merged (gap < 3 s, result < 60 s; cf. Omi
`backend/models/transcript_segment.py`).
"""

from __future__ import annotations

import bisect
import io
from dataclasses import dataclass

import numpy as np
import soundfile as sf

from ..audio.timeline import SAMPLE_RATE, Piece
from .segmenter import Interval, subtract, union

SPACER_SECONDS = 0.5
MERGE_MAX_GAP = 3.0
MERGE_MAX_DURATION = 60.0


@dataclass(frozen=True)
class MapSegment:
    out_start: float
    wall_start: float
    duration: float

    @property
    def out_end(self) -> float:
        return self.out_start + self.duration


@dataclass
class ConversationAudio:
    pcm: np.ndarray
    timemap: list[MapSegment]
    blocks_out: list[Interval]  # each speech block's span in submitted-audio seconds
    missing: list[Interval]  # wall-clock parts of speech blocks with no decoded audio

    @property
    def duration(self) -> float:
        return len(self.pcm) / SAMPLE_RATE

    def flac(self) -> bytes:
        buf = io.BytesIO()
        sf.write(buf, self.pcm, SAMPLE_RATE, format="FLAC", subtype="PCM_16")
        return buf.getvalue()


def assemble(blocks: list[Interval], sources: list[tuple[int, Piece]]) -> ConversationAudio:
    """Cut `blocks` (wall-clock) out of decoded pieces. Lower priority numbers win where pieces
    overlap in time (live audio over ring audio, should both exist)."""
    segments: list[tuple[float, float, Piece]] = []
    covered: list[Interval] = []
    for _, piece in sorted(sources, key=lambda item: (item[0], item[1].start)):
        for a, b in subtract([(piece.start, piece.end)], covered):
            segments.append((a, b, piece))
        covered = union(covered + [(piece.start, piece.end)])
    segments.sort(key=lambda s: s[0])

    out: list[np.ndarray] = []
    timemap: list[MapSegment] = []
    blocks_out: list[Interval] = []
    missing: list[Interval] = []
    t_out = 0
    for index, (ba, bb) in enumerate(blocks):
        if index:
            out.append(np.zeros(int(SPACER_SECONDS * SAMPLE_RATE), dtype=np.int16))
            t_out += int(SPACER_SECONDS * SAMPLE_RATE)
        block_start = t_out
        got: list[Interval] = []
        for a, b, piece in segments:
            lo, hi = max(a, ba), min(b, bb)
            if hi <= lo:
                continue
            i0 = max(0, round((lo - piece.start) * SAMPLE_RATE))
            i1 = min(len(piece.pcm), round((hi - piece.start) * SAMPLE_RATE))
            if i1 <= i0:
                continue
            samples = piece.pcm[i0:i1]
            timemap.append(MapSegment(t_out / SAMPLE_RATE, piece.start + i0 / SAMPLE_RATE, len(samples) / SAMPLE_RATE))
            out.append(samples)
            t_out += len(samples)
            got.append((lo, hi))
        blocks_out.append((block_start / SAMPLE_RATE, t_out / SAMPLE_RATE))
        missing.extend(subtract([(ba, bb)], got))
    pcm = np.concatenate(out).astype(np.int16) if out else np.zeros(0, dtype=np.int16)
    return ConversationAudio(pcm=pcm, timemap=timemap, blocks_out=blocks_out, missing=[m for m in missing if m[1] - m[0] > 0.05])


def map_time(timemap: list[MapSegment], t: float) -> float:
    """Submitted-audio seconds → wall-clock epoch. Times in spacers clamp to the nearest edge."""
    if not timemap:
        return t
    starts = [m.out_start for m in timemap]
    i = bisect.bisect_right(starts, t) - 1
    if i < 0:
        return timemap[0].wall_start
    seg = timemap[i]
    if t <= seg.out_end:
        return seg.wall_start + (t - seg.out_start)
    if i + 1 < len(timemap) and t - seg.out_end > timemap[i + 1].out_start - t:
        return timemap[i + 1].wall_start
    return seg.wall_start + seg.duration


def segments_from_deepgram(response: dict, timemap: list[MapSegment]) -> list[dict]:
    """`results.utterances[]` → wall-clock segments with speakers relabelled S1, S2… by first appearance."""
    results = response.get("results") or {}
    utterances = results.get("utterances")
    if utterances is None:
        utterances = _utterances_from_words(results)
    labels: dict[object, str] = {}
    segments: list[dict] = []
    for utt in sorted(utterances, key=lambda u: float(u.get("start", 0))):
        text = str(utt.get("transcript", "")).strip()
        if not text:
            continue
        speaker = utt.get("speaker", 0)
        if speaker not in labels:
            labels[speaker] = f"S{len(labels) + 1}"
        start = map_time(timemap, float(utt.get("start", 0)))
        end = max(start, map_time(timemap, float(utt.get("end", 0))))
        segments.append(
            {
                "start": round(start, 3),
                "end": round(end, 3),
                "speaker": labels[speaker],
                "text": text,
                "confidence": round(float(utt.get("confidence", 0) or 0), 4),
            }
        )
    return segments


def detected_language(response: dict) -> str | None:
    """Deepgram's `results.channels[0].detected_language` (present with language detection)."""
    try:
        language = response["results"]["channels"][0].get("detected_language")
    except (KeyError, IndexError, TypeError, AttributeError):
        return None
    return language if isinstance(language, str) and language else None


def _utterances_from_words(results: dict) -> list[dict]:
    """Fallback when `utterances` is absent: group consecutive words by speaker."""
    try:
        words = results["channels"][0]["alternatives"][0].get("words", [])
    except (KeyError, IndexError, TypeError):
        return []
    utterances: list[dict] = []
    for w in words:
        token = w.get("punctuated_word") or w.get("word", "")
        speaker = w.get("speaker", 0)
        if utterances and utterances[-1]["speaker"] == speaker and w.get("start", 0) - utterances[-1]["end"] < 1.0:
            utterances[-1]["transcript"] += " " + token
            utterances[-1]["end"] = w.get("end", utterances[-1]["end"])
        else:
            utterances.append({"start": w.get("start", 0), "end": w.get("end", 0), "speaker": speaker,
                               "transcript": token, "confidence": w.get("confidence", 0)})  # fmt: skip
    return utterances


def merge_same_speaker(segments: list[dict]) -> list[dict]:
    merged: list[dict] = []
    for seg in segments:
        if (
            merged
            and merged[-1]["speaker"] == seg["speaker"]
            and seg["start"] - merged[-1]["end"] < MERGE_MAX_GAP
            and seg["end"] - merged[-1]["start"] < MERGE_MAX_DURATION
        ):
            prev = merged[-1]
            prev["text"] = f"{prev['text']} {seg['text']}".strip()
            prev["end"] = max(prev["end"], seg["end"])
            prev["confidence"] = min(prev["confidence"], seg["confidence"])
        else:
            merged.append(dict(seg))
    return merged
