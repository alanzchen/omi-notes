"""OpenAI-compatible transcription (`POST {base}/audio/transcriptions`, multipart) with diarization.

One client for OpenAI and the servers that copied its API. They differ in how speaker labels are
requested and returned, so requests come in five *styles* (auto-detected from the host and model,
overridable with `STT_REQUEST_STYLE`):

- `openai_diarized`: diarizing models (`gpt-4o-transcribe-diarize`, vLLM MOSS-Transcribe-Diarize):
  `response_format=diarized_json`; `chunking_strategy=auto` on api.openai.com (it errors without it
  for audio over 30 s); no `prompt` (unsupported).
- `mistral`: Voxtral: `diarize=true`, keyterms as `context_bias[]` (at most 100); `language` but no
  `timestamp_granularities` (the two are mutually exclusive).
- `together`: `response_format=verbose_json`, `diarize=true`; speakers in `speaker_segments[]`.
- `verbose`: generic whisper-style servers (LocalAI, whisper.cpp server, speaches, mlx-audio, Groq):
  `verbose_json` with word + segment timestamps, `diarize=true` (ignored where unknown), keyterms
  as `prompt`.
- `json`: text-only models such as `gpt-transcribe`. Local diarization partitions audio before
  STT; requests return `json`, with coarse window times and stable local labels in the pipeline.

Every response shape is normalized into the Deepgram-shaped dict the pipeline reads
(`results.utterances[]` with integer `speaker`, or None when the server gave no labels). Audio
longer than the style's per-request limit (or rejected with 413) is split at speech-block
boundaries, transcribed piece by piece and merged; labels restart in every piece, so they are
namespaced per piece and the result records how many pieces there were.
"""

from __future__ import annotations

import io
import logging
import re
from typing import Literal
from urllib.parse import urlparse

import httpx
import numpy as np
import soundfile as sf

from ..pipeline.prompt import LANGUAGE_NAMES
from . import ProviderError, SttRequest

log = logging.getLogger(__name__)

Style = Literal["openai_diarized", "mistral", "together", "verbose", "json"]
SAMPLE_RATE = 16000
MAX_CONTEXT_BIAS = 100
# Known per-request limits (seconds). OpenAI's diarize model tops out around 1400 s (community
# reports); 1200 s also keeps 16 kHz FLAC under its 25 MB upload cap. Together's upload cap is 80 MB.
_LIMITS = {("openai_diarized", "api.openai.com"): 1200.0, ("together", None): 3600.0}
_SPEAKER_PREFIX = re.compile(r"^\s*\[((?:S|SPEAKER_?|speaker_?)\d+|[A-Z])\]\s*")
_LANGUAGE_CODES = {name.lower(): code for code, name in LANGUAGE_NAMES.items()}


def _host(base_url: str) -> str:
    return (urlparse(base_url).hostname or "").lower()


def resolve_style(base_url: str, model: str, configured: str = "auto") -> Style:
    if configured != "auto":
        return configured  # type: ignore[return-value]
    host, name = _host(base_url), model.lower()
    if "diarize" in name:
        return "openai_diarized"
    if name == "gpt-transcribe":
        return "json"
    if host.endswith("mistral.ai") or name.rsplit("/", 1)[-1].startswith("voxtral"):
        return "mistral"
    if host.endswith("together.xyz") or host.endswith("together.ai"):
        return "together"
    return "verbose"


def default_max_seconds(style: str, base_url: str) -> float:
    if style == "json":
        return 30.0
    host = _host(base_url)
    return _LIMITS.get((style, host), _LIMITS.get((style, None), 0.0))


class _TooLarge(Exception):
    pass


class OpenAICompatStt:
    name = "openai"

    def __init__(
        self,
        base_url: str,
        api_key: str,
        model: str,
        *,
        style: str = "auto",
        max_request_seconds: float | None = None,
        timeout: float = 900.0,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.url = self.base_url + "/audio/transcriptions"
        self.api_key = api_key
        self.model = model
        self._auto = style == "auto"
        self.style: Style = resolve_style(base_url, model, style)
        self.max_seconds = default_max_seconds(self.style, base_url) if max_request_seconds is None else max_request_seconds
        self._context_bias = True
        self._client = httpx.Client(timeout=httpx.Timeout(timeout, connect=15.0), transport=transport)

    @property
    def cache_tag(self) -> str:
        """Part of the STT cache key: a different request style is a different transcription."""
        return f"json-turns-v1-{self.max_seconds:g}" if self.style == "json" else self.style

    @property
    def needs_speaker_windows(self) -> bool:
        return self.style == "json"

    def transcribe(self, request: SttRequest) -> dict:
        if self.max_seconds and request.duration > self.max_seconds:
            parts = split_request(request, self.max_seconds)
        else:
            parts = [(0.0, request)]
        results: list[tuple[float, dict]] = []
        for offset, part in parts:
            results.extend(self._transcribe_part(offset, part))
        return merge_pieces(results)

    def _transcribe_part(self, offset: float, part: SttRequest) -> list[tuple[float, dict]]:
        try:
            data = self._post(part)
            if self.style == "json":
                if not isinstance(data.get("text"), str):
                    raise ProviderError("JSON transcription response is missing text", kind="response")
                # This response has no word timing; the pipeline sends one local speaker window.
                data = {"text": data["text"], "duration": part.duration,
                        "languages": data.get("languages"), "language": data.get("language")}
            return [(offset, normalize_response(data))]
        except _TooLarge:
            if len(part.blocks) < 2:
                raise ProviderError(
                    f"transcription server rejected {part.duration:.0f} s of audio as too large (HTTP 413) and it "
                    "cannot be split further; set STT_MAX_REQUEST_SECONDS lower or raise the server's upload limit",
                    terminal=True, kind="request",
                ) from None
            log.warning("HTTP 413 for %.0f s of audio: splitting it in two", part.duration)
            out: list[tuple[float, dict]] = []
            for sub_offset, sub in halve_request(part):
                out.extend(self._transcribe_part(offset + sub_offset, sub))
            return out

    def fields(self, request: SttRequest) -> dict[str, str | list[str]]:
        fields: dict[str, str | list[str]] = {"model": self.model}
        language = request.language if request.language and request.language != "multi" else None
        if self.style == "json":
            fields["response_format"] = "json"
            if self.model == "gpt-transcribe":
                if language:
                    fields["languages[]"] = [language]
                if request.keyterms:
                    fields["keywords[]"] = request.keyterms
                language = None
            elif request.keyterms:
                fields["prompt"] = ", ".join(request.keyterms)
        elif self.style == "openai_diarized":
            fields["response_format"] = "diarized_json"
            if _host(self.base_url) == "api.openai.com":
                fields["chunking_strategy"] = "auto"
        elif self.style == "mistral":
            fields["diarize"] = "true"
            if self._context_bias and request.keyterms:
                fields["context_bias[]"] = request.keyterms[:MAX_CONTEXT_BIAS]
        elif self.style == "together":
            fields["response_format"] = "verbose_json"
            fields["diarize"] = "true"
        else:
            fields["response_format"] = "verbose_json"
            fields["timestamp_granularities[]"] = ["word", "segment"]
            fields["diarize"] = "true"
        if language:
            fields["language"] = language
        if self.style == "verbose" and request.keyterms:
            fields["prompt"] = ", ".join(request.keyterms)
        return fields

    def _post(self, request: SttRequest) -> dict:
        while True:
            headers = {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {}
            try:
                response = self._client.post(
                    self.url, data=self.fields(request), files={"file": ("audio.flac", request.flac, "audio/flac")},
                    headers=headers,
                )  # fmt: skip
            except httpx.HTTPError as exc:
                raise ProviderError(f"transcription request to {self.url} failed: {exc}", kind="network") from exc
            status, detail = response.status_code, response.text[:300]
            lowered = detail.lower()
            if status in (400, 422) and self.style == "mistral" and self._context_bias and "context_bias" in lowered:
                log.warning("%s rejected context_bias (%s); sending keyterms no more", self.url, detail)
                self._context_bias = False
                continue
            if status in (400, 422) and self._auto and self.style == "openai_diarized" and "response_format" in lowered:
                log.warning("%s does not know diarized_json (%s); using verbose_json from now on", self.url, detail)
                self.style = "verbose"
                continue
            break
        if status == 413:
            raise _TooLarge
        if status in (401, 403):
            raise ProviderError(f"transcription auth error (HTTP {status}): {detail}", terminal=True, kind="auth")
        if status == 402:
            raise ProviderError(f"transcription billing error: {detail}", terminal=True, kind="billing")
        if status in (408, 409, 429) or status >= 500:
            raise ProviderError(f"transcription HTTP {status}: {detail}", kind="transient")
        if status >= 400:
            raise ProviderError(f"transcription rejected the request (HTTP {status}): {detail}", terminal=True, kind="request")
        try:
            data = response.json()
        except ValueError as exc:
            raise ProviderError(f"transcription server returned no JSON: {detail}", kind="transient") from exc
        if not isinstance(data, dict):
            raise ProviderError("transcription response is not a JSON object", kind="transient")
        return data


# -- response normalization ------------------------------------------------------------------------


def _label(value: object) -> str | None:
    return None if value is None or value == "" else str(value)


def _words(raw: object, speaker_of) -> list[dict]:
    words = []
    for w in raw if isinstance(raw, list) else []:
        if not isinstance(w, dict) or w.get("start") is None or w.get("end") is None:
            continue
        text = str(w.get("word") or w.get("text") or "").strip()
        if not text:
            continue
        word = {"word": text, "punctuated_word": text, "start": float(w["start"]), "end": float(w["end"])}
        speaker = speaker_of(_label(w.get("speaker_id", w.get("speaker"))))
        if speaker is not None:
            word["speaker"] = speaker
        words.append(word)
    return words


def normalize_response(data: dict) -> dict:
    """Any known transcription response → Deepgram-shaped `results.utterances[]`.

    Speaker labels (`segments[].speaker` from OpenAI/vLLM/LocalAI, `segments[].speaker_id` from
    Mistral/mlx-audio, `speaker_segments[]` from Together, or a leading `[S01]` in the text) become
    integers by first appearance; `speaker` stays None when the server gave no labels.
    """
    labels: dict[str, int] = {}

    def speaker_of(label: str | None) -> int | None:
        if label is None:
            return None
        return labels.setdefault(label, len(labels))

    segments = data.get("speaker_segments") or data.get("segments") or []
    top_words = _words(data.get("words"), lambda _: None)
    used = [False] * len(top_words)
    utterances: list[dict] = []
    for seg in segments if isinstance(segments, list) else []:
        if not isinstance(seg, dict):
            continue
        text = str(seg.get("text") or "").strip()
        label = _label(seg.get("speaker")) or _label(seg.get("speaker_id"))
        if prefix := _SPEAKER_PREFIX.match(text):
            text = text[prefix.end() :].strip()
            label = label or prefix.group(1)
        if not text:
            continue
        start, end = float(seg.get("start") or 0.0), float(seg.get("end") or 0.0)
        words = _words(seg.get("words"), speaker_of)
        if not words and top_words:  # verbose_json keeps words at the top level
            for i, w in enumerate(top_words):
                if not used[i] and start <= (w["start"] + w["end"]) / 2 <= end:
                    words.append(w)
                    used[i] = True
        utterance = {"start": start, "end": max(start, end), "transcript": text, "speaker": speaker_of(label)}
        if words:
            utterance["words"] = words
        if seg.get("confidence") is not None:
            utterance["confidence"] = float(seg["confidence"])
        utterances.append(utterance)
    if not utterances and str(data.get("text") or "").strip():
        end = float(data.get("duration") or (top_words[-1]["end"] if top_words else 0.0))
        utterances.append({"start": 0.0, "end": end, "transcript": str(data["text"]).strip(), "speaker": None})
    channel: dict = {}
    language = data.get("language")
    if not language and isinstance(data.get("languages"), list) and data["languages"]:
        first = data["languages"][0]
        language = first.get("code") if isinstance(first, dict) else None
    if isinstance(language, str) and language.strip():
        channel["detected_language"] = _LANGUAGE_CODES.get(language.strip().lower(), language.strip())
    return {"results": {"channels": [channel], "utterances": utterances}}


def merge_pieces(results: list[tuple[float, dict]]) -> dict:
    """Shift each piece's times by its offset; namespace its speaker labels (they restart per piece)."""
    if len(results) == 1 and results[0][0] == 0.0:
        return results[0][1]
    utterances: list[dict] = []
    language = None
    base = 0
    for offset, result in results:
        pieces_max = -1
        for utt in result["results"]["utterances"]:
            shifted = dict(utt, start=utt["start"] + offset, end=utt["end"] + offset)
            if utt.get("speaker") is not None:
                shifted["speaker"] = utt["speaker"] + base
                pieces_max = max(pieces_max, utt["speaker"])
            if utt.get("words"):
                shifted["words"] = [
                    dict(w, start=w["start"] + offset, end=w["end"] + offset)
                    | ({"speaker": w["speaker"] + base} if w.get("speaker") is not None else {})
                    for w in utt["words"]
                ]
            utterances.append(shifted)
        base += pieces_max + 1
        channel = result["results"]["channels"][0] if result["results"]["channels"] else {}
        language = language or channel.get("detected_language")
    return {
        "results": {"channels": [{"detected_language": language} if language else {}], "utterances": utterances},
        "omi_notes": {"pieces": len(results), "offsets": [round(o, 3) for o, _ in results]},
    }


# -- splitting -------------------------------------------------------------------------------------


def _flac(pcm: np.ndarray) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, pcm, SAMPLE_RATE, format="FLAC", subtype="PCM_16")
    return buf.getvalue()


def _quietest(pcm: np.ndarray, lo: float, hi: float) -> float:
    """Start of the quietest 50 ms window in [lo, hi] (a cut inside speech, only when unavoidable)."""
    window = SAMPLE_RATE // 20
    a, b = int(lo * SAMPLE_RATE), int(hi * SAMPLE_RATE)
    segment = pcm[a:b].astype(np.float64)
    if len(segment) < window:
        return hi
    n = len(segment) // window
    energy = (segment[: n * window].reshape(n, window) ** 2).mean(axis=1)
    return (a + int(np.argmin(energy)) * window) / SAMPLE_RATE


def _pieces(request: SttRequest, pcm: np.ndarray, cuts: list[float]) -> list[tuple[float, SttRequest]]:
    duration = len(pcm) / SAMPLE_RATE
    edges = [0.0, *cuts, duration]
    out = []
    for start, end in zip(edges, edges[1:], strict=False):
        piece = pcm[round(start * SAMPLE_RATE) : round(end * SAMPLE_RATE)]
        blocks = [(max(a, start) - start, min(b, end) - start) for a, b in request.blocks if b > start and a < end]
        out.append((start, SttRequest(flac=_flac(piece), duration=len(piece) / SAMPLE_RATE, blocks=blocks,
                                      language=request.language, keyterms=request.keyterms)))  # fmt: skip
    return out


def split_request(request: SttRequest, max_seconds: float) -> list[tuple[float, SttRequest]]:
    """Pieces of at most `max_seconds`, cut in the middle of the silent spacers between speech
    blocks. Only a single block longer than the limit is cut inside, at its quietest moment."""
    pcm, _ = sf.read(io.BytesIO(request.flac), dtype="int16")
    duration = len(pcm) / SAMPLE_RATE
    if duration <= max_seconds:
        return [(0.0, request)]
    blocks = sorted(request.blocks) or [(0.0, duration)]
    cuts: list[float] = []
    start = 0.0
    for i, (a, b) in enumerate(blocks):
        if b - start <= max_seconds:
            continue
        spacer = (blocks[i - 1][1] + a) / 2 if i else None
        if spacer is not None and spacer > start:
            cuts.append(spacer)
            start = spacer
        while b - start > max_seconds:
            cut = _quietest(pcm, start + 0.9 * max_seconds, start + max_seconds)
            cuts.append(cut)
            start = cut
    if duration - start > max_seconds:  # trailing silence after the last block
        cuts.append(start + max_seconds)
    return _pieces(request, pcm, cuts)


def halve_request(request: SttRequest) -> list[tuple[float, SttRequest]]:
    """Two pieces, cut in the spacer closest to the middle (used after HTTP 413)."""
    pcm, _ = sf.read(io.BytesIO(request.flac), dtype="int16")
    blocks = sorted(request.blocks)
    spacers = [(x[1] + y[0]) / 2 for x, y in zip(blocks, blocks[1:], strict=False)]
    middle = len(pcm) / SAMPLE_RATE / 2
    return _pieces(request, pcm, [min(spacers, key=lambda c: abs(c - middle))])
