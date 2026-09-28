"""OpenAI-compatible transcription: request shapes, response normalization, splitting, errors."""

from __future__ import annotations

import io
from email.parser import BytesParser
from email.policy import default as email_policy

import httpx
import numpy as np
import pytest
import soundfile as sf

from omi_notes.providers import ProviderError, SttRequest
from omi_notes.providers.openai_stt import (
    OpenAICompatStt,
    default_max_seconds,
    normalize_response,
    resolve_style,
    split_request,
)

SR = 16000


def flac(pcm: np.ndarray) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, pcm, SR, format="FLAC", subtype="PCM_16")
    return buf.getvalue()


def audio_with_blocks(block_seconds: list[float], level: int = 3000) -> SttRequest:
    """Speech blocks (noise) separated by 0.5 s silent spacers, like `ConversationAudio`."""
    rng = np.random.default_rng(0)
    parts, blocks, t = [], [], 0.0
    for i, seconds in enumerate(block_seconds):
        if i:
            parts.append(np.zeros(SR // 2, np.int16))
            t += 0.5
        n = int(seconds * SR)
        parts.append(rng.normal(0, level, n).astype(np.int16))
        blocks.append((t, t + seconds))
        t += seconds
    pcm = np.concatenate(parts)
    return SttRequest(flac=flac(pcm), duration=len(pcm) / SR, blocks=blocks, language="en", keyterms=["Omi", "Priya"])


def form(request: httpx.Request) -> dict[str, list]:
    """Multipart fields of a recorded request: text values, or (filename, content type, bytes)."""
    head = f"Content-Type: {request.headers['content-type']}\r\n\r\n".encode()
    message = BytesParser(policy=email_policy).parsebytes(head + request.content)
    fields: dict[str, list] = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if part.get_filename():
            value = (part.get_filename(), part.get_content_type(), part.get_payload(decode=True))
        else:
            value = part.get_payload(decode=True).decode()
        fields.setdefault(name, []).append(value)
    return fields


def stt(base_url: str, model: str, responses, **kwargs) -> tuple[OpenAICompatStt, list[httpx.Request]]:
    seen: list[httpx.Request] = []
    queue = list(responses) if isinstance(responses, list) else None

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if queue is not None:
            item = queue.pop(0)
            return item if isinstance(item, httpx.Response) else httpx.Response(200, json=item)
        return responses(request, len(seen))

    return OpenAICompatStt(base_url, kwargs.pop("api_key", "sk-test"), model, transport=httpx.MockTransport(handler), **kwargs), seen


DIARIZED = {"task": "transcribe", "duration": 4.0, "text": "Hi. Hello.",
            "segments": [{"type": "transcript.text.segment", "id": "seg_0", "start": 0.2, "end": 1.5, "text": " Hi.", "speaker": "A"},
                         {"type": "transcript.text.segment", "id": "seg_1", "start": 1.8, "end": 3.9, "text": "Hello.", "speaker": "B"}]}  # fmt: skip


# -- style and limits ------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "base_url, model, configured, style",
    [
        ("https://api.openai.com/v1", "gpt-4o-transcribe-diarize", "auto", "openai_diarized"),
        ("http://gpu-box:8000/v1", "OpenMOSS-Team/MOSS-Transcribe-Diarize", "auto", "openai_diarized"),
        ("https://api.mistral.ai/v1", "voxtral-mini-latest", "auto", "mistral"),
        ("http://localhost:9000/v1", "voxtral-mini-2507", "auto", "mistral"),
        ("https://api.together.xyz/v1", "openai/whisper-large-v3", "auto", "together"),
        ("http://127.0.0.1:8080/v1", "whisper-1", "auto", "verbose"),
        ("https://api.groq.com/openai/v1", "whisper-large-v3-turbo", "auto", "verbose"),
        ("http://mac.local:8000/v1", "OpenMOSS-Team/MOSS-Transcribe-Diarize", "verbose", "verbose"),
    ],
)
def test_style_resolution(base_url, model, configured, style):
    assert resolve_style(base_url, model, configured) == style


def test_default_request_limits():
    assert default_max_seconds("openai_diarized", "https://api.openai.com/v1") == 1200
    assert default_max_seconds("openai_diarized", "http://gpu-box:8000/v1") == 0
    assert default_max_seconds("together", "https://api.together.xyz/v1") == 3600
    assert default_max_seconds("mistral", "https://api.mistral.ai/v1") == 0
    assert default_max_seconds("verbose", "http://localhost:8080/v1") == 0
    provider, _ = stt("https://api.openai.com/v1", "gpt-4o-transcribe-diarize", [], max_request_seconds=600)
    assert provider.max_seconds == 600


def test_gpt_transcribe_json_request_and_local_window_duration():
    provider, seen = stt("https://transcription.example/v1", "gpt-transcribe", [{"text": "A useful reminder.", "languages": [{"code": "en"}]}])
    response = provider.transcribe(audio_with_blocks([2.0]))
    fields = form(seen[0])
    assert fields["response_format"] == ["json"]
    assert fields["languages[]"] == ["en"] and "language" not in fields
    assert fields["keywords[]"] == ["Omi", "Priya"]
    assert "diarize" not in fields and "timestamp_granularities[]" not in fields
    assert response["results"]["utterances"][0]["end"] == 2.0
    assert response["results"]["channels"][0]["detected_language"] == "en"


def test_json_response_without_text_is_an_error_not_silence():
    provider, _ = stt("https://transcription.example/v1", "gpt-transcribe", [{"unexpected": "shape"}], style="json")
    with pytest.raises(ProviderError, match="text"):
        provider.transcribe(audio_with_blocks([2.0]))


# -- request fields --------------------------------------------------------------------------------


def request_fields(base_url, model, *, language="en", **kwargs) -> tuple[dict, httpx.Request]:
    provider, seen = stt(base_url, model, [DIARIZED], **kwargs)
    req = audio_with_blocks([2.0])
    provider.transcribe(SttRequest(req.flac, req.duration, req.blocks, language, req.keyterms))
    (request,) = seen
    return form(request), request


def test_openai_diarized_request():
    fields, request = request_fields("https://api.openai.com/v1", "gpt-4o-transcribe-diarize")
    assert request.url == "https://api.openai.com/v1/audio/transcriptions"
    assert request.headers["authorization"] == "Bearer sk-test"
    assert fields.pop("file")[0][:2] == ("audio.flac", "audio/flac")
    assert fields == {"model": ["gpt-4o-transcribe-diarize"], "response_format": ["diarized_json"],
                      "chunking_strategy": ["auto"], "language": ["en"]}  # fmt: skip


def test_openai_diarized_self_hosted_request_has_no_chunking_strategy():
    fields, _ = request_fields("http://gpu-box:8000/v1", "OpenMOSS-Team/MOSS-Transcribe-Diarize", language="multi", api_key="")
    fields.pop("file")
    assert fields == {"model": ["OpenMOSS-Team/MOSS-Transcribe-Diarize"], "response_format": ["diarized_json"]}


def test_request_without_api_key_sends_no_authorization():
    _, request = request_fields("http://localhost:8080/v1", "whisper-1", api_key="")
    assert "authorization" not in request.headers


def test_mistral_request():
    fields, _ = request_fields("https://api.mistral.ai/v1", "voxtral-mini-latest")
    fields.pop("file")
    assert fields == {"model": ["voxtral-mini-latest"], "diarize": ["true"], "language": ["en"],
                      "context_bias[]": ["Omi", "Priya"]}  # fmt: skip
    assert "timestamp_granularities[]" not in fields  # incompatible with language


def test_together_request():
    fields, _ = request_fields("https://api.together.xyz/v1", "openai/whisper-large-v3")
    fields.pop("file")
    assert fields == {"model": ["openai/whisper-large-v3"], "response_format": ["verbose_json"], "diarize": ["true"],
                      "language": ["en"]}  # fmt: skip


def test_verbose_request():
    fields, _ = request_fields("http://localhost:8080/v1", "whisper-1")
    fields.pop("file")
    assert fields == {"model": ["whisper-1"], "response_format": ["verbose_json"],
                      "timestamp_granularities[]": ["word", "segment"], "diarize": ["true"], "language": ["en"],
                      "prompt": ["Omi, Priya"]}  # fmt: skip


def test_context_bias_is_capped_at_100_terms():
    provider, seen = stt("https://api.mistral.ai/v1", "voxtral-mini-latest", [DIARIZED])
    req = audio_with_blocks([1.0])
    provider.transcribe(SttRequest(req.flac, req.duration, req.blocks, "en", [f"t{i}" for i in range(150)]))
    assert len(form(seen[0])["context_bias[]"]) == 100


def test_rejected_context_bias_is_retried_without_it():
    rejection = httpx.Response(422, json={"detail": [{"loc": ["body", "context_bias"], "msg": "unexpected"}]})
    provider, seen = stt("https://api.mistral.ai/v1", "voxtral-mini-latest", [rejection, DIARIZED])
    req = audio_with_blocks([1.0])
    provider.transcribe(req)
    assert "context_bias[]" in form(seen[0]) and "context_bias[]" not in form(seen[1])


def test_auto_style_downgrades_when_diarized_json_is_unknown():
    rejection = httpx.Response(400, json={"error": "Unsupported response_format: diarized_json"})
    verbose = {"text": "hi", "segments": [{"start": 0, "end": 1, "text": "[S01] hi", "speaker_id": "S01"}]}
    provider, seen = stt("http://mac.local:8000/v1", "OpenMOSS-Team/MOSS-Transcribe-Diarize", [rejection, verbose])
    result = provider.transcribe(audio_with_blocks([1.0]))
    assert form(seen[1])["response_format"] == ["verbose_json"] and provider.style == "verbose"
    assert result["results"]["utterances"][0]["transcript"] == "hi"


# -- response normalization ------------------------------------------------------------------------


def utterances(data: dict) -> list[tuple]:
    return [(u["start"], u["end"], u["speaker"], u["transcript"]) for u in normalize_response(data)["results"]["utterances"]]


def test_openai_diarized_json():
    assert utterances(DIARIZED) == [(0.2, 1.5, 0, "Hi."), (1.8, 3.9, 1, "Hello.")]


def test_vllm_moss_labels():
    data = {"text": "", "segments": [{"start": 0, "end": 1, "text": "a", "speaker": "S01"},
                                     {"start": 1, "end": 2, "text": "b", "speaker": "S02"},
                                     {"start": 2, "end": 3, "text": "c", "speaker": "S01"}]}  # fmt: skip
    assert [u[2] for u in utterances(data)] == [0, 1, 0]


def test_verbose_json_with_speakers_and_top_level_words():
    data = {"language": "english", "duration": 3.0, "text": "Hello there. Hi.",
            "segments": [{"id": 0, "start": 0.0, "end": 1.4, "text": " Hello there.", "speaker": "SPEAKER_01"},
                         {"id": 1, "start": 1.6, "end": 2.5, "text": " Hi.", "speaker": "SPEAKER_00"}],
            "words": [{"word": " Hello", "start": 0.0, "end": 0.5}, {"word": " there.", "start": 0.6, "end": 1.4},
                      {"word": " Hi.", "start": 1.6, "end": 2.5}]}  # fmt: skip
    result = normalize_response(data)
    first, second = result["results"]["utterances"]
    assert (first["speaker"], second["speaker"]) == (0, 1)
    assert [w["punctuated_word"] for w in first["words"]] == ["Hello", "there."]
    assert [w["start"] for w in second["words"]] == [1.6]
    assert result["results"]["channels"][0]["detected_language"] == "en"


def test_mistral_speaker_ids_and_language():
    data = {"model": "voxtral-mini-2602", "language": "fr", "text": "Bonjour. Salut.",
            "segments": [{"text": "Bonjour.", "start": 0.0, "end": 1.0, "speaker_id": "speaker_1"},
                         {"text": "Salut.", "start": 1.2, "end": 2.0, "speaker_id": "speaker_2"}]}  # fmt: skip
    assert utterances(data) == [(0.0, 1.0, 0, "Bonjour."), (1.2, 2.0, 1, "Salut.")]
    assert normalize_response(data)["results"]["channels"][0]["detected_language"] == "fr"


def test_mlx_audio_prefix_is_stripped():
    data = {"segments": [{"start": 0, "end": 1, "text": "[S01] Hello there", "speaker_id": "S01"},
                         {"start": 1, "end": 2, "text": "[S02]Hi", "speaker_id": None},
                         {"start": 2, "end": 3, "text": "[S01] Again"}]}  # fmt: skip
    assert utterances(data) == [(0, 1, 0, "Hello there"), (1, 2, 1, "Hi"), (2, 3, 0, "Again")]


def test_together_speaker_segments_with_words():
    data = {"text": "x", "segments": [{"start": 0, "end": 9, "text": "ignored in favour of speaker_segments"}],
            "speaker_segments": [
                {"id": 0, "speaker_id": "SPEAKER_01", "start": 0.0, "end": 1.0, "text": "Morning all.",
                 "words": [{"word": "Morning", "start": 0.0, "end": 0.4, "id": 0, "speaker_id": "SPEAKER_01"},
                           {"word": "all.", "start": 0.5, "end": 1.0, "id": 1, "speaker_id": "SPEAKER_01"}]},
                {"id": 1, "speaker_id": "SPEAKER_00", "start": 1.2, "end": 2.0, "text": "Hey.", "words": []}]}  # fmt: skip
    result = normalize_response(data)["results"]["utterances"]
    assert [(u["speaker"], u["transcript"]) for u in result] == [(0, "Morning all."), (1, "Hey.")]
    assert [w["word"] for w in result[0]["words"]] == ["Morning", "all."]


def test_integer_speakers_are_mapped_by_first_appearance():
    data = {"segments": [{"start": 0, "end": 1, "text": "a", "speaker": 3}, {"start": 1, "end": 2, "text": "b", "speaker": 0}]}
    assert [u[2] for u in utterances(data)] == [0, 1]


def test_plain_whisper_has_no_speaker_information():
    data = {"language": "en", "segments": [{"start": 0, "end": 1, "text": "hello"}], "text": "hello"}
    assert [u[2] for u in utterances(data)] == [None]


def test_text_only_response():
    assert utterances({"text": " just text ", "duration": 2.5}) == [(0.0, 2.5, None, "just text")]


def test_empty_segments_are_dropped():
    data = {"segments": [{"start": 0, "end": 1, "text": "  ", "speaker": "A"}, {"start": 1, "end": 2, "text": "x", "speaker": "B"}]}
    assert utterances(data) == [(1, 2, 0, "x")]


# -- splitting -------------------------------------------------------------------------------------


def test_split_cuts_only_in_spacers():
    req = audio_with_blocks([30, 40, 50, 20, 45])
    parts = split_request(req, max_seconds=100)
    assert len(parts) >= 3
    spacers = [(a[1], b[0]) for a, b in zip(req.blocks, req.blocks[1:], strict=False)]
    for offset, _ in parts[1:]:
        assert any(lo < offset < hi for lo, hi in spacers), offset
    assert all(part.duration <= 100 + 1e-6 for _, part in parts)
    total = sum(sf.read(io.BytesIO(part.flac))[0].shape[0] for _, part in parts)
    assert total == round(req.duration * SR)
    for _, part in parts:  # blocks are re-based onto each piece
        assert all(0 <= a < b <= part.duration + 1e-6 for a, b in part.blocks)
        assert part.language == "en" and part.keyterms == req.keyterms


def test_a_block_longer_than_the_limit_is_cut_inside_it():
    req = audio_with_blocks([250])
    parts = split_request(req, max_seconds=100)
    assert len(parts) == 3 and all(part.duration <= 100 + 1e-6 for _, part in parts)


def test_short_audio_is_not_split():
    req = audio_with_blocks([10, 10])
    assert [offset for offset, _ in split_request(req, max_seconds=100)] == [0.0]


def test_long_audio_is_transcribed_in_pieces_and_merged():
    req = audio_with_blocks([30, 30, 30])

    def handler(request, n):
        return httpx.Response(200, json={"segments": [
            {"start": 1.0, "end": 5.0, "text": f"piece {n} first", "speaker": "A"},
            {"start": 6.0, "end": 9.0, "text": f"piece {n} second", "speaker": "B"}]})  # fmt: skip

    provider, seen = stt("https://api.openai.com/v1", "gpt-4o-transcribe-diarize", handler, max_request_seconds=40)
    result = provider.transcribe(req)
    parts = split_request(req, max_seconds=40)
    assert len(seen) == len(parts) == 3
    utts = result["results"]["utterances"]
    assert [u["start"] for u in utts] == pytest.approx([o + s for o, _ in parts for s in (1.0, 6.0)])
    # labels restart per piece, so they are namespaced: A/B of piece 2 are not A/B of piece 1
    assert [u["speaker"] for u in utts] == [0, 1, 2, 3, 4, 5]
    assert result["omi_notes"]["pieces"] == 3


def test_413_splits_and_retries_smaller():
    req = audio_with_blocks([20, 20, 20, 20])
    responses = [httpx.Response(413, text="too large"), DIARIZED, DIARIZED]
    provider, seen = stt("http://gpu-box:8000/v1", "x-diarize", responses)
    result = provider.transcribe(req)
    assert len(seen) == 3 and result["omi_notes"]["pieces"] == 2
    halves = [sf.read(io.BytesIO(form(r)["file"][0][2]))[0].shape[0] / SR for r in seen[1:]]
    assert sum(halves) == pytest.approx(req.duration) and max(halves) < req.duration


def test_413_on_a_single_block_is_terminal():
    provider, _ = stt("http://gpu-box:8000/v1", "x-diarize", [httpx.Response(413, text="too large")])
    with pytest.raises(ProviderError) as info:
        provider.transcribe(audio_with_blocks([20]))
    assert info.value.terminal and "413" in str(info.value)


# -- errors ----------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "status, terminal, kind",
    [(401, True, "auth"), (403, True, "auth"), (402, True, "billing"), (429, False, "transient"),
     (500, False, "transient"), (503, False, "transient"), (408, False, "transient"), (400, True, "request"),
     (404, True, "request")],
)  # fmt: skip
def test_error_classification(status, terminal, kind):
    provider, _ = stt("http://localhost:8080/v1", "whisper-1", [httpx.Response(status, text="nope")])
    with pytest.raises(ProviderError) as info:
        provider.transcribe(audio_with_blocks([1.0]))
    assert (info.value.terminal, info.value.kind) == (terminal, kind)


def test_network_errors_are_transient():
    def handler(request, n):
        raise httpx.ConnectError("refused", request=request)

    provider, _ = stt("http://localhost:8080/v1", "whisper-1", handler)
    with pytest.raises(ProviderError) as info:
        provider.transcribe(audio_with_blocks([1.0]))
    assert not info.value.terminal and info.value.kind == "network"


def test_non_json_response_is_transient():
    provider, _ = stt("http://localhost:8080/v1", "whisper-1", [httpx.Response(200, text="<html>proxy</html>")])
    with pytest.raises(ProviderError) as info:
        provider.transcribe(audio_with_blocks([1.0]))
    assert not info.value.terminal
