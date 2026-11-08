"""The local ASR sidecar as STT (`STT_LOCAL_URL`): request shape, long pieces, speakers linked across
pieces by voiceprint, and the fallback to the STT_* provider while it is down. Mocked transports only."""

from __future__ import annotations

import io
import json
from datetime import timedelta

import httpx
import pytest
import numpy as np
import soundfile as sf

from omi_notes.pipeline.speaker_links import link, overlap_spans
from omi_notes.pipeline.speakers import resolve_speakers
from omi_notes.providers.local_asr import LocalAsrStt

from .conftest import AUTH
from .helpers import STARTED, T0, convs, replay
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
    groups = result["omi_notes"]["groups"]
    assert len({g for _, g in groups}) == len(seen) and len(groups) == 2 * len(seen), "labels restart per request"
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
    assert speakers[2] in (speakers[0], speakers[1]) or speakers[2] not in speakers[:2], "one of them at most"


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


def test_while_the_sidecar_is_down_conversations_wait_without_using_up_attempts_then_resume(client, worker):
    down, seen = sidecar(moss_like, down=True)
    worker.providers._local_stt = down
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    for k in range(10):  # well past MAX_ATTEMPTS: waiting is not failing
        worker.tick(T0 + 400 + 120 * k)
    (row,) = convs(worker)
    assert row["status"] == "transcribing" and row["error_kind"] == "stt_unavailable" and row["attempts"] == 0
    assert not seen and not (worker.pipeline.conv_dir(row["id"]) / "transcript.json").exists(), "never the old path"
    up, seen = sidecar(moss_like)
    worker.providers._local_stt = up
    worker.tick(T0 + 400 + 120 * 11)
    (row,) = convs(worker)
    transcript = json.loads((worker.pipeline.conv_dir(row["id"]) / "transcript.json").read_text())
    assert row["status"] == "done" and transcript["stt"] == "local-asr/omi-asr" and len(seen) == 1


def test_a_sidecar_that_dies_mid_request_makes_the_conversation_wait(client, worker):
    calls = []

    def transport(request):
        if request.url.path == "/health":
            return httpx.Response(200 if not calls else 503, json={})
        calls.append(request)
        raise httpx.ReadError("connection reset")

    worker.providers._local_stt = LocalAsrStt("http://127.0.0.1:18793/v1", transport=httpx.MockTransport(transport))
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert calls and row["status"] == "transcribing" and row["error_kind"] == "stt_unavailable" and row["attempts"] == 0


def test_a_sidecar_down_ten_minutes_is_an_issue_and_an_alert_until_it_is_back(client, worker, settings):
    from omi_notes import views

    worker.providers._local_stt, _ = sidecar(down=True)
    worker.pipeline.watch_local_stt(T0)
    assert not [i for i in views.server_issues(worker.db, read_only=None, worker=True, now=T0 + 1) if i["code"] == "local_transcription_unavailable"]
    worker.pipeline.watch_local_stt(T0 + 601)
    (issue,) = [i for i in views.server_issues(worker.db, read_only=None, worker=True, now=T0 + 601) if i["code"] == "local_transcription_unavailable"]
    assert "10 min" in issue["message"]
    alert = json.loads((settings.logs_dir / "alerts" / "local-transcription.json").read_text())
    assert alert["state"] == "down" and alert["down_since"]
    worker.providers._local_stt, _ = sidecar()
    worker.pipeline.watch_local_stt(T0 + 700)
    assert not [i for i in views.server_issues(worker.db, read_only=None, worker=True, now=T0 + 700) if i["code"] == "local_transcription_unavailable"]
    assert json.loads((settings.logs_dir / "alerts" / "local-transcription.json").read_text())["state"] == "recovered"
    assert "local_transcription" in client.get("/v1/status", headers=AUTH).json()
    configured = settings.model_copy(update={"stt_local_url": "http://127.0.0.1:18793/v1"})
    state = views.local_transcription(worker.db, configured, T0 + 700)
    assert state["available"] is True and state["down_since"] is None and state["checked_at"]



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
    assert speakers[3] != speakers[1], out["omi_notes"]["speakers_linked"]


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


def test_labels_of_a_moss_resplit_inside_one_request_are_linked_by_voice():
    # one request; MOSS was re-split at 20 s and its labels restarted: S01/S02 then W1.2-S01/W1.2-S02,
    # with the numbering swapped in the second half
    pcm = np.concatenate([voice(10, ALAN, 1), voice(10, PRIYA, 2), voice(10, PRIYA, 3), voice(10, ALAN, 4)])

    def handler(request, n):
        return httpx.Response(200, json={
            "language": "English", "duration": 40.0,
            "windows": [{"start": 0.0, "end": 20.0, "label_prefix": ""}, {"start": 20.0, "end": 40.0, "label_prefix": "W1.2-"}],
            "segments": [{"start": 0.5, "end": 9.5, "speaker_id": "S01", "text": "alan one"},
                         {"start": 10.5, "end": 19.5, "speaker_id": "S02", "text": "priya one"},
                         {"start": 20.5, "end": 29.5, "speaker_id": "W1.2-S01", "text": "priya two"},
                         {"start": 30.5, "end": 39.5, "speaker_id": "W1.2-S02", "text": "alan two"}]})  # fmt: skip

    stt, _ = sidecar(handler)
    buf = io.BytesIO()
    sf.write(buf, pcm, SR, format="FLAC")
    from omi_notes.providers import SttRequest

    response = stt.transcribe(SttRequest(flac=buf.getvalue(), duration=40.0, blocks=[(0.0, 40.0)], language="en", keyterms=[]))
    utterances = response["results"]["utterances"]
    assert [round(u["start"], 1) for u in utterances] == [0.5, 10.5, 20.5, 30.5], "times stay where they were"
    assert response["omi_notes"]["pieces"] == 2
    linked = link(response, pcm, FakeEmbedder())
    speakers = [u["speaker"] for u in linked["results"]["utterances"]]
    assert speakers[0] == speakers[3] and speakers[1] == speakers[2] and speakers[0] != speakers[1]


def compressed(k: int, dim: int = 16) -> list[float]:
    """Voices that share a large common part (room, microphone): raw cosines between people ~0.98."""
    v = np.zeros(dim)
    v[0] = 1.0
    v[1 + k] = 0.15
    return list(v / np.linalg.norm(v))


def test_voices_that_all_sound_alike_raw_are_linked_once_centred_on_the_conversation():
    # three pieces, the same two people (codes 1 and 2) in each: raw cosines are all ~0.98, so no raw link is
    # clear; centred on the conversation's own mean they separate
    embedder = CodedEmbedder({1: compressed(0), 2: compressed(1)})
    pcm = np.concatenate([np.full(10 * SR, v, np.int16) for v in (1, 2, 2, 1, 1, 2)])
    response = pieces_response([(0, 10, 0), (10, 20, 1), (20, 30, 2), (30, 40, 3), (40, 50, 4), (50, 60, 5)], [0.0, 20.0, 40.0])
    raw = link(response, pcm, embedder, centre_min=99)
    assert raw["omi_notes"]["speakers_linked"]["speakers"] > 2
    out = link(response, pcm, embedder)
    speakers = [u["speaker"] for u in out["results"]["utterances"]]
    assert speakers[0] == speakers[3] == speakers[4] and speakers[1] == speakers[2] == speakers[5] and speakers[0] != speakers[1]
    assert out["omi_notes"]["speakers_linked"]["space"] == "conversation"


def test_a_few_labels_are_centred_on_the_background_voice():
    embedder = CodedEmbedder({1: compressed(0), 2: compressed(1)})
    pcm = np.concatenate([np.full(10 * SR, v, np.int16) for v in (1, 2, 2, 1)])
    response = pieces_response([(0, 10, 0), (10, 20, 1), (20, 30, 2), (30, 40, 3)], [0.0, 20.0])
    background = np.eye(16)[0]  # the common part every voice shares
    out = link(response, pcm, embedder, background=background)
    assert [u["speaker"] for u in out["results"]["utterances"]] == [0, 1, 1, 0]
    assert out["omi_notes"]["speakers_linked"]["space"] == "background"


def test_two_alike_labels_inside_one_piece_raise_the_bar_for_every_link():
    # piece 0 holds the same voice twice (the provider over-split it): that "different people" pair is as
    # close as voices get, so nothing in this conversation is close enough to link
    embedder = CodedEmbedder({1: compressed(0), 2: compressed(1), 3: compressed(2)})
    pcm = np.concatenate([np.full(10 * SR, v, np.int16) for v in (1, 1, 2, 1, 2, 3)])
    response = pieces_response([(0, 10, 0), (10, 20, 1), (20, 30, 2), (30, 40, 3), (40, 50, 4), (50, 60, 5)], [0.0, 20.0, 40.0])
    out = link(response, pcm, embedder)
    assert out["omi_notes"]["speakers_linked"]["speakers"] == 6


def unknown_tail(request, n):
    """MOSS stopped early: words after it come back UNKNOWN."""
    seconds = seconds_of(request)
    return httpx.Response(200, json={"language": "en", "segments": [
        {"start": 0.0, "end": seconds / 2, "speaker_id": "S01", "text": "attributed words"},
        {"start": seconds / 2, "end": seconds, "speaker_id": "UNKNOWN", "text": "nobody's words"}]})  # fmt: skip


def test_unattributed_words_are_kept_as_an_unknown_speaker_and_teach_no_voice(client, worker):
    stt, _ = sidecar(unknown_tail)
    worker.providers._local_stt = stt
    worker.providers._embedder = FakeEmbedder()
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    transcript = json.loads((worker.pipeline.conv_dir(row["id"]) / "transcript.json").read_text())
    assert row["status"] == "done", row["error"]
    assert [s["speaker"] for s in transcript["segments"]] == ["S1", "unknown"]
    assert "nobody's words" in transcript["segments"][1]["text"]
    assert set(transcript["speaker_clips"]) <= {"S1"}, "no voiceprint from unattributed speech"


def test_a_transcript_with_no_attributed_words_is_speakers_unknown_not_an_invented_speaker(client, worker):
    def all_unknown(request, n):
        return httpx.Response(200, json={"segments": [{"start": 0.0, "end": 3.0, "speaker_id": "UNKNOWN", "text": "words"}]})

    worker.providers._local_stt, _ = sidecar(all_unknown)
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert row["status"] == "failed" and row["error_kind"] == "speakers_unknown"


def test_audio_that_keeps_killing_the_sidecar_stops_waiting_and_counts_attempts(client, worker):
    state = {"down": False}

    def transport(request):
        if request.url.path == "/health":
            return httpx.Response(503 if state["down"] else 200, json={})
        state["down"] = True  # this audio takes the engine down; it restarts before the next look
        return httpx.Response(503, json={"detail": "transcription engine failed"})

    stt = LocalAsrStt("http://127.0.0.1:18793/v1", transport=httpx.MockTransport(transport))
    stt.HEALTH_TTL = 0.0
    worker.providers._local_stt = stt
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    for k in range(6):
        state["down"] = False
        worker.pipeline._local_successes += 1  # other conversations are transcribed fine in between
        worker.tick(T0 + 400 + 120 * k)
    (row,) = convs(worker)
    assert row["attempts"] >= 1, "after a few engine deaths on the same audio it is this conversation's problem"


def test_an_engine_that_fails_on_everything_is_an_outage_not_this_conversations_failure(client, worker, settings):
    state = {"down": False}

    def transport(request):
        if request.url.path == "/health":
            return httpx.Response(503 if state["down"] else 200, json={})
        state["down"] = True
        return httpx.Response(503, json={"detail": "transcription engine failed"})

    stt = LocalAsrStt("http://127.0.0.1:18793/v1", transport=httpx.MockTransport(transport))
    stt.HEALTH_TTL = 0.0
    worker.providers._local_stt = stt
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    for k in range(6):  # nothing succeeds anywhere in between
        state["down"] = False
        worker.tick(T0 + 400 + 120 * k)
    (row,) = convs(worker)
    assert row["attempts"] == 0 and row["error_kind"] == "stt_unavailable"
    alert = json.loads((settings.logs_dir / "alerts" / "local-transcription.json").read_text())
    assert alert["state"] == "failing"


def test_a_rerun_keeps_the_speaker_links_it_made_even_if_other_voices_changed(client, worker):
    pcm_voice = np.concatenate([np.zeros(SR, np.int16), voice(6, ALAN, 7), np.zeros(SR, np.int16), voice(6, PRIYA, 8), np.zeros(2 * SR, np.int16)])
    stt, seen = sidecar(moss_like, max_seconds=5)
    worker.providers._local_stt = stt
    worker.providers._embedder = FakeEmbedder()
    replay(client, pcm_voice)
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    conv_dir = worker.pipeline.conv_dir(row["id"])
    first = json.loads((conv_dir / "transcript.json").read_text())["segments"]
    assert list(conv_dir.glob("links-v1-*.json")), "the linking decision is stored next to the STT result"
    worker.pipeline._background_voice = lambda conv_id, embedder: np.eye(32)[3]  # the other voices changed meanwhile
    (conv_dir / "transcript.json").unlink()
    worker.pipeline._set(row["id"], status="closed")
    worker.tick(T0 + 500)
    again = json.loads((conv_dir / "transcript.json").read_text())["segments"]
    assert [s["speaker"] for s in again] == [s["speaker"] for s in first] and len(seen) >= 2


def test_stale_health_reads_as_unknown(worker, settings):
    from omi_notes import views

    configured = settings.model_copy(update={"stt_local_url": "http://127.0.0.1:18793/v1"})
    worker.providers._local_stt, _ = sidecar()
    worker.pipeline.watch_local_stt(T0)
    assert views.local_transcription(worker.db, configured, T0 + 10)["available"] is True
    assert views.local_transcription(worker.db, configured, T0 + 600)["available"] is None, "nobody has looked for 10 min"


def test_without_a_voice_model_the_unlinked_result_is_kept_too(client, worker):
    stt, _ = sidecar(moss_like, max_seconds=5)
    worker.providers._local_stt = stt
    worker.providers._embedder = False
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(12, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    assert list(worker.pipeline.conv_dir(row["id"]).glob("links-v1-*.json")), "installing a model later must not relink it"


def test_a_new_conversation_is_transcribed_before_an_old_ones_reprocess(client, worker):
    order = []

    def recording(request, n):
        order.append(seconds_of(request))
        return moss_like(request, n)

    worker.providers._local_stt, _ = sidecar(recording)
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (old,) = convs(worker)
    worker.db.execute("UPDATE conversations SET reprocess_request = reprocess_request + 1, force_restt = 1 WHERE id=?", (old["id"],))
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(4, PRIYA, 9), np.zeros(2 * SR, np.int16)]), start=STARTED + timedelta(seconds=1000))
    order.clear()
    worker.tick(T0 + 1400)
    assert len(order) == 2 and order[0] < order[1], "the new (shorter) recording went first"


def overlap_sidecar(voices_at, full_pcm, max_seconds, overlap):
    """A sidecar whose labels restart per request but name the same voice in the same place (numbered by
    first appearance in each request, so the numbering differs between requests). It finds where each
    request lies in the full audio by its samples (FLAC is lossless)."""

    def offset_of(req: np.ndarray) -> float:
        k = int(np.flatnonzero(req)[0])
        window = req[k : k + 4000]
        hits = [i for i in np.flatnonzero(full_pcm == window[0]) if np.array_equal(full_pcm[i : i + len(window)], window)]
        return (hits[0] - k) / SR

    def handler(request, n):
        req = sf.read(io.BytesIO(form(request)["file"][0][2]), dtype="int16")[0]
        start, seconds = offset_of(req), len(req) / SR
        segments, names = [], {}
        for a, b, who in voices_at:
            lo, hi = max(a, start), min(b, start + seconds)
            if hi - lo > 0.3:
                names.setdefault(who, f"S{len(names) + 1:02d}")
                segments.append({"start": lo - start, "end": hi - start, "speaker_id": names[who], "text": f"{who}@{a:.0f}"})
        return httpx.Response(200, json={"segments": segments})

    stt, seen = sidecar(handler, max_seconds=max_seconds)
    stt.overlap_seconds = overlap
    return stt, seen


def test_overlapping_requests_anchor_the_same_speech_heard_twice_without_voiceprints():
    from omi_notes.providers import SttRequest

    # alternating A/B turns of 8 s with 1 s pauses, 60 s; requests of at most 30 s overlapping by 2 x 4 s
    turns, t, who = [], 0.0, "A"
    while t < 58:
        turns.append((t, min(t + 8, 60.0), who))
        t, who = t + 9, "B" if who == "A" else "A"
    pcm = np.zeros(60 * SR, np.int16)
    for a, b, w in turns:
        pcm[int(a * SR) : int(b * SR)] = voice(b - a, ALAN if w == "A" else PRIYA, int(a))[: int(b * SR) - int(a * SR)]
    buf = io.BytesIO()
    sf.write(buf, pcm, SR, format="FLAC")
    stt, seen = overlap_sidecar(turns, pcm, max_seconds=30, overlap=4)
    request = SttRequest(flac=buf.getvalue(), duration=60.0, blocks=[(a, b) for a, b, _ in turns], language="en", keyterms=[])
    response = stt.transcribe(request)
    meta = response["omi_notes"]
    assert len(seen) >= 3 and meta["anchors"], "the shared stretch ties labels of neighbouring requests"
    kept = sorted((u["start"], u["end"]) for u in response["results"]["utterances"])
    assert all(b[0] >= a[1] - 0.05 for a, b in zip(kept, kept[1:])), f"speech in the shared stretch is kept once: {kept}"
    for a, b, _ in turns:  # and none of it is lost
        assert sum(max(0.0, min(b, y) - max(a, x)) for x, y in kept) >= (b - a) - 0.05, (a, b, kept)

    class Blind:  # no usable voiceprint at all: anchors alone must carry the identities
        def embed(self, pcm):
            raise ValueError("too short")

    out = link(response, pcm, Blind())
    by_voice = {}
    for u in out["results"]["utterances"]:
        by_voice.setdefault(u["transcript"].split("@")[0], set()).add(u["speaker"])
    assert all(len(v) == 1 for v in by_voice.values()) and by_voice["A"] != by_voice["B"], by_voice


def test_an_unconfirmed_but_likely_speaker_is_shown_as_possibly_that_person():
    from omi_notes.notes.render import speaker_label

    assert speaker_label("S2", None, {}, {"S2": "Alan"}, "zh") == "Speaker 2 (可能是 Alan)"
    assert speaker_label("S2", None, {}, {"S2": "Alan"}, "en") == "Speaker 2 (possibly Alan)"
    assert speaker_label("S2", None, {"S2": "Priya"}, {"S2": "Alan"}, "en") == "Priya", "a recognized name wins"


def test_the_summary_is_told_who_a_speaker_may_be():
    from zoneinfo import ZoneInfo

    from omi_notes.pipeline import prompt

    text = prompt.build_user_message(segments=[{"start": T0, "end": T0 + 2, "speaker": "S2", "text": "I'll send it"}],
                                     start=T0, end=T0 + 2, tz=ZoneInfo("UTC"), timezone_name="UTC", language="en",
                                     owner_name="Alan", bookmarks=[], provisional=False, audio_gaps=[], now=T0,
                                     speaker_names={}, possible_names={"S2": ("Alan", True)})  # fmt: skip
    assert "S2 may be the owner (Alan)" in text
    assert "never in owner, owner_name or speaker_names" in text, "a guess must not become an identity field"


def test_possible_names_go_to_the_closest_unnamed_label_of_a_known_voice_only():
    from omi_notes.pipeline.conversations import possible_names

    background = np.eye(8)[0]
    cents = {"p-alan": np.eye(8)[1], "p-priya": np.eye(8)[2]}
    voices = {"S1": background * 2 + np.eye(8)[1], "S2": background * 2 + np.eye(8)[1] + 0.3 * np.eye(8)[3], "S3": background * 2 + np.eye(8)[5]}
    out = possible_names(voices, {}, cents, background=background)
    assert out == {"S1": "p-alan"}, "the closest unnamed label only; an unlike voice gets nothing"
    assert possible_names(voices, {"S4": {"person_id": "p-alan"}}, cents, background=background) == {}, "already named here"


def utt(a, b, speaker, text="x"):
    return {"start": a, "end": b, "speaker": speaker, "transcript": text}


def test_the_seam_between_requests_keeps_speech_once_even_when_their_timings_disagree():
    from omi_notes.providers.local_asr import seam

    for left, right in (([utt(9, 12, 0, "phrase")], [utt(8, 11, 1, "phrase")]), ([utt(8, 11, 0, "phrase")], [utt(9, 12, 1, "phrase")])):
        s = seam(left, right, 6.0, 14.0)
        kept = [u for u in left if (u["start"] + u["end"]) / 2 < s] + [u for u in right if (u["start"] + u["end"]) / 2 >= s]
        assert [u["transcript"] for u in kept] == ["phrase"], (left, right, s)


def test_anchors_need_most_of_both_labels_speech_and_ignore_simultaneous_talk():
    from omi_notes.providers.local_asr import anchors

    assert anchors([utt(0, 40, 0)], [utt(10, 12, 5)], 0, 40) == [], "a 2 s backchannel is not 40 s of speech"
    assert anchors([utt(0, 40, 0)], [utt(0, 40, 5)], 0, 40) == [[0, 5]]
    both = anchors([utt(0, 20, 0), utt(0, 20, 1)], [utt(0, 20, 5), utt(0, 20, 6)], 0, 20)
    assert both == [], "two people talking at once tie every pairing: no anchor"


def test_a_stored_sidecar_result_with_older_request_settings_is_reused_not_retranscribed(client, worker):
    stt, seen = sidecar(moss_like)
    worker.providers._local_stt = stt
    worker.providers._embedder = FakeEmbedder()
    replay(client, np.concatenate([np.zeros(SR, np.int16), voice(8, ALAN, 7), np.zeros(2 * SR, np.int16)]))
    worker.tick(T0 + 400)
    (row,) = convs(worker)
    ref = row["stt_ref"]
    other, seen2 = sidecar(moss_like, max_seconds=600)  # different request settings: a different cache tag
    worker.providers._local_stt = other
    (worker.pipeline.conv_dir(row["id"]) / "transcript.json").unlink()
    worker.pipeline._set(row["id"], status="closed")
    worker.tick(T0 + 500)
    (row,) = convs(worker)
    assert row["status"] == "done" and row["stt_ref"] == ref and not seen2


def test_a_voice_equally_close_to_two_people_of_one_window_joins_neither():
    a, b = [1.0, 0.0, 0.0], [0.5, float(np.sqrt(0.75)), 0.0]
    c = list(np.add(a, b) / np.linalg.norm(np.add(a, b)))
    embedder = CodedEmbedder({1: a, 2: b, 3: c})
    pcm = np.concatenate([np.full(10 * SR, v, np.int16) for v in (1, 2, 3)])
    response = pieces_response([(0, 10, 0), (10, 20, 1), (20, 30, 2)], [0.0, 20.0])
    out = link(response, pcm, embedder)
    assert out["omi_notes"]["speakers_linked"]["speakers"] == 3


def test_engine_deaths_count_once_the_engine_worked_for_others_even_in_one_batch(worker):
    pipeline = worker.pipeline
    counts = []
    for _ in range(3):
        counts.append(pipeline._engine_died("c1", "sha", T0))
        pipeline._local_successes += 1  # another conversation transcribed in the same batch
    assert counts == [0, 1, 2]


def test_a_possible_name_is_withheld_when_the_nearest_person_is_already_named():
    from omi_notes.pipeline.conversations import possible_names

    background = np.eye(8)[0]
    cents = {"p-alan": np.eye(8)[1], "p-priya": np.eye(8)[2]}
    out = possible_names({"S2": background * 2 + np.eye(8)[1]}, {"S1": {"person_id": "p-alan"}}, cents, background=background)
    assert out == {}, "the voice is Alan's: not suggested as the runner-up"


def test_possible_names_are_sanitized_like_names():
    from zoneinfo import ZoneInfo

    from omi_notes.notes.render import NoteData, sanitized

    d = sanitized(NoteData(id="x", status="completed", start=T0, end=T0 + 1, tz=ZoneInfo("UTC"), speech_seconds=1.0, segments=[], possible_names={"S2": "A <!-- my-notes:start -->\n[[B]]"}))
    assert "<!--" not in d.possible_names["S2"] and "\n" not in d.possible_names["S2"] and "[[" not in d.possible_names["S2"]


def test_without_a_voice_model_overlap_anchors_still_join_labels():
    response = {"results": {"channels": [{}], "utterances": [utt(0, 10, 0), utt(10, 20, 1), utt(20, 30, 2)]},
                "omi_notes": {"pieces": 2, "offsets": [0.0, 15.0], "groups": [[0, 0], [1, 1], [2, 1]], "anchors": [[0, 2]]}}
    out = link(response, np.zeros(30 * SR, np.int16), None)
    speakers = [u["speaker"] for u in out["results"]["utterances"]]
    assert speakers[0] == speakers[2] != speakers[1]


def test_without_a_shared_pause_a_longer_phrase_is_not_dropped_for_a_shorter_one():
    stt, _ = sidecar()

    def fake_parts(offset, part):  # left request [0, 12] and right request [8, 20]; no pause in [8, 12]
        if offset == 0.0:
            utts = [{"start": 0.0, "end": 8.0, "speaker": 0, "transcript": "first part"},
                    {"start": 8.0, "end": 12.0, "speaker": 0, "transcript": "please turn left now"}]
        else:
            utts = [{"start": 2.0, "end": 4.0, "speaker": 0, "transcript": "now"},
                    {"start": 4.0, "end": 12.0, "speaker": 0, "transcript": "then straight on"}]
        return [(offset, {"results": {"channels": [{}], "utterances": utts}})]

    stt._transcribe_part = fake_parts
    stt.max_seconds, stt.overlap_seconds = 16.0, 2.0
    request = audio_with_blocks([20])
    import omi_notes.providers.local_asr as la

    original = la.split_points
    la.split_points = lambda request, max_seconds: [(10.0, True)]
    try:
        text = " ".join(u["transcript"] for u in stt.transcribe(request)["results"]["utterances"])
    finally:
        la.split_points = original
    assert "please turn left" in text and "then straight on" in text, text


def test_one_outlier_pair_of_known_different_labels_does_not_block_every_join():
    from omi_notes.pipeline.speaker_links import bar

    apart = [0.1, -0.2, 0.25, 0.0, 0.3, 0.05, -0.1, 0.2, 0.15, 0.1, 0.77]  # one over-split window: 0.77
    assert bar(apart, centred=True) < 0.5, "the 90th percentile, not the outlier"
    assert bar([0.77], centred=True) == pytest.approx(0.82), "too few pairs to call it an outlier"
    assert bar([], centred=True) == pytest.approx(0.5), "nothing to calibrate against: cautious"
    assert bar([0.98], centred=False) == pytest.approx(1.03), "raw: above the closest known-different pair"


def test_a_phrase_counts_as_already_there_only_when_its_words_are():
    from omi_notes.providers.local_asr import _covered

    left = {"start": 8.0, "end": 12.0, "transcript": "Do not open the door."}
    assert not _covered(left, [{"start": 10.0, "end": 12.0, "transcript": "open the door"}]), "the negation would be lost"
    assert _covered({"start": 10.0, "end": 12.0, "transcript": "open the door"}, [left])
    assert _covered({"start": 1.0, "end": 2.0, "transcript": "开门"}, [{"start": 0.5, "end": 2.5, "transcript": "请不要开门。"}])
    assert not _covered({"start": 1.0, "end": 2.0, "transcript": "不要开门"}, [{"start": 0.5, "end": 2.5, "transcript": "请开门"}])


def test_hints_compare_voices_after_removing_what_every_recording_shares():
    from omi_notes.speakers.space import centred_centroids, score

    common = np.eye(16)[0] * 3.0  # every voice from this microphone shares this part
    alan = [common + np.eye(16)[1] + 0.1 * np.eye(16)[k] for k in range(4, 9)]
    gigi = [common + np.eye(16)[2] + 0.1 * np.eye(16)[k] for k in range(4, 9)]
    gigi.append(common + np.eye(16)[1])  # one of her samples is really Alan (a mislabel): the median ignores it
    background = np.eye(16)[0]
    cents = centred_centroids({"alan": alan, "gigi": gigi}, background)
    voice = common + np.eye(16)[1] + 0.05 * np.eye(16)[9]
    assert score(voice, cents["alan"], background) > 0.8 > score(voice, cents["gigi"], background) + 0.5


def test_possible_names_use_the_centred_space_and_need_a_clear_winner():
    from omi_notes.pipeline.conversations import possible_names

    background = np.eye(8)[0]
    cents = {"p-alan": np.eye(8)[1], "p-gigi": np.eye(8)[2]}
    voices = {"S1": np.eye(8)[0] * 3 + np.eye(8)[1], "S2": np.eye(8)[0] * 3 + 0.5 * np.eye(8)[1] + 0.5 * np.eye(8)[2]}
    out = possible_names(voices, {}, cents, background=background)
    assert out == {"S1": "p-alan"}, "S2 is as much Gigi as Alan: no guess"
