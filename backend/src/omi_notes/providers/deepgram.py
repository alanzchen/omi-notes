"""Deepgram pre-recorded (batch) transcription over plain httpx (no SDK churn).

Parameters follow Omi's `backend/utils/stt/pre_recorded.py`: smart_format, punctuate, diarize,
utterances, explicit language, and `keyterm` (nova-3's replacement for `keywords`).
"""

from __future__ import annotations

import httpx

from . import ProviderError, SttRequest

URL = "https://api.deepgram.com/v1/listen"


class DeepgramStt:
    name = "deepgram"

    def __init__(self, api_key: str, model: str = "nova-3", *, timeout: float = 600.0, transport=None) -> None:
        if not api_key:
            raise ProviderError("DEEPGRAM_API_KEY is not set", terminal=True, kind="config")
        self.api_key = api_key
        self.model = model
        self._client = httpx.Client(timeout=httpx.Timeout(timeout, connect=15.0), transport=transport)

    def params(self, request: SttRequest) -> list[tuple[str, str]]:
        params = [
            ("model", self.model),
            ("smart_format", "true"),
            ("punctuate", "true"),
            ("diarize", "true"),
            ("utterances", "true"),
        ]
        if request.language and request.language != "multi":
            params.append(("language", request.language))
        else:
            params.append(("detect_language", "true"))
        params.extend(("keyterm", term) for term in request.keyterms)
        return params

    def transcribe(self, request: SttRequest) -> dict:
        try:
            response = self._client.post(
                URL,
                params=self.params(request),
                content=request.flac,
                headers={"Authorization": f"Token {self.api_key}", "Content-Type": "audio/flac"},
            )
        except httpx.HTTPError as exc:
            raise ProviderError(f"Deepgram request failed: {exc}", kind="network") from exc
        status = response.status_code
        if status in (401, 402, 403):
            kind = "billing" if status == 402 else "auth"
            raise ProviderError(f"Deepgram HTTP {status}: {response.text[:300]}", terminal=True, kind=kind)
        if status == 429 or status >= 500 or status == 408:
            raise ProviderError(f"Deepgram HTTP {status}: {response.text[:300]}", kind="transient")
        if status >= 400:
            raise ProviderError(f"Deepgram HTTP {status}: {response.text[:300]}", terminal=True, kind="request")
        try:
            data = response.json()
        except ValueError as exc:
            raise ProviderError("Deepgram returned invalid JSON", kind="transient") from exc
        if not isinstance(data, dict) or "results" not in data:
            raise ProviderError("Deepgram response has no results", kind="transient")
        return data
