"""The local ASR sidecar as STT (`STT_LOCAL_URL`): request shape, long pieces, speakers linked across
pieces by voiceprint, and the fallback to the STT_* provider while it is down. Mocked transports only."""

from __future__ import annotations

import io
import json

import httpx
import numpy as np
import soundfile as sf

from omi_notes.pipeline.speaker_links import link, overlap_spans
from omi_notes.pipeline.speakers import resolve_speakers
from omi_notes.providers.local_asr import LocalAsrStt

from .helpers import T0, convs, replay
from .test_openai_stt import audio_with_blocks, form
from .test_speaker_learning import ALAN, PRIYA, RAVI, FakeEmbedder, voice

SR = 16000


def sidecar(handler=None, *, down=False, max_seconds=900.0, seen=None):
    """A LocalAsrStt on a mock transport: /health answers 200 (or the connection fails when `down`)."""
    seen = seen if seen is not None else []

    def transport(request: httpx.Request) -> httpx.Response:
        if down:
            raise httpx.ConnectError("connection refused")
        if request.url.path == "/health":
            return httpx.Response(200, json={"ok": True})
        seen.append(request)
        return handler(request, len(seen)) if handler else httpx.Response(200, json={"segments": []})

    return LocalAsrStt("http://127.0.0.1:18793/v1", max_request_seconds=max_seconds, transport=httpx.MockTransport(transport)), seen


def seconds_of(request: httpx.Request) -> float:
    return sf.read(io.BytesIO(form(request)["file"][0][2]))[0].shape[0] / SR


def test_requests_carry_context_and_no_prompt_or_language_in_pieces_within_the_limit():
    def handler(request, n):
        return httpx.Response(200, json={"segments": [{"start": 0.5, "end": 2.0, "speaker_id": "S01", "text": f"piece {n}"},
                                                      {"start": 2.5, "end": 4.0, "speaker_id": "S02", "text": "reply"}]})
    stt, seen = sidecar(handler, max_seconds=20)
    result = stt.transcribe(audio_with_blocks([8, 8, 8, 8, 8]))  # 42 s with pauses between blocks
    assert len(seen) >= 3 and all(seconds_of(r) <= 20 for r in seen)
    fields = form(seen[0])
    assert fields["model"] == ["omi-asr"] and fields["response_format"] == ["diarized_json"]
    assert fields["context"] == ["Omi, Priya"], "keyterms go as context (Qwen hotwords)"
    assert "prompt" not in fields and "language" not in fields, "a MOSS prompt would replace its instruction"
    utterances = result["results"]["utterances"]
    assert len({u["speaker"] for u in utterances}) == 2 * len(seen), "labels restart per piece until linked"
    assert result["omi_notes"]["pieces"] == len(seen)


def test_health_is_checked_and_remembered_briefly():
    up, _ = sidecar()
    assert up.healthy() and up.healthy()
    down, _ = sidecar(down=True)
    assert not down.healthy()


def pieces_response(spans: list[tuple[float, float, int]], offsets: list[float]) -> dict:
    return {"results": {"channels": [{}], "utterances": [{"start": a, "end": b, "speaker": s, "transcript": "x"} for a, b, s in spans]},
            "omi_notes": {"pieces": len(offsets), "offsets": offsets}}


def test_labels_are_linked_across_pieces_by_voice_and_a_new_voice_is_a_new_speaker():
    pcm = np.concatenate([voice(10, ALAN, 1), voice(10, PRIYA, 2), voice(10, PRIYA, 3), voice(10, RAVI, 4)])
    # piece 0 (0-20 s): labels 0 Alan, 1 Priya; piece 1 (20-40 s): labels 2 Priya, 3 Ravi
    response = pieces_response([(0, 10, 0), (10, 20, 1), (20, 30, 2), (30, 40, 3)], [0.0, 20.0])
    out = link(response, pcm, FakeEmbedder())
    assert [u["speaker"] for u in out["results"]["utterances"]] == [0, 1, 1, 2]
    meta = out["omi_notes"]["speakers_linked"]
    assert meta["labels"] == 4 and meta["speakers"] == 3
    assert resolve_speakers(out, "provider", lambda: None).consistent, "linked labels are one consistent set"
    strict = link(response, pcm, FakeEmbedder(), threshold=1.01)
    assert len({u["speaker"] for u in strict["results"]["utterances"]}) == 4, "below the threshold: a new speaker"


def test_a_label_starting_at_a_rounded_offset_belongs_to_its_own_piece():
    pcm = np.concatenate([voice(10, ALAN, 1), voice(10, ALAN, 2)])
    response = pieces_response([(0, 10.0004, 0), (10.0004, 20, 1)], [0.0, 10.0])  # cut at 10.0004, recorded as 10.0
    response["omi_notes"]["offsets"] = [0.0, 10.001]
    out = link(response, pcm, FakeEmbedder())
    assert {u["speaker"] for u in out["results"]["utterances"]} == {0}, out["omi_notes"]["speakers_linked"]


def test_two_labels_of_one_piece_never_join_even_with_the_same_voice():
    pcm = np.concatenate([voice(10, ALAN, 1), voice(10, ALAN, 2), voice(10, ALAN, 3)])
    response = pieces_response([(0, 10, 0), (10, 20, 1), (20, 30, 2)], [0.0, 20.0])
    out = link(response, pcm, FakeEmbedder())
    speakers = [u["speaker"] for u in out["results"]["utterances"]]
    assert speakers[0] != speakers[1], "the provider told them apart within its piece"
    assert speakers[2] not in (speakers[0], speakers[1]), "as close to both: the margin rule makes it new"


def test_overlapped_speech_is_found_for_exclusion_from_voiceprints():
    spans = overlap_spans([{"start": 0, "end": 5, "speaker": 0}, {"start": 4, "end": 8, "speaker": 1}, {"start": 9, "end": 10, "speaker": 1}])
    assert spans == [(4, 5)]


def moss_like(request, n):
    """A sidecar answer for any piece: one speaker over the whole piece (S01 restarts every piece)."""
    seconds = seconds_of(request)
    return httpx.Response(200, json={"language": "en", "duration": seconds,
                                     "segments": [{"start": 0.0, "end": seconds, "speaker_id": "S01", "text": f"part {n}"}]})


def test_the_pipeline_uses_the_sidecar_with_its_speakers_linked_into_one_transcript(client, worker, settings):
    stt, seen = sidecar(moss_like, max_seconds=5)
    worker.providers._local_stt = stt
    worker.providers._embedder = FakeEmbedder()
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(12, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "done", row["error"]
    transcript = json.loads((worker.pipeline.conv_dir(row["id"]) / "transcript.json").read_text())
    assert len(seen) >= 2, "split into pieces of at most 5 s"
    assert transcript["stt"] == "local-asr/omi-asr" and transcript["speaker_source"] == "provider"
    assert transcript["speaker_labels_consistent"] is True and transcript["timing_source"] == "provider"
    assert len({s["speaker"] for s in transcript["segments"]}) == 1, "one voice in every piece: one speaker"


def test_while_the_sidecar_is_down_the_configured_provider_transcribes(client, worker):
    stt, seen = sidecar(moss_like, down=True)
    worker.providers._local_stt = stt
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    transcript = json.loads((worker.pipeline.conv_dir(row["id"]) / "transcript.json").read_text())
    assert not seen and transcript["stt"].startswith("fake/"), transcript["stt"]



class CodedEmbedder:
    """Each synthetic voice is a constant sample value; its vector is looked up by that value."""

    def __init__(self, vectors: dict[int, list[float]]):
        self.vectors = vectors

    def embed(self, pcm: np.ndarray) -> np.ndarray:
        return np.asarray(self.vectors[int(pcm[len(pcm) // 2])], dtype=np.float64)


def test_a_label_kept_from_its_closest_speaker_by_the_piece_rule_never_joins_the_runner_up():
    # X and Y sound alike (cosine 0.87): piece 1 has X twice (provider over-split), the second must stay
    # apart rather than becoming Y
    y = [0.87, float(np.sqrt(1 - 0.87**2)), 0.0]
    embedder = CodedEmbedder({1: [1.0, 0.0, 0.0], 2: y})
    pcm = np.concatenate([np.full(10 * SR, v, np.int16) for v in (1, 2, 1, 1)])
    response = pieces_response([(0, 10, 0), (10, 20, 1), (20, 30, 2), (30, 40, 3)], [0.0, 20.0])
    out = link(response, pcm, embedder)
    speakers = [u["speaker"] for u in out["results"]["utterances"]]
    assert speakers[:3] == [0, 1, 0]
    assert speakers[3] not in (0, 1), out["omi_notes"]["speakers_linked"]


def test_a_finished_conversation_transcribed_again_reuses_its_cached_stt_whichever_provider_is_up(client, worker):
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "done" and row["stt_ref"].startswith("stt-fake")
    # the sidecar is switched on: a re-run (e.g. a lost transcript.json) must not transcribe again
    stt, seen = sidecar(moss_like)
    worker.providers._local_stt = stt
    worker.pipeline._set(row["id"], status="closed")
    worker.tick(T0 + 500)
    (row,) = convs(worker)
    transcript = json.loads((worker.pipeline.conv_dir(row["id"]) / "transcript.json").read_text())
    assert row["status"] == "done" and not seen and transcript["stt"].startswith("fake/")


def test_a_conversation_from_the_sidecar_keeps_its_transcript_while_the_sidecar_is_down(client, worker):
    stt, seen = sidecar(moss_like)
    worker.providers._local_stt = stt
    worker.providers._embedder = FakeEmbedder()
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["stt_ref"].startswith("stt-local-asr") and len(seen) == 1
    down, _ = sidecar(moss_like, down=True)
    worker.providers._local_stt = down
    worker.pipeline._set(row["id"], status="closed")
    worker.tick(T0 + 500)
    (row,) = convs(worker)
    transcript = json.loads((worker.pipeline.conv_dir(row["id"]) / "transcript.json").read_text())
    assert row["status"] == "done" and transcript["stt"] == "local-asr/omi-asr", "not re-transcribed by the fallback"
    assert transcript["speaker_source"] == "provider"


def test_a_long_piece_gets_a_bounded_timeout_not_an_hour():
    stt, _ = sidecar()
    assert stt._client.timeout.read <= 1200
