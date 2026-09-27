"""OpenAI-compatible chat completions (`POST {base}/chat/completions`) for the notes call.

Works with OpenAI and with servers that speak the same API: Ollama, llama.cpp, LM Studio, vLLM,
OpenRouter, etc. One request per conversation, asking for the notes JSON schema via
`response_format: json_schema` (strict). Servers that don't support schemas get a downgrade, once,
remembered for the process: `json_object` with the schema in the system prompt, then plain
instructions. The lenient `ConversationNotes` parser validates whatever comes back either way.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Literal

import httpx

from . import LlmRequest, LlmResult, ProviderError

log = logging.getLogger(__name__)

JsonMode = Literal["auto", "json_schema", "json_object", "prompt"]
_DOWNGRADE = {"json_schema": "json_object", "json_object": "prompt"}
_FENCE = re.compile(r"^\s*```(?:json)?\s*(.*?)\s*```\s*$", re.DOTALL)


class OpenAICompatLlm:
    name = "openai"

    def __init__(
        self,
        base_url: str,
        api_key: str,
        model: str,
        *,
        json_mode: JsonMode = "auto",
        reasoning_effort: str = "",
        timeout: float = 600.0,
        client: httpx.Client | None = None,
    ) -> None:
        self.url = base_url.rstrip("/") + "/chat/completions"
        self.api_key = api_key
        self.model = model
        self.reasoning_effort = reasoning_effort
        # "auto" starts with the strongest mode and downgrades on a rejection.
        self._mode: str = "json_schema" if json_mode == "auto" else json_mode
        self._auto = json_mode == "auto"
        self._client = client or httpx.Client(timeout=timeout)

    def summarize(self, request: LlmRequest) -> LlmResult:
        while True:
            response = self._post(self._body(request, self._mode))
            if response.status_code == 400 and self._auto and self._mode in _DOWNGRADE and _mentions_format(response):
                log.warning(
                    "%s rejected response_format=%s (%s); using %s from now on",
                    self.url, self._mode, response.text[:200], _DOWNGRADE[self._mode],
                )
                self._mode = _DOWNGRADE[self._mode]
                continue
            return self._parse(response)

    def _body(self, request: LlmRequest, mode: str) -> dict:
        system = request.system
        if mode != "json_schema":
            # Without schema enforcement the model only has the prompt to go on.
            system += (
                "\n\nRespond with a single JSON object and nothing else (no prose, no code fences). "
                "It must match this JSON Schema:\n" + json.dumps(request.schema, separators=(",", ":"))
            )
        body: dict = {
            "model": self.model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": request.user}],
        }
        if mode == "json_schema":
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": {"name": "conversation_notes", "schema": request.schema, "strict": True},
            }
        elif mode == "json_object":
            body["response_format"] = {"type": "json_object"}
        if self.reasoning_effort:
            body["reasoning_effort"] = self.reasoning_effort
        return body

    def _post(self, body: dict) -> httpx.Response:
        headers = {"Content-Type": "application/json"}
        if self.api_key:  # local servers usually need none
            headers["Authorization"] = f"Bearer {self.api_key}"
        try:
            return self._client.post(self.url, json=body, headers=headers)
        except httpx.HTTPError as exc:
            raise ProviderError(f"LLM request to {self.url} failed: {exc}", kind="network") from exc

    def _parse(self, response: httpx.Response) -> LlmResult:
        status = response.status_code
        detail = response.text[:300]
        if status in (401, 403):
            raise ProviderError(f"LLM auth error (HTTP {status}): {detail}", terminal=True, kind="auth")
        if status == 402:
            raise ProviderError(f"LLM billing error: {detail}", terminal=True, kind="billing")
        if status in (408, 409, 429) or status >= 500:
            raise ProviderError(f"LLM HTTP {status}: {detail}", kind="transient")
        if status >= 400:
            raise ProviderError(f"LLM rejected the request (HTTP {status}): {detail}", terminal=True, kind="request")
        try:
            data = response.json()
            choice = data["choices"][0]
            message = choice["message"]
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            raise ProviderError("LLM response is not a chat completion", kind="transient") from exc
        if message.get("refusal"):
            raise ProviderError(f"model declined to summarize: {message['refusal']}", terminal=True, kind="refusal")
        if choice.get("finish_reason") == "length":
            raise ProviderError("response hit the token limit before the JSON was complete", kind="transient")
        text = message.get("content") or ""
        if isinstance(text, list):  # some servers return content parts
            text = "".join(part.get("text", "") for part in text if isinstance(part, dict))
        if fenced := _FENCE.match(text):
            text = fenced.group(1)
        try:
            notes = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ProviderError(f"model returned invalid JSON: {exc}", kind="transient") from exc
        if not isinstance(notes, dict):
            raise ProviderError("model returned a non-object JSON value", kind="transient")
        usage = data.get("usage") or {}
        cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
        return LlmResult(
            data=notes,
            model=data.get("model") or self.model,
            usage={
                "input_tokens": usage.get("prompt_tokens", 0),
                "output_tokens": usage.get("completion_tokens", 0),
                "cache_read_input_tokens": cached,
                "cache_creation_input_tokens": 0,
            },
        )


def _mentions_format(response: httpx.Response) -> bool:
    """A 400 about response_format / JSON schema support (vs. any other bad request)."""
    text = response.text.lower()
    return any(word in text for word in ("response_format", "json_schema", "json schema", "json_object", "structured"))
