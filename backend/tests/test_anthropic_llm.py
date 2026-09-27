"""The Anthropic provider exercised through the real SDK with a mock HTTP transport."""

import json

import anthropic
import httpx2
import pytest

from omi_notes.notes.schema import NOTES_JSON_SCHEMA
from omi_notes.pipeline.prompt import SYSTEM_PROMPT
from omi_notes.providers import LlmRequest, ProviderError
from omi_notes.providers.anthropic_llm import FALLBACK_BETA, AnthropicLlm


def message(text: str, stop_reason: str = "end_turn", **extra) -> dict:
    return {
        "id": "msg_01", "type": "message", "role": "assistant", "model": "claude-opus-5",
        "content": [{"type": "text", "text": text}] if text else [], "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {"input_tokens": 1200, "output_tokens": 300, "cache_read_input_tokens": 900,
                  "cache_creation_input_tokens": 0},
    } | extra  # fmt: skip


def provider(handler) -> tuple[AnthropicLlm, list[httpx2.Request]]:
    seen: list[httpx2.Request] = []

    def record(request: httpx2.Request) -> httpx2.Response:
        seen.append(request)
        return handler(request, len(seen))

    client = anthropic.Anthropic(
        api_key="test-key", max_retries=0, http_client=anthropic.DefaultHttpxClient(transport=httpx2.MockTransport(record))
    )
    return AnthropicLlm("test-key", client=client), seen


REQUEST = LlmRequest(system=SYSTEM_PROMPT, user="FULL TRANSCRIPT\n[00:00 S1] hi", schema=NOTES_JSON_SCHEMA)


def test_request_shape_and_parsed_result():
    llm, seen = provider(lambda req, n: httpx2.Response(200, json=message(json.dumps({"title": "Hello", "keep": True}))))
    result = llm.summarize(REQUEST)
    assert result.data == {"title": "Hello", "keep": True}
    assert result.usage["cache_read_input_tokens"] == 900 and result.model == "claude-opus-5"
    (req,) = seen
    body = json.loads(req.content)
    assert FALLBACK_BETA in req.headers["anthropic-beta"]
    assert body["fallbacks"] == "default"
    assert body["model"] == "claude-opus-5"
    assert body["output_config"] == {"effort": "medium", "format": {"type": "json_schema", "schema": NOTES_JSON_SCHEMA}}
    assert body["system"] == [{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}]
    assert body["messages"] == [{"role": "user", "content": REQUEST.user}]
    assert "thinking" not in body and "temperature" not in body


def test_rejected_fallbacks_retry_once_without():
    def handler(req, n):
        if n == 1:
            return httpx2.Response(400, json={"type": "error", "error": {"type": "invalid_request_error", "message": "fallbacks: not allowed"}})
        return httpx2.Response(200, json=message('{"title": "Ok"}'))

    llm, seen = provider(handler)
    assert llm.summarize(REQUEST).data == {"title": "Ok"}
    assert len(seen) == 2
    second = json.loads(seen[1].content)
    assert "fallbacks" not in second and FALLBACK_BETA not in seen[1].headers.get("anthropic-beta", "")


def test_refusal_is_checked_before_content():
    llm, _ = provider(lambda req, n: httpx2.Response(200, json=message("", stop_reason="refusal",
                                                                         stop_details={"type": "refusal", "category": "cyber", "explanation": None})))  # fmt: skip
    with pytest.raises(ProviderError) as info:
        llm.summarize(REQUEST)
    assert info.value.terminal and info.value.kind == "refusal" and "cyber" in str(info.value)


@pytest.mark.parametrize(
    "status, error_type, terminal, kind",
    [
        (401, "authentication_error", True, "auth"),
        (403, "permission_error", True, "auth"),
        (404, "not_found_error", True, "request"),
        (429, "rate_limit_error", False, "transient"),
        (529, "overloaded_error", False, "transient"),
        (500, "api_error", False, "transient"),
    ],
)
def test_error_mapping(status, error_type, terminal, kind):
    llm, _ = provider(lambda req, n: httpx2.Response(status, json={"type": "error", "error": {"type": error_type, "message": "x"}}))
    with pytest.raises(ProviderError) as info:
        llm.summarize(REQUEST)
    assert info.value.terminal is terminal and info.value.kind == kind


def test_invalid_json_and_truncation_are_retryable():
    llm, _ = provider(lambda req, n: httpx2.Response(200, json=message("{not json")))
    with pytest.raises(ProviderError) as info:
        llm.summarize(REQUEST)
    assert not info.value.terminal
    llm, _ = provider(lambda req, n: httpx2.Response(200, json=message('{"title": "Hel', stop_reason="max_tokens")))
    with pytest.raises(ProviderError) as info:
        llm.summarize(REQUEST)
    assert not info.value.terminal


def test_haiku_and_effort_none_omit_effort():
    for model, effort in (("claude-haiku-4-5", "medium"), ("claude-opus-5", "none")):
        seen: list[httpx2.Request] = []

        def record(request: httpx2.Request, seen: list[httpx2.Request] = seen) -> httpx2.Response:
            seen.append(request)
            return httpx2.Response(200, json=message(json.dumps({"title": "x"})))

        client = anthropic.Anthropic(
            api_key="k", max_retries=0, http_client=anthropic.DefaultHttpxClient(transport=httpx2.MockTransport(record))
        )
        AnthropicLlm("k", model, effort, client=client).summarize(REQUEST)
        assert "effort" not in json.loads(seen[0].content)["output_config"], model
