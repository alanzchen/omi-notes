"""The OpenAI-compatible notes provider against a mock HTTP transport."""

import json

import httpx
import pytest

from omi_notes.notes.schema import NOTES_JSON_SCHEMA
from omi_notes.pipeline.prompt import SYSTEM_PROMPT
from omi_notes.providers import LlmRequest, ProviderError
from omi_notes.providers.openai_llm import OpenAICompatLlm

REQUEST = LlmRequest(system=SYSTEM_PROMPT, user="FULL TRANSCRIPT\n[00:00 S1] hi", schema=NOTES_JSON_SCHEMA)


def completion(content: str | None, finish_reason: str = "stop", **message) -> dict:
    return {
        "id": "chatcmpl-1", "object": "chat.completion", "model": "gpt-test",
        "choices": [{"index": 0, "finish_reason": finish_reason,
                     "message": {"role": "assistant", "content": content} | message}],
        "usage": {"prompt_tokens": 1200, "completion_tokens": 300, "prompt_tokens_details": {"cached_tokens": 1024}},
    }  # fmt: skip


def provider(handler, **kwargs) -> tuple[OpenAICompatLlm, list[httpx.Request]]:
    seen: list[httpx.Request] = []

    def record(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request, len(seen))

    client = httpx.Client(transport=httpx.MockTransport(record))
    llm = OpenAICompatLlm(kwargs.pop("base_url", "https://api.example.com/v1/"), kwargs.pop("api_key", "sk-test"),
                          kwargs.pop("model", "gpt-test"), client=client, **kwargs)  # fmt: skip
    return llm, seen


def test_request_shape_and_parsed_result():
    llm, seen = provider(lambda req, n: httpx.Response(200, json=completion(json.dumps({"title": "Hello", "keep": True}))))
    result = llm.summarize(REQUEST)
    assert result.data == {"title": "Hello", "keep": True}
    assert result.model == "gpt-test"
    assert result.usage == {"input_tokens": 1200, "output_tokens": 300, "cache_read_input_tokens": 1024,
                            "cache_creation_input_tokens": 0}  # fmt: skip
    (req,) = seen
    assert str(req.url) == "https://api.example.com/v1/chat/completions"
    assert req.headers["authorization"] == "Bearer sk-test"
    body = json.loads(req.content)
    assert body["model"] == "gpt-test"
    assert body["messages"] == [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": REQUEST.user}]
    assert body["response_format"] == {
        "type": "json_schema", "json_schema": {"name": "conversation_notes", "schema": NOTES_JSON_SCHEMA, "strict": True}
    }  # fmt: skip
    assert "reasoning_effort" not in body and "temperature" not in body


def test_local_server_without_key_sends_no_auth_and_optional_reasoning_effort():
    llm, seen = provider(lambda req, n: httpx.Response(200, json=completion("{}")), api_key="", reasoning_effort="high",
                         base_url="http://localhost:11434/v1")  # fmt: skip
    llm.summarize(REQUEST)
    assert "authorization" not in seen[0].headers
    assert json.loads(seen[0].content)["reasoning_effort"] == "high"


def test_schema_rejection_downgrades_once_and_is_remembered():
    def handler(req, n):
        body = json.loads(req.content)
        if body.get("response_format", {}).get("type") == "json_schema":
            return httpx.Response(400, json={"error": {"message": "response_format json_schema is not supported"}})
        return httpx.Response(200, json=completion('{"title": "Ok"}'))

    llm, seen = provider(handler)
    assert llm.summarize(REQUEST).data == {"title": "Ok"}
    downgraded = json.loads(seen[1].content)
    assert downgraded["response_format"] == {"type": "json_object"}
    assert "must match this JSON Schema" in downgraded["messages"][0]["content"]
    llm.summarize(REQUEST)
    assert len(seen) == 3 and json.loads(seen[2].content)["response_format"] == {"type": "json_object"}


def test_prompt_only_when_json_mode_is_also_rejected():
    def handler(req, n):
        if "response_format" in json.loads(req.content):
            return httpx.Response(400, json={"error": {"message": "unknown field response_format"}})
        return httpx.Response(200, json=completion('```json\n{"title": "Fenced"}\n```'))

    llm, seen = provider(handler)
    assert llm.summarize(REQUEST).data == {"title": "Fenced"}
    assert len(seen) == 3


def test_fixed_json_mode_never_downgrades():
    llm, seen = provider(lambda req, n: httpx.Response(400, json={"error": {"message": "json_schema unsupported"}}),
                         json_mode="json_schema")  # fmt: skip
    with pytest.raises(ProviderError) as err:
        llm.summarize(REQUEST)
    assert err.value.terminal and len(seen) == 1


@pytest.mark.parametrize(
    ("status", "terminal", "kind"),
    [(401, True, "auth"), (403, True, "auth"), (402, True, "billing"), (404, True, "request"),
     (429, False, "transient"), (500, False, "transient"), (503, False, "transient")],
)  # fmt: skip
def test_http_errors_are_classified(status, terminal, kind):
    llm, _ = provider(lambda req, n: httpx.Response(status, json={"error": {"message": "nope"}}))
    with pytest.raises(ProviderError) as err:
        llm.summarize(REQUEST)
    assert (err.value.terminal, err.value.kind) == (terminal, kind)


def test_unrelated_bad_request_is_terminal_without_downgrade():
    llm, seen = provider(lambda req, n: httpx.Response(400, json={"error": {"message": "context length exceeded"}}))
    with pytest.raises(ProviderError) as err:
        llm.summarize(REQUEST)
    assert err.value.terminal and len(seen) == 1


def test_refusal_truncation_and_bad_json():
    cases = [
        (completion(None, refusal="I can't help with that."), True, "refusal"),
        (completion('{"title": "cut', finish_reason="length"), False, "transient"),
        (completion("not json"), False, "transient"),
        (completion("[1, 2]"), False, "transient"),
        ({"object": "error"}, False, "transient"),
    ]
    for payload, terminal, kind in cases:
        llm, _ = provider(lambda req, n, p=payload: httpx.Response(200, json=p))
        with pytest.raises(ProviderError) as err:
            llm.summarize(REQUEST)
        assert (err.value.terminal, err.value.kind) == (terminal, kind), payload


def test_network_error_is_retryable():
    def handler(req, n):
        raise httpx.ConnectError("connection refused")

    llm, _ = provider(handler)
    with pytest.raises(ProviderError) as err:
        llm.summarize(REQUEST)
    assert err.value.kind == "network" and not err.value.terminal


def test_pipeline_builds_the_openai_provider(settings):
    from omi_notes.pipeline.conversations import Providers

    s = settings.model_copy(update={"llm_provider": "openai", "llm_model": "qwen-test", "llm_base_url": "http://localhost:11434/v1"})
    llm = Providers(s).llm
    assert isinstance(llm, OpenAICompatLlm) and llm.url == "http://localhost:11434/v1/chat/completions"
