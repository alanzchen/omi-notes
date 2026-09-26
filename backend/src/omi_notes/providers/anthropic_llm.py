"""Anthropic structured-output notes call (anthropic SDK 1.x).

One request per conversation: the static system prompt first with `cache_control` (so repeated
calls read it from the prompt cache), the per-conversation context in the user message,
`output_config={"effort", "format": json_schema}`, and server-side refusal fallbacks
(`fallbacks="default"`, beta `server-side-fallback-2026-07-01`). If the API rejects the request
with fallbacks, it is retried once without them. `stop_reason` is checked before reading content.
"""

from __future__ import annotations

import json
import logging

import anthropic

from . import LlmRequest, LlmResult, ProviderError

log = logging.getLogger(__name__)

FALLBACK_BETA = "server-side-fallback-2026-07-01"


class AnthropicLlm:
    name = "anthropic"

    def __init__(
        self,
        api_key: str,
        model: str = "claude-opus-5",
        effort: str = "medium",
        *,
        max_tokens: int = 16000,
        client: anthropic.Anthropic | None = None,
    ) -> None:
        self.model = model
        self.effort = effort
        self.max_tokens = max_tokens
        # An empty key lets the SDK resolve other credentials (ANTHROPIC_AUTH_TOKEN, `ant auth login`).
        self.client = client or anthropic.Anthropic(api_key=api_key or None, max_retries=2, timeout=600.0)

    def summarize(self, request: LlmRequest) -> LlmResult:
        params = {
            "model": self.model,
            "max_tokens": self.max_tokens,
            "system": [{"type": "text", "text": request.system, "cache_control": {"type": "ephemeral"}}],
            "messages": [{"role": "user", "content": request.user}],
            "output_config": {"effort": self.effort, "format": {"type": "json_schema", "schema": request.schema}},
        }
        try:
            response = self._create(params)
        except (anthropic.AuthenticationError, anthropic.PermissionDeniedError) as exc:
            raise ProviderError(f"Anthropic auth error: {exc.message}", terminal=True, kind="auth") from exc
        except anthropic.NotFoundError as exc:
            raise ProviderError(f"Anthropic model/endpoint not found: {exc.message}", terminal=True, kind="request") from exc
        except anthropic.BadRequestError as exc:
            raise ProviderError(f"Anthropic rejected the request: {exc.message}", terminal=True, kind="request") from exc
        except anthropic.RateLimitError as exc:
            raise ProviderError(f"Anthropic rate limit: {exc.message}", kind="transient") from exc
        except anthropic.APIStatusError as exc:
            if exc.status_code == 402:
                raise ProviderError(f"Anthropic billing error: {exc.message}", terminal=True, kind="billing") from exc
            if exc.status_code >= 500 or exc.status_code in (408, 409):
                raise ProviderError(f"Anthropic HTTP {exc.status_code}: {exc.message}", kind="transient") from exc
            raise ProviderError(f"Anthropic HTTP {exc.status_code}: {exc.message}", terminal=True, kind="request") from exc
        except anthropic.APIConnectionError as exc:  # includes APITimeoutError
            raise ProviderError(f"Anthropic connection error: {exc}", kind="network") from exc

        if response.stop_reason == "refusal":
            details = getattr(response, "stop_details", None)
            category = getattr(details, "category", None) if details else None
            raise ProviderError(f"model declined to summarize (category: {category})", terminal=True, kind="refusal")
        if response.stop_reason == "max_tokens":
            raise ProviderError("response hit max_tokens before the JSON was complete", kind="transient")
        text = "".join(block.text for block in response.content if block.type == "text")
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ProviderError(f"model returned invalid JSON: {exc}", kind="transient") from exc
        if not isinstance(data, dict):
            raise ProviderError("model returned a non-object JSON value", kind="transient")

        usage = response.usage
        iterations = getattr(usage, "iterations", None) or []
        return LlmResult(
            data=data,
            model=response.model,
            usage={
                "input_tokens": usage.input_tokens,
                "output_tokens": usage.output_tokens,
                "cache_read_input_tokens": getattr(usage, "cache_read_input_tokens", None) or 0,
                "cache_creation_input_tokens": getattr(usage, "cache_creation_input_tokens", None) or 0,
            },
            fallback_used=any(getattr(entry, "type", None) == "fallback_message" for entry in iterations),
        )

    def _create(self, params: dict):
        try:
            return self.client.beta.messages.create(**params, betas=[FALLBACK_BETA], fallbacks="default")
        except anthropic.BadRequestError as exc:
            log.warning("request with server-side fallbacks was rejected (%s); retrying once without", exc.message)
        return self.client.beta.messages.create(**params)
