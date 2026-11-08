"""The local ASR sidecar (`sidecar/asr`, MOSS-Transcribe-Diarize lines + Qwen3-ASR text) as Omi's STT.

It speaks the `openai_diarized` shape: segments with real start/end and `speaker_id`. Differences from a
generic OpenAI-compatible server, all deliberate (asr-bench-20261108):
- pieces of up to 900 s split at pauses (the sidecar keeps MOSS within its context and re-splits a
  truncated window itself), never per-speaker 30 s windows;
- no `language` hint (mixed Mandarin/English) and no `prompt` (a MOSS prompt replaces its instruction);
  the keyterms go as `context`, which the sidecar gives Qwen as hotwords;
- its labels restart in every piece, and inside a piece in every window MOSS was re-split into (the
  answer's `windows`, label prefixes `W<k>.<n>-`): each such window becomes a piece of its own here, so
  the pipeline links them all with voiceprints (`pipeline.speaker_links`) and uses them as the
  provider's labels.
A 900 s piece takes about 80 s (RTF 0.09, plus ~10 s to load the models); the 20 min timeout leaves room
for MOSS re-splitting a truncated window without letting a hung sidecar hold the worker for an hour.
`healthy()` asks `/health` (cached 30 s; `refresh=True` asks again). The sidecar is the only engine:
while it is down, conversations wait for it (never another provider).
"""

from __future__ import annotations

import time

import httpx

from . import SttRequest
from .openai_stt import OpenAICompatStt, _TooLarge, normalize_response, pad_short


UNKNOWN = "UNKNOWN"  # the sidecar's label for words no MOSS line holds


def _normalized(data: dict) -> dict:
    """`normalize_response`, with the sidecar's UNKNOWN words marked `unattributed` (speaker None): kept and
    shown as an unknown speaker, never numbered, linked or used for a voiceprint."""
    segments = [dict(s, speaker_id=None) if s.get("speaker_id") == UNKNOWN else s for s in data.get("segments") or []]
    result = normalize_response(dict(data, segments=segments))
    for utterance in result["results"]["utterances"]:
        if utterance.get("speaker") is None:
            utterance["unattributed"] = True
    return result


class LocalAsrStt(OpenAICompatStt):
    name = "local-asr"
    links_speakers = True
    HEALTH_TTL = 30.0

    def __init__(self, base_url: str, model: str = "omi-asr", *, max_request_seconds: float = 900.0,
                 transport: httpx.BaseTransport | None = None, timeout: float = 1200.0) -> None:  # fmt: skip
        super().__init__(base_url, "", model, style="openai_diarized", max_request_seconds=max_request_seconds,
                         timeout=timeout, transport=transport)  # fmt: skip
        self._health: tuple[float, bool] | None = None
        self._health_client = httpx.Client(timeout=httpx.Timeout(2.0, connect=1.0), transport=transport)

    @property
    def cache_tag(self) -> str:
        return f"local-asr-v1-{self.max_seconds:g}"

    def fields(self, request: SttRequest) -> dict[str, str | list[str]]:
        fields: dict[str, str | list[str]] = {"model": self.model, "response_format": "diarized_json"}
        if request.keyterms:
            fields["context"] = ", ".join(request.keyterms)
        return fields

    def _transcribe_part(self, offset: float, part: SttRequest) -> list[tuple[float, dict]]:
        try:
            data = self._post(pad_short(part))
        except _TooLarge:  # the generic path halves it
            return super()._transcribe_part(offset, part)
        windows = sorted(data.get("windows") or [], key=lambda w: float(w["start"]))
        if len(windows) < 2:
            return [(offset, _normalized(data))]
        # each segment belongs to the window whose label prefix it carries (the first window's is empty)
        groups: dict[int, list[dict]] = {}
        for seg in data.get("segments") or []:
            label = str(seg.get("speaker_id") or "")
            k = next((i for i, w in enumerate(windows) if w.get("label_prefix") and label.startswith(w["label_prefix"])), 0)
            groups.setdefault(k, []).append(seg)
        out = []
        for k, segments in sorted(groups.items()):
            start = float(windows[k]["start"])
            shifted = [dict(seg, start=float(seg["start"]) - start, end=float(seg["end"]) - start) for seg in segments]
            out.append((offset + start, _normalized(dict(data, segments=shifted))))
        return out

    def healthy(self, *, refresh: bool = False) -> bool:
        now = time.monotonic()
        if not refresh and self._health and now - self._health[0] < self.HEALTH_TTL:
            return self._health[1]
        root = self.base_url[: -len("/v1")] if self.base_url.endswith("/v1") else self.base_url
        try:
            ok = self._health_client.get(root + "/health").status_code == 200
        except httpx.HTTPError:
            ok = False
        self._health = (now, ok)
        return ok
