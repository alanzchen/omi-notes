"""The local ASR sidecar (`sidecar/asr`, MOSS-Transcribe-Diarize lines + Qwen3-ASR text) as Omi's STT.

It speaks the `openai_diarized` shape: segments with real start/end and `speaker_id`. Differences from a
generic OpenAI-compatible server, all deliberate (asr-bench-20261108):
- pieces of up to 900 s split at pauses (the sidecar keeps MOSS within its context and re-splits a
  truncated window itself), never per-speaker 30 s windows;
- no `language` hint (mixed Mandarin/English) and no `prompt` (a MOSS prompt replaces its instruction);
  the keyterms go as `context`, which the sidecar gives Qwen as hotwords;
- its labels restart in every piece: the pipeline links them across pieces with voiceprints
  (`pipeline.speaker_links`) and uses them as the provider's labels.
`healthy()` asks `/health` (cached 30 s): while the sidecar is down, the pipeline uses the configured
STT_* provider instead.
"""

from __future__ import annotations

import time

import httpx

from . import SttRequest
from .openai_stt import OpenAICompatStt


class LocalAsrStt(OpenAICompatStt):
    name = "local-asr"
    links_speakers = True
    HEALTH_TTL = 30.0

    def __init__(self, base_url: str, model: str = "omi-asr", *, max_request_seconds: float = 900.0,
                 transport: httpx.BaseTransport | None = None, timeout: float = 3600.0) -> None:  # fmt: skip
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

    def healthy(self) -> bool:
        now = time.monotonic()
        if self._health and now - self._health[0] < self.HEALTH_TTL:
            return self._health[1]
        root = self.base_url[: -len("/v1")] if self.base_url.endswith("/v1") else self.base_url
        try:
            ok = self._health_client.get(root + "/health").status_code == 200
        except httpx.HTTPError:
            ok = False
        self._health = (now, ok)
        return ok
