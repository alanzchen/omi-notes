"""Conversation stages after close: audio → STT → relevance → LLM → markdown; plus stubs,
daily indexes and `_status.md`.

Every stage is idempotent; its results are permanent files in the conversation's vault directory
`_omi/conversations/YYYY-MM/<id>/` (docs/vault.md):
- `stt-<provider>-<model>-<lang>-<audio_sha16>[-<n>].json`: raw provider response (+ when)
- `diarization-<tag>-<audio_sha16>.json`: local speaker turns
- `transcript.json`: wall-clock segments and the audio time map (permanent: after raw retention
  it cannot be recomputed)
- `llm-<model>-p<PROMPT_VERSION>-<transcript_sha16>[-<n>].json`: structured notes (+ when/usage)
- `conversation.json`: decision / settings / render / failure blocks (`records.py`), written
  before the index is told, after the files it references.
Rendering is a pure function of the record and these files, so rebuilding makes zero provider
calls. Results no record references any more (after a forced reprocess) are deleted. A
conversation is advanced only under a durable claim, so two processes never work on the same one.
"""

from __future__ import annotations

import json
import logging
import re
import sqlite3
import time
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from ..audio.diarize import LocalDiarizer, Turn, local_diarization_status
from ..audio.timeline import CaptureTimeline, Piece
from ..db import Database
from ..envelope import OPUS_CODECS, parse_envelope
from ..ingest import seal_end_epoch
from ..notes import daily as daily_mod
from ..notes.render import NoteData, owner_display, render_note, render_stub, title_of
from ..notes.schema import NOTES_JSON_SCHEMA, ConversationNotes
from ..notes.status import StatusSnapshot, render_status
from ..notes.writer import (
    UserRegionError,
    conversation_relpath,
    discarded_relpath,
    extract_my_notes,
    generated_sha,
    link_target,
    read_note_id,
    remove,
    stub_relpath,
    with_suffix_id,
    write_if_changed,
)
from ..records import record_bytes, record_from_row, record_path
from ..providers import LlmProvider, LlmRequest, ProviderError, SttProvider, SttRequest
from ..settings import Settings
from ..spool import atomic_write_bytes
from ..util import canonical_json, sha256_hex
from ..speakers import match as speaker_match
from ..speakers.store import SpeakerStore, voices_name
from ..speakers.voices import cosine_distance, embed_voices, label_turns, select_clips, usable_spans
from ..vault import Vault
from . import prompt
from .relevance import deterministic_relevance
from .segmenter import RingCapture, ring_resolved_until
from .speakers import SpeakerResult, resolve_speakers
from .transcript import ConversationAudio, assemble, detected_language, merge_same_speaker, segments_from_deepgram

log = logging.getLogger(__name__)

MAX_ATTEMPTS = 6
CLAIM_TTL = 3600.0
SOURCE_PRIORITY = {"live_ble": 0, "wav_replay": 1, "device_ring": 2}
SOURCE_LABEL = {"live_ble": "live", "wav_replay": "replay", "device_ring": "offline"}
RULE_REASONS = {
    "empty_transcript": "no speech was transcribed",
    "filler_only": "only filler words",
    "mic_check": "microphone check",
    "no_content_words": "no content words",
}
PENDING = ("open", "closed", "transcribing", "summarizing")
BOOKMARK_REACH = 60.0
_PROMPT_IN_NAME = re.compile(r"-p(\d+)-[0-9a-f]{16}\.json$")


STATUS_INTERVAL = 60.0  # `_status.md` and stubs are rewritten at most once a minute
EDITED_RETRY = 600.0


class CacheMiss(RuntimeError):
    """`rebuild` needs a cached provider result that does not exist."""


class NoteEdited(RuntimeError):
    """The note was edited outside My Notes since we wrote it: the re-render is postponed."""


def backoff(attempts: int) -> float:
    return min(3600.0, 30.0 * 2 ** max(0, attempts - 1))


@dataclass
class Providers:
    """Lazily constructed so a missing key fails the conversation visibly instead of the server."""

    settings: Settings
    _stt: SttProvider | None = None
    _llm: LlmProvider | None = None
    _diarizer: object = None  # LocalDiarizer, or False once known to be unavailable
    _embedder: object = None  # speaker embedder, or False once known to be unavailable

    @property
    def stt(self) -> SttProvider:
        if self._stt is None:
            if self.settings.stt_provider == "fake":
                from ..providers.fake import FakeStt

                self._stt = FakeStt()
            elif self.settings.stt_provider == "openai":
                from ..providers.openai_stt import OpenAICompatStt

                self._stt = OpenAICompatStt(
                    self.settings.stt_base_url,
                    self.settings.stt_api_key,
                    self.settings.stt_model,
                    style=self.settings.stt_request_style,
                    max_request_seconds=self.settings.stt_max_request_seconds,
                )
            else:
                from ..providers.deepgram import DeepgramStt

                self._stt = DeepgramStt(self.settings.deepgram_api_key, self.settings.stt_model)
        return self._stt

    @property
    def local_diarization_problem(self) -> str | None:
        """None when local diarization can run, else why not."""
        return local_diarization_status(
            self.settings.diarization_segmentation_model, self.settings.diarization_embedding_model
        )

    @property
    def diarizer(self):
        """The local diarizer, or None when it is not installed (loaded once, on first use)."""
        if self._diarizer is None:
            problem = self.local_diarization_problem
            if problem:
                self._diarizer = False
            else:
                self._diarizer = LocalDiarizer(
                    self.settings.diarization_segmentation_model,
                    self.settings.diarization_embedding_model,
                    num_speakers=self.settings.diarization_num_speakers,
                    threshold=self.settings.diarization_threshold,
                )
        return self._diarizer or None

    @property
    def embedder(self):
        """The speaker embedder (WeSpeaker via sherpa-onnx), or None when not installed."""
        if self._embedder is None:
            from ..audio.embed import SherpaEmbedder, speaker_embedding_status

            problem = speaker_embedding_status(self.settings.speaker_model)
            try:
                self._embedder = False if problem else SherpaEmbedder(self.settings.speaker_model)
            except Exception:  # a broken model file must not stop transcription
                log.exception("could not load the speaker model %s", self.settings.speaker_model)
                self._embedder = False
        return self._embedder or None

    @property
    def llm(self) -> LlmProvider:
        if self._llm is None:
            if self.settings.llm_provider == "fake":
                from ..providers.fake import FakeLlm

                self._llm = FakeLlm()
            elif self.settings.llm_provider == "openai":
                from ..providers.openai_llm import OpenAICompatLlm

                self._llm = OpenAICompatLlm(
                    self.settings.llm_base_url,
                    self.settings.llm_api_key,
                    self.settings.llm_model,
                    json_mode=self.settings.llm_json_mode,
                    reasoning_effort=self.settings.llm_reasoning_effort,
                )
            else:
                from ..providers.anthropic_llm import AnthropicLlm

                self._llm = AnthropicLlm(
                    self.settings.anthropic_api_key, self.settings.llm_model, self.settings.llm_effort
                )
        return self._llm

    @property
    def stt_label(self) -> str:
        """What transcribes and where speaker labels come from, e.g.
        `openai/voxtral-mini-latest+local-diarization` (status page)."""
        if self.settings.stt_provider == "fake":
            return "fake/fake-stt"
        label = f"{self.settings.stt_provider}/{self.settings.stt_model}"
        mode = self.settings.stt_diarization
        if mode == "off":
            return label + "+no-diarization"
        if mode == "local" or (mode == "auto" and self.local_diarization_problem is None):
            return label + ("+local-diarization" if mode == "local" else "+local-diarization-fallback")
        return label

    @property
    def llm_model(self) -> str:
        return "fake-llm" if self.settings.llm_provider == "fake" else self.settings.llm_model


class ConversationPipeline:
    def __init__(self, settings: Settings, db: Database, providers: Providers, vad_label: str, vad_warning: str | None) -> None:
        self.settings = settings
        self.db = db
        self.vault = Vault.open(settings)
        self.speakers = SpeakerStore(self.vault, db, auto_assign_default=settings.speaker_auto_assign)
        self.operating = speaker_match.Operating(threshold=settings.speaker_match_threshold,
                                                 margin=settings.speaker_match_margin)  # fmt: skip
        self.providers = providers
        self.vad_label = vad_label
        self.vad_warning = vad_warning
        self._move_retries: dict[str, tuple[int, float]] = {}
        self._status_written: tuple[float, str] | None = None
        self._stub_written: dict[str, float] = {}

    # -- paths / days ----------------------------------------------------------------------------

    def conv_dir(self, conv_id: str) -> Path:
        return self.vault.conversation_dir(conv_id)

    def _local(self, epoch: float) -> datetime:
        return datetime.fromtimestamp(epoch, self.tz)

    def mark_day(self, epoch: float) -> None:
        """Queue the day's index for re-rendering (persisted: survives a crash)."""
        self.db.execute("INSERT OR IGNORE INTO dirty_days (day) VALUES (?)", (self._local(epoch).date().isoformat(),))

    def reconcile_days(self) -> None:
        """Queue every day that has conversations (after a restart indexes may be stale)."""
        days = {self._local(r["start"]).date().isoformat() for r in self.db.query("SELECT start FROM conversations")}
        self.db.conn().executemany("INSERT OR IGNORE INTO dirty_days (day) VALUES (?)", [(d,) for d in days])

    # -- claims ----------------------------------------------------------------------------------

    def claim(self, conv_id: str) -> str | None:
        token, wall = uuid.uuid4().hex, time.time()
        cur = self.db.execute(
            "UPDATE conversations SET claim_token=?, claim_expires=? WHERE id=? AND (claim_token IS NULL OR claim_expires < ?)",
            (token, wall + CLAIM_TTL, conv_id, wall),
        )
        return token if cur.rowcount == 1 else None

    def release(self, conv_id: str, token: str) -> None:
        self.db.execute(
            "UPDATE conversations SET claim_token=NULL, claim_expires=NULL WHERE id=? AND claim_token=?", (conv_id, token)
        )

    def release_all_claims(self) -> None:
        self.db.execute("UPDATE conversations SET claim_token=NULL, claim_expires=NULL WHERE claim_token IS NOT NULL")

    # -- scheduling ------------------------------------------------------------------------------

    def mark_stale_renders(self) -> int:
        """Notes rendered from other speaker labels than the current ones are re-rendered, however
        the labels changed (a correction during a render, a recovered file, a rebuild)."""
        return self.db.execute(
            """UPDATE conversations SET needs_render=1, next_attempt_at=NULL
               WHERE note_path IS NOT NULL AND needs_render=0 AND frozen=0 AND status IN ('done','discarded','failed')
                 AND COALESCE(rendered_speakers_revision, 0) <> speakers_revision"""
        ).rowcount

    def run(self, now: float, *, limit: int = 20) -> int:
        self.mark_stale_renders()
        rows = self.db.query(
            """SELECT id FROM conversations
               WHERE ((status IN ('closed','transcribing','summarizing') OR (needs_render=1 AND status IN ('done','discarded','failed')))
                      AND (next_attempt_at IS NULL OR next_attempt_at <= ?))
                  OR (reprocess_request > reprocess_handled AND status <> 'open')
               ORDER BY start LIMIT ?""",
            (now, limit),
        )
        for row in rows:
            try:
                self.advance(row["id"], now)
            except Exception as exc:  # one bad row must never stall the others
                log.exception("conversation %s could not be advanced", row["id"])
                current = self._row(row["id"])
                self._set(row["id"], attempts=current["attempts"] + 1, error=f"{type(exc).__name__}: {exc}"[:500],
                          next_attempt_at=now + backoff(current["attempts"] + 1))  # fmt: skip
        return len(rows)

    def advance(self, conv_id: str, now: float) -> None:
        token = self.claim(conv_id)
        if token is None:
            return  # another process is working on it
        try:
            self._advance(conv_id, now)
        finally:
            self.release(conv_id, token)

    def _advance(self, conv_id: str, now: float) -> None:
        row = self._row(conv_id)
        if row["reprocess_request"] > row["reprocess_handled"] and row["status"] != "open":
            row = self._consume_reprocess(row)
        if row["status"] not in ("closed", "transcribing", "summarizing"):
            if row["needs_render"]:
                self._rerender(row, now)
            return
        stage = "transcribing" if row["status"] in ("closed", "transcribing") else "summarizing"
        try:
            if stage == "transcribing":
                self._set(conv_id, status="transcribing", updated_at=now)
                self.transcribe(conv_id, now)
                stage = "summarizing"
            self.summarize_and_render(conv_id, now)
        except ProviderError as exc:
            self._fail(conv_id, stage, exc, now)
        except CacheMiss as exc:
            log.warning("conversation %s: %s; transcribing again (cached audio/STT are reused)", conv_id, exc)
            self._set(conv_id, status="closed", updated_at=now)
        except UserRegionError as exc:
            self._fail(conv_id, stage, ProviderError(str(exc), kind="notes"), now)
        except NoteEdited:
            self._set(conv_id, next_attempt_at=now + EDITED_RETRY)
        except Exception as exc:  # a bug or unexpected I/O error must not stop the worker loop
            log.exception("conversation %s failed in %s", conv_id, stage)
            self._fail(conv_id, stage, ProviderError(f"{type(exc).__name__}: {exc}"), now)

    def _consume_reprocess(self, row: sqlite3.Row) -> sqlite3.Row:
        """Apply `reprocess` requests (a counter plus accumulated force flags, stored apart from the
        execution status). Nothing is deleted: results a forced stage must not reuse are listed
        (`skip_stt`/`skip_llm`), so it writes new result files; the old ones are removed once no
        record references them. The compare-and-swap on the counter means a request arriving
        meanwhile is never lost: it is applied too, or left pending for the next pass."""
        while True:
            if row["enrollment_id"]:  # a voice-enrollment reading is never transcribed: nothing to redo
                cur = self.db.execute(
                    "UPDATE conversations SET reprocess_handled=?, force_restt=0, force_llm=0 WHERE id=? AND reprocess_request=?",
                    (row["reprocess_request"], row["id"], row["reprocess_request"]),
                )
                row = self._row(row["id"])
                if cur.rowcount == 1:
                    return row
                continue
            conv_dir = self.conv_dir(row["id"])
            skip_stt = json.dumps(sorted(p.name for p in conv_dir.glob("stt-*.json"))) if row["force_restt"] else row["skip_stt"]
            skip_llm = json.dumps(sorted(p.name for p in conv_dir.glob("llm-*.json"))) if row["force_llm"] else row["skip_llm"]
            transcript = (conv_dir / "transcript.json").exists()
            status = "summarizing" if transcript and not row["force_restt"] else "closed"
            cur = self.db.execute(
                """UPDATE conversations SET reprocess_handled=?, force_restt=0, force_llm=0, skip_stt=?, skip_llm=?,
                       status=?, attempts=0, error=NULL, error_kind=NULL, failed_stage=NULL, next_attempt_at=NULL, edited=0
                   WHERE id=? AND reprocess_request=?""",
                (row["reprocess_request"], skip_stt, skip_llm, status, row["id"], row["reprocess_request"]),
            )
            row = self._row(row["id"])
            if cur.rowcount == 1:
                self._sync_record(row)  # a cleared failure is permanent news
                return row

    def _rerender(self, row: sqlite3.Row, now: float) -> None:
        """Re-render a finished note (late bookmark/double tap, rebuild) from caches only. The
        flag is cleared by a successful write; failures are retried with backoff."""
        error = (row["error"] or "summary failed") if row["status"] == "failed" else None
        try:
            self.summarize_and_render(row["id"], now, cache_only=True, summary_error=error)
        except CacheMiss as exc:
            log.warning("conversation %s: nothing cached to re-render (%s)", row["id"], exc)
            self._set(row["id"], needs_render=0, rendered_speakers_revision=row["speakers_revision"])
        except NoteEdited:
            self._set(row["id"], next_attempt_at=now + EDITED_RETRY)
        except (OSError, UserRegionError) as exc:
            attempts = row["attempts"] + 1
            log.warning("re-rendering %s failed (attempt %d): %s", row["id"], attempts, exc)
            self._set(row["id"], attempts=attempts, error=str(exc)[:500],
                      error_kind="notes" if isinstance(exc, UserRegionError) else "io",
                      next_attempt_at=now + backoff(attempts))  # fmt: skip

    def _fail(self, conv_id: str, stage: str, exc: ProviderError, now: float) -> None:
        row = self._row(conv_id)
        attempts = row["attempts"] + 1
        if exc.terminal or attempts >= MAX_ATTEMPTS:
            log.error("conversation %s failed permanently in %s: %s", conv_id, stage, exc)
            self._commit(conv_id, status="failed", failed_stage=stage, attempts=attempts, error=str(exc)[:500],
                         error_kind=exc.kind, next_attempt_at=None, updated_at=now)  # fmt: skip
            if stage == "summarizing":
                # The transcript is safe; publish it now rather than waiting for the LLM.
                try:
                    self.summarize_and_render(conv_id, now, summary_error=str(exc)[:200])
                except Exception:
                    log.exception("could not render transcript-only note for %s", conv_id)
        else:
            log.warning("conversation %s: %s (attempt %d, retrying)", conv_id, exc, attempts)
            self._set(conv_id, attempts=attempts, error=str(exc)[:500], error_kind=exc.kind,
                      next_attempt_at=now + backoff(attempts), updated_at=now)  # fmt: skip

    # -- audio + STT -----------------------------------------------------------------------------

    def conversation_audio(self, row: sqlite3.Row) -> ConversationAudio:
        """Re-decode exactly the chunks under this conversation's speech blocks."""
        blocks = [tuple(b) for b in json.loads(row["blocks_json"])]
        if not blocks:
            return assemble([], [])
        lo, hi = min(b[0] for b in blocks), max(b[1] for b in blocks)
        chunks = self.db.query(
            """SELECT capture_id, chunk_sequence FROM chunks
               WHERE device_id=? AND status='processed' AND audio_start IS NOT NULL
                 AND audio_start <= ? AND audio_end >= ? ORDER BY capture_id, chunk_sequence""",
            (row["device_id"], hi + 1, lo - 1),
        )
        by_capture: dict[str, list[int]] = {}
        for c in chunks:
            by_capture.setdefault(c["capture_id"], []).append(c["chunk_sequence"])
        sources: list[tuple[int, Piece]] = []
        for capture_id, seqs in by_capture.items():
            capture = self.db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
            for piece in self.decode_range(capture, min(seqs), max(seqs)):
                for a, b in blocks:
                    lo_t, hi_t = max(a, piece.start), min(b, piece.end)
                    if hi_t > lo_t:
                        i0 = round((lo_t - piece.start) * 16000)
                        i1 = round((hi_t - piece.start) * 16000)
                        sub = piece.pcm[i0:i1]
                        if len(sub):
                            sources.append((SOURCE_PRIORITY.get(capture["source"], 3), Piece(piece.start + i0 / 16000, sub)))
        return assemble(blocks, sources)

    def decode_range(self, capture: sqlite3.Row, first: int, last: int) -> list[Piece]:
        carry = None
        if first > 0:
            prev = self.db.one(
                "SELECT carry_json FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture["capture_id"], first - 1)
            )
            carry = json.loads(prev["carry_json"]) if prev and prev["carry_json"] else None
        timeline = CaptureTimeline(OPUS_CODECS.get(capture["codec_id"] or 21, 320), carry)
        pieces: list[Piece] = []
        for seq in range(first, last + 1):
            chunk = self.db.one("SELECT * FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture["capture_id"], seq))
            if chunk is None or chunk["raw_deleted"]:
                raise ProviderError(f"raw audio for chunk {seq} of {capture['capture_id']} is gone", terminal=True, kind="audio")
            env = parse_envelope((self.vault.root / chunk["path"]).read_bytes())
            timeline.ring_seen = ring_seen_check(self.db, capture["device_id"], capture["capture_id"], seq)
            final = bool(json.loads(chunk["stats_json"] or "{}").get("final"))
            pieces.extend(timeline.decode_chunk(env, final=final).pieces)
        return pieces

    def transcribe(self, conv_id: str, now: float) -> None:
        row = self._row(conv_id)
        if row["enrollment_id"]:
            raise ProviderError("voice-enrollment audio is never transcribed", terminal=True, kind="enrollment")
        audio = self.conversation_audio(row)
        if len(audio.pcm) == 0:
            raise ProviderError("no decodable audio under this conversation's speech", terminal=True, kind="audio")
        audio_sha = sha256_hex(audio.pcm.tobytes() + canonical_json([list(b) for b in audio.blocks_out]).encode())
        stt = self.providers.stt
        tag = f"-{_slug(stt.cache_tag)}" if getattr(stt, "cache_tag", "") else ""
        base = f"stt-{stt.name}{tag}-{_slug(stt.model)}-{_slug(self.settings.stt_language)}-{audio_sha[:16]}"
        conv_dir = self.conv_dir(conv_id)
        name = _reusable(conv_dir, base, row["stt_ref"], row["skip_stt"])
        path = conv_dir / name
        if path.exists():
            cached = json.loads(path.read_text())
        else:
            response = stt.transcribe(
                SttRequest(flac=audio.flac(), duration=audio.duration, blocks=audio.blocks_out,
                           language=self.settings.stt_language, keyterms=self.settings.keyterms)
            )  # fmt: skip
            cached = {"created_at": now, "provider": stt.name, "model": stt.model, "response": response}
            atomic_write_bytes(path, json.dumps(cached).encode())
        speakers = self._speakers(conv_id, cached["response"], audio, audio_sha)
        segments = merge_same_speaker(segments_from_deepgram(speakers.response, audio.timemap))
        clips = select_clips(label_turns(speakers.response), usable_spans(audio.blocks_out, self._losses_out(row, audio)))
        language = self.settings.stt_language
        if language == "multi":
            language = detected_language(cached["response"]) or language
        transcript = {
            "segments": segments,
            "language": language,
            "audio_sha": audio_sha,
            "stt": f"{cached['provider']}/{cached['model']}" + ("+local-diarization" if speakers.source == "local" else ""),
            "speaker_source": speakers.source,
            "speaker_labels_consistent": speakers.consistent,
            "stt_file": name,
            "transcribed_at": cached["created_at"],
            "submitted_seconds": round(audio.duration, 3),
            "missing": audio.missing,
            # clean per-label clips (submitted-audio seconds) for voices and the app's "who is this?"
            "speaker_clips": {label: [[c.start, c.end] for c in cs] for label, cs in clips.items()},
            "timemap": [[m.out_start, m.wall_start, m.duration] for m in audio.timemap],
        }
        atomic_write_bytes(self.conv_dir(conv_id) / "transcript.json", json.dumps(transcript, indent=1).encode())
        self.identify(conv_id, audio, audio_sha, clips, sha256_hex(canonical_json(segments).encode()),
                      {seg["speaker"] for seg in segments}, consistent=speakers.consistent)  # fmt: skip
        self._set(conv_id, status="summarizing", audio_sha=audio_sha, stt_ref=name, language=language,
                  transcript_sha=sha256_hex(canonical_json(segments).encode()), attempts=0, error=None,
                  error_kind=None, next_attempt_at=None, updated_at=now, skip_stt=None)  # fmt: skip

    def _losses_out(self, row, audio: ConversationAudio) -> list[tuple[float, float]]:
        """Known losses (concealed audio) inside this conversation, on the submitted-audio clock."""
        losses = self.db.query(
            "SELECT start, end FROM losses WHERE device_id=? AND end >= ? AND start <= ?", (row["device_id"], row["start"], row["end"])
        )
        out = []
        for m in audio.timemap:
            for loss in losses:
                lo, hi = max(loss["start"], m.wall_start), min(loss["end"], m.wall_start + m.duration)
                if hi > lo:
                    out.append((m.out_start + lo - m.wall_start, m.out_start + hi - m.wall_start))
        return out

    def identify(self, conv_id: str, audio: ConversationAudio | None, audio_sha: str | None, clips: dict,
                 transcript_sha: str, labels: set[str], *, consistent: bool = True) -> None:  # fmt: skip
        """Voices stage: label voiceprints while the PCM is in memory, then the pure assignment.
        Voices are inert until someone is enrolled or named and skipped without a speaker model;
        label states always move to a new transcript (`_carry_over`), voices or not."""
        embedder = self.providers.embedder
        voices, name, fresh = None, None, False
        if embedder is not None and consistent and audio_sha and self.speakers.any_samples():
            # keyed by everything the voices depend on: a new transcript may number the voices differently
            name = voices_name(embedder, audio_sha, transcript_sha)
            fresh = not (self.conv_dir(conv_id) / name).exists()
            if fresh and audio is not None and clips:
                voices = embed_voices(clips, audio.pcm, embedder)  # outside the lock: the slow part
            elif fresh:
                name, fresh = None, False  # no audio in hand (a recovery path): nothing to compute
        with self.speakers.lock:
            self.speakers.sync_labels_index(conv_id)  # start from the file's states, not a stale index
            stored = self.speakers.labels(conv_id)
            previous = self.speakers.labels_transcript(conv_id)
            moved = previous not in (None, transcript_sha)
            # what the stored states were made against (speakers.json names it), never the new file
            old_voices = self.speakers.voices_of_labels(conv_id, previous, not_file=name) if moved else {}
            if name is not None and not fresh:  # a retried stage: finish it with the stored voices
                voices = self.speakers.read_voices(conv_id, name)
            current = self._carry_over(stored, old_voices, voices, labels, self.speakers.had_forgotten(conv_id)) if moved else stored
            states = current
            if voices is not None:
                samples = self.speakers.samples(embedder.model, embedder.model_sha)  # as of now, not before embedding
                if samples:
                    states = speaker_match.assign(voices, current, speaker_match.build_models(samples, self.operating),
                                                  auto_assign=self.speakers.settings()["auto_assign"], op=self.operating)  # fmt: skip
            if fresh:
                keep = self.speakers.vector_labels(states, set(voices), raw=True)
                self.speakers.write_voices(conv_id, name, embedder.model, embedder.model_sha, voices, keep)
            elif name is not None:  # written for states that never committed: apply the rule to these
                self.speakers.index_voices(conv_id, name)
                raw = self.speakers.raw_available(self._row(conv_id))
                self.speakers.prune_vectors(conv_id, self.speakers.vector_labels(states, set(voices), raw=raw))
            if moved or name is not None or self.speakers.persisted(states) != self.speakers.persisted(stored):
                # one commit: the states, their transcript, and the voices file they were made against
                self.speakers.write_labels(conv_id, states, transcript_sha=transcript_sha, voices=name)
            if moved or name is not None:
                self.speakers.remove_other_voices(conv_id, name)  # nothing depends on the others now

    def move_labels(self, conv_id: str, transcript: dict) -> None:
        """Label states made for another transcript (recovery after a crash between writing the
        transcript and its voices stage) are moved before anything uses their names."""
        segments = transcript.get("segments") or []
        sha = sha256_hex(canonical_json(segments).encode())
        if self.speakers.labels_transcript(conv_id) not in (None, sha):
            self.identify(conv_id, None, transcript.get("audio_sha"), {}, sha, {s["speaker"] for s in segments},
                          consistent=transcript.get("speaker_labels_consistent", True))  # fmt: skip

    def _carry_over(self, current: dict, old_voices: dict, new_voices: dict | None, labels: set[str],
                    had_forgotten: bool = False) -> dict:  # fmt: skip
        """Label states of the previous transcript that still apply. A state belongs to a voice,
        not a label number: it moves to the new label with the same voice (one-to-one, closest
        first, within SAME_VOICE); without a same voice to follow it is dropped. A forgotten voice
        has no vector to follow, so in a conversation where one was ever forgotten every new label
        that nothing carried over to may be it and is marked forgotten too."""
        pairs = sorted(
            (cosine_distance(old.vector, new.vector), old_label, new_label)
            for old_label, old in old_voices.items()
            if old.vector is not None and old_label in current and not current[old_label].get("forgotten")
            for new_label, new in (new_voices or {}).items() if new.vector is not None
        )  # fmt: skip
        out: dict[str, dict] = {}
        moved: set[str] = set()
        for distance, old_label, new_label in pairs:
            if distance >= speaker_match.SAME_VOICE:
                break
            if old_label not in moved and new_label not in out:
                moved.add(old_label)
                out[new_label] = current[old_label]
        if had_forgotten or any(state.get("forgotten") for state in current.values()):
            for label in labels | set(new_voices or {}):
                out.setdefault(label, {"forgotten": True})
        return out

    def sync_labels_everywhere(self) -> None:
        with self.speakers.lock:
            for r in self.db.query("SELECT id FROM conversations WHERE status <> 'open'"):
                self.speakers.sync_labels_index(r["id"])

    def finish_migrations(self) -> None:
        """Move every conversation's label states to its current transcript (a crash may have left
        some behind), so labels and voices agree."""
        with self.speakers.lock:
            for r in self.db.query("SELECT id FROM conversations WHERE status <> 'open' AND transcript_sha IS NOT NULL"):
                conv_dir = self.conv_dir(r["id"])
                if (conv_dir / "speakers.json").exists() and (conv_dir / "transcript.json").exists():
                    self.move_labels(r["id"], json.loads((conv_dir / "transcript.json").read_text()))

    def relabel(self, now: float) -> list[str]:
        """Re-run the pure assignment over stored voices after people/samples changed; notes whose
        names changed are re-rendered from cache (no provider call). Returns the conversations
        whose label assignments changed. Holds the speaker lock, so an API correction made
        meanwhile is never overwritten by states computed before it."""
        with self.speakers.lock:
            return self._relabel(now)

    def _relabel(self, now: float) -> list[str]:
        self.speakers.scan_people()
        # compared with what notes were last rendered with, not with the previous scan: another
        # caller (PUT /v1/people, GET /v1/people) may have scanned the change first
        names = self.speakers.names_digest()
        names_changed = names != self.db.meta("rendered_names")
        operating = f"{self.operating.threshold}/{self.operating.margin}"
        if operating != self.db.meta("speaker_operating"):  # new operating points: reassign everything
            self.db.set_meta("speaker_operating", operating)
            self.db.set_meta("relabel_pending", "1")
        if not names_changed and self.db.meta("relabel_pending") != "1":
            return []
        prefs = self.speakers.settings()
        models_by_voice: dict[tuple[str, str], dict] = {}
        changed: list[str] = []
        conv_ids = [r["conversation_id"] for r in self.db.query(
            "SELECT DISTINCT conversation_id FROM voices UNION SELECT DISTINCT conversation_id FROM speaker_labels")]  # fmt: skip
        for conv_id in conv_ids:
            row = self.db.one("SELECT * FROM conversations WHERE id=?", (conv_id,))
            if row is None:
                continue
            self.speakers.sync_labels_index(conv_id)  # never overwrite the file with a stale index
            voices = self.speakers.voices(conv_id)
            current = self.speakers.labels(conv_id)
            key = next(((v.model, v.model_sha) for v in voices.values()), None)
            if key is not None:
                if key not in models_by_voice:
                    models_by_voice[key] = speaker_match.build_models(self.speakers.samples(*key), self.operating)
                states = speaker_match.assign(voices, current, models_by_voice[key], auto_assign=prefs["auto_assign"],
                                              op=self.operating)  # fmt: skip
            else:
                states = current
            known = {r["id"] for r in self.speakers.people()}
            states = {label: (st if st.get("person_id") in known or not st.get("person_id") else
                              st | {"person_id": None, "source": None}) for label, st in states.items()}  # fmt: skip
            differs = self.speakers.persisted(states) != self.speakers.persisted(current)
            if differs:
                self.speakers.write_labels(conv_id, states)  # still tagged with the transcript they were made for
                changed.append(conv_id)
            named = any(s.get("person_id") for s in (states | current).values())
            if (differs or names_changed) and row["note_path"] and named:
                self._set(conv_id, needs_render=1, next_attempt_at=None)
        self.db.set_meta("relabel_pending", None)
        self.db.set_meta("rendered_names", names)
        return changed

    def voice_names(self, conv_id: str) -> dict[str, tuple[str, bool]]:
        return {label: (v["name"], v["me"]) for label, v in self.speakers.names(conv_id).items()}

    def _speakers(self, conv_id: str, response: dict, audio: ConversationAudio, audio_sha: str) -> SpeakerResult:
        """Speaker labels per STT_DIARIZATION (see `pipeline.speakers`). Local diarization runs on
        the submitted PCM (same clock as the provider's timestamps) and is cached."""

        def local_turns() -> list[Turn] | None:
            diarizer = self.providers.diarizer
            if diarizer is None:
                return None
            path = self.conv_dir(conv_id) / f"diarization-{_slug(diarizer.tag)}-{audio_sha[:16]}.json"
            if path.exists():
                return [Turn(*t) for t in json.loads(path.read_text())["turns"]]
            turns = diarizer.diarize(audio.pcm)
            atomic_write_bytes(path, json.dumps({"turns": [[t.start, t.end, t.speaker] for t in turns]}).encode())
            return turns

        return resolve_speakers(response, self.settings.stt_diarization, local_turns)

    # -- LLM + render ----------------------------------------------------------------------------

    def load_transcript(self, conv_id: str) -> dict:
        path = self.conv_dir(conv_id) / "transcript.json"
        if not path.exists():
            raise CacheMiss(f"no transcript for {conv_id}")
        return json.loads(path.read_text())

    def bookmarks(self, row: sqlite3.Row) -> list[float]:
        return sorted(
            ev["t"]
            for ev in self.db.query(
                "SELECT t FROM event_times WHERE device_id=? AND type='button' AND code=1", (row["device_id"],)
            )
            if bookmark_owner(self.db, row["device_id"], ev["t"]) == row["id"]
        )

    def late_double_taps(self, row: sqlite3.Row) -> list[float]:
        """Double taps strictly inside the conversation: they came too late to split it."""
        return sorted(
            ev["t"]
            for ev in self.db.query(
                "SELECT t FROM event_times WHERE device_id=? AND type='button' AND code=2 AND t > ? AND t < ?",
                (row["device_id"], row["start"] + 1e-3, row["end"] - 1e-3),
            )
        )

    def llm_notes(self, row: sqlite3.Row, segments: list[dict], language: str, now: float, *, cache_only: bool) -> dict:
        conv_dir = self.conv_dir(row["id"])
        if cache_only:
            # Re-render from exactly what the note was made with, whatever the current model/prompt.
            if row["llm_ref"] and (conv_dir / row["llm_ref"]).exists():
                return _load_llm_cache(conv_dir / row["llm_ref"])
            candidates = sorted(conv_dir.glob(f"llm-*-{row['transcript_sha'][:16]}.json"))
            if not candidates:
                raise CacheMiss(f"no cached LLM result for {row['id']}")
            return max((_load_llm_cache(p) for p in candidates), key=lambda c: c["created_at"])
        names = self.voice_names(row["id"])
        # The names the summary was written with are part of its cache key.
        speakers_sha = sha256_hex(canonical_json(sorted((k, v[0], v[1]) for k, v in names.items())).encode())[:8]
        base = f"llm-{_slug(self.providers.llm_model)}-p{prompt.PROMPT_VERSION}-{row['transcript_sha'][:16]}-s{speakers_sha}"
        name = _reusable(conv_dir, base, row["llm_ref"], row["skip_llm"])
        path = conv_dir / name
        if path.exists():
            return _load_llm_cache(path)
        user = prompt.build_user_message(
            segments=segments, start=row["start"], end=row["end"], tz=self.tz,
            timezone_name=self.timezone, language=language,
            owner_name=self.owner_name, bookmarks=self.bookmarks(row),
            provisional=bool(row["provisional"]), audio_gaps=json.loads(row["gaps_json"]), now=now,
            speaker_names=names,
        )  # fmt: skip
        result = self.providers.llm.summarize(
            LlmRequest(system=prompt.SYSTEM_PROMPT, user=user, schema=NOTES_JSON_SCHEMA, segments=segments)
        )
        cached = {"created_at": now, "model": result.model, "prompt_version": prompt.PROMPT_VERSION,
                  "usage": result.usage, "fallback_used": result.fallback_used, "data": result.data}  # fmt: skip
        atomic_write_bytes(path, json.dumps(cached, ensure_ascii=False).encode())
        return cached | {"file": name}

    def summarize_and_render(
        self, conv_id: str, now: float, *, cache_only: bool = False, summary_error: str | None = None
    ) -> None:
        row = self._row(conv_id)
        transcript = self.load_transcript(conv_id)
        self.move_labels(conv_id, transcript)
        row = self._row(conv_id)  # the speakers revision this render is made from
        segments = transcript["segments"]
        language = transcript.get("language") or self.settings.stt_language
        verdict, rule = deterministic_relevance([s["text"] for s in segments], row["speech_seconds"])
        notes: ConversationNotes | None = None
        llm_cached: dict | None = None
        discard_reason = None
        # Re-renders (cache_only) reproduce what the note was made from, whatever the settings now.
        no_summary = row["llm_status"] == "none" if cache_only else self.settings.llm_provider == "none"
        if verdict == "discard":
            kind = "discarded"
            discard_reason = RULE_REASONS.get(rule, rule)
        elif summary_error is not None or no_summary:
            kind = "transcript_only"
            summary_error = summary_error or "LLM_PROVIDER=none"
        else:
            llm_cached = self.llm_notes(row, segments, language, now, cache_only=cache_only)
            notes = ConversationNotes.model_validate(llm_cached["data"])
            kind = "completed" if verdict == "keep" or notes.keep else "discarded"
            if kind == "discarded":
                discard_reason = notes.discard_reason or "judged not worth keeping"
        self.render(row, kind, segments, language, transcript, notes, llm_cached, discard_reason, summary_error,
                    verdict, rule, now, cache_only=cache_only)  # fmt: skip

    def render(self, row, kind, segments, language, transcript, notes, llm_cached, discard_reason, summary_error,
               verdict, rule, now, *, cache_only: bool = False) -> None:  # fmt: skip
        """Publish the note crash-safely: read the user's My Notes (refusing ambiguous markers),
        durably write the new file, record it (conversation.json, then the index), and only then
        remove a previous location. A note edited outside My Notes since we wrote it is not
        overwritten (docs/vault.md, "Notes"); a frozen note is never re-rendered."""
        conv_id = row["id"]
        root = self.settings.vault_dir
        if row["frozen"] and row["note_path"]:
            self._set(conv_id, needs_render=0, next_attempt_at=None)
            return
        snap = self._render_settings(row, cache_only)
        tz = ZoneInfo(snap["timezone"])
        if row["stale_note_path"]:
            self._remove_own(row["stale_note_path"], conv_id)  # finish a move interrupted by a crash
            self._commit(conv_id, stale_note_path=None)
            row = self._row(conv_id)
        related = None
        if row["related_id"]:
            rel = self.db.one("SELECT note_path FROM conversations WHERE id=?", (row["related_id"],))
            related = link_target(rel["note_path"]) if rel and rel["note_path"] else row["related_id"]
        data = NoteData(
            id=conv_id, status=kind, start=row["start"], end=row["end"], tz=tz,
            segments=segments, speech_seconds=row["speech_seconds"], notes=notes,
            provisional=bool(row["provisional"]), late_audio=bool(row["late_audio"]), related=related,
            audio_gaps=json.loads(row["gaps_json"]), sources=json.loads(row["sources_json"]),
            device=self._device_label(row["device_id"]), language=language,
            stt=transcript.get("stt", ""), llm=llm_cached["model"] if llm_cached else None,
            prompt_version=llm_cached["prompt_version"] if llm_cached else None, revision=0,
            processed_at=llm_cached["created_at"] if llm_cached else transcript.get("transcribed_at"),
            bookmarks=self.bookmarks(row), late_double_taps=self.late_double_taps(row),
            discard_reason=discard_reason, summary_error=summary_error, owner_name=snap["owner_name"],
            lost_seconds=row["lost_seconds"], clock_suspect=bool(row["clock_suspect"]),
            speaker_labels_consistent=transcript.get("speaker_labels_consistent", True),
            voice_names={label: name for label, (name, _) in self.voice_names(conv_id).items()},
        )  # fmt: skip
        content_sha = sha256_hex(render_note(data, "").encode())
        revision = row["revision"] if row["content_sha"] == content_sha and row["revision"] else row["revision"] + 1
        data.revision = revision

        old = row["note_path"]
        relpath = self._target_path(row, kind, data, tz)
        user_notes = self._user_notes(conv_id, relpath, old)
        text = render_note(data, user_notes)
        self._guard_edits(row, old, text)
        write_if_changed(root / relpath, text)
        moved = old if old and old != relpath else None

        failed = row["status"] == "failed"
        index = {
            "kind": kind,
            "emoji": notes.emoji if notes else "",
            "action_items": [_action_text(i, snap["owner_name"]) for i in notes.action_items] if notes else [],
            "llm_model": llm_cached["model"] if llm_cached else None,
            "llm_usage": llm_cached.get("usage", {}) if llm_cached else {},
            "stt_seconds": transcript.get("submitted_seconds", 0),
            "discard_reason": discard_reason,
            "relevance": [verdict, rule],
        }
        llm_status = "ok" if llm_cached else ("none" if snap.get("llm_none") else ("failed" if summary_error else None))
        self._commit(
            conv_id,
            status="failed" if failed and kind == "transcript_only" else ("discarded" if kind == "discarded" else "done"),
            note_path=relpath, stale_note_path=moved, stub_path=None, revision=revision, content_sha=content_sha,
            written_sha=generated_sha(text), edited=0, settings_json=json.dumps(snap, sort_keys=True),
            title=title_of(data), index_json=json.dumps(index, ensure_ascii=False), needs_render=0, relevance=rule,
            rendered_speakers_revision=row["speakers_revision"],
            llm_ref=llm_cached["file"] if llm_cached else None,
            prompt_version=llm_cached["prompt_version"] if llm_cached else None,
            llm_status=llm_status, **({"skip_llm": None} if llm_cached and not cache_only else {}),
            next_attempt_at=None, done_at=row["done_at"] or now, updated_at=now,
            **({} if failed else {"error": None, "error_kind": None, "failed_stage": None, "attempts": 0}),
        )  # fmt: skip
        if moved:
            self._remove_own(moved, conv_id)
            self._commit(conv_id, stale_note_path=None)
        if relpath != old:  # late-audio notes link here: refresh their link
            self.db.execute("UPDATE conversations SET needs_render=1 WHERE related_id=? AND note_path IS NOT NULL", (conv_id,))
        if row["stub_path"]:
            remove(root / row["stub_path"])
        self.mark_day(row["start"])
        self._collect_garbage(conv_id)

    def _render_settings(self, row, cache_only: bool) -> dict:
        """Render-affecting settings: the conversation's snapshot for cache-only re-renders (a
        config change never silently rewrites history), the current ones otherwise."""
        if cache_only and row["settings_json"]:
            return json.loads(row["settings_json"])
        snap = {"timezone": self.timezone, "owner_name": self.owner_name}
        if (row["llm_status"] == "none") if cache_only else self.settings.llm_provider == "none":
            snap["llm_none"] = True
        return snap

    @property
    def timezone(self) -> str:
        """TIMEZONE when set explicitly, else the vault's (so another machine renders the same)."""
        if "timezone" in self.settings.model_fields_set or not self.vault.timezone:
            return self.settings.timezone
        return self.vault.timezone

    @property
    def tz(self) -> ZoneInfo:
        return ZoneInfo(self.timezone)

    @property
    def owner_name(self) -> str:
        """The "me" person's name once there is one, else OWNER_NAME (explicit, else the vault's)."""
        me = self.speakers.me()
        if me is not None:
            return me["name"]
        if "owner_name" in self.settings.model_fields_set:
            return self.settings.owner_name
        return self.vault.info.get("owner_name") or self.settings.owner_name

    def _guard_edits(self, row, old: str | None, text: str) -> None:
        """Best-effort (not race-free) protection of edits outside My Notes. `text` is what is
        about to be written: a note that already says exactly that is our own earlier write that
        a crash kept from being recorded, not a user's edit."""
        if not old or not row["written_sha"]:
            return
        path = self.settings.vault_dir / old
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            return  # deleted: it is written again
        try:
            current = generated_sha(data.decode("utf-8"))
        except UnicodeDecodeError:
            current = None
        if current in (row["written_sha"], generated_sha(text)):
            return
        if row["edited"] == 2:  # "overwrite" chosen: set the user's version aside first
            atomic_write_bytes(self.vault.displaced / f"{sha256_hex(data)}.md", data)
            log.info("note %s: the edited version was saved to _omi/displaced/%s.md", old, sha256_hex(data))
            return
        if row["edited"] != 1:
            log.warning("note %s was edited outside My Notes; not overwriting it (see _status.md)", old)
        self._set(row["id"], edited=1)
        raise NoteEdited(old)

    def _remove_own(self, relpath: str, conv_id: str) -> None:
        """Remove a previous location of this conversation's note, never someone else's file."""
        path = self.settings.vault_dir / relpath
        if path.exists() and read_note_id(path) not in (conv_id, None):
            log.warning("not removing %s: it now belongs to another note", relpath)
            return
        remove(path)

    def _collect_garbage(self, conv_id: str) -> None:
        """Delete provider results no record references any more (e.g. after a forced reprocess)."""
        row = self._row(conv_id)
        conv_dir = self.conv_dir(conv_id)
        keep = {row["stt_ref"], row["llm_ref"]}
        audio = (row["audio_sha"] or "")[:16]
        for path in list(conv_dir.glob("stt-*.json")) + list(conv_dir.glob("llm-*.json")):
            if path.name not in keep:
                path.unlink(missing_ok=True)
        for path in conv_dir.glob("diarization-*.json"):
            if audio and not path.stem.endswith(audio):
                path.unlink(missing_ok=True)

    def _target_path(self, row: sqlite3.Row, kind: str, data: NoteData, tz: ZoneInfo | None = None) -> str:
        conv_id, old = row["id"], row["note_path"]
        start_local = datetime.fromtimestamp(row["start"], tz or self.tz)
        short = conv_id.replace("-", "")[-6:]
        if kind == "discarded":
            return old if old and old.startswith("_discarded/") else discarded_relpath(start_local, short)
        if old and old.startswith("Conversations/"):
            return old  # frozen at first completion
        base = conversation_relpath(start_local, title_of(data))
        for candidate in (base, with_suffix_id(base, short), with_suffix_id(base, conv_id)):
            if self.db.one("SELECT 1 FROM conversations WHERE note_path=? AND id<>?", (candidate, conv_id)):
                continue
            path = self.settings.vault_dir / candidate
            # Our own file (published before a crash lost the ledger update) is reused, not dodged.
            if not path.exists() or read_note_id(path) == conv_id:
                return candidate
        raise UserRegionError(f"no free file name for {conv_id} near {base}")

    def _user_notes(self, conv_id: str, relpath: str, old: str | None) -> str | None:
        for candidate in dict.fromkeys(p for p in (relpath, old) if p):
            path = self.settings.vault_dir / candidate
            if path.exists() and (candidate == old or read_note_id(path) == conv_id):
                try:
                    return extract_my_notes(path.read_text(encoding="utf-8"))
                except UserRegionError as exc:
                    raise UserRegionError(f"My Notes markers in {candidate} are ambiguous ({exc}); fix the file by hand") from exc
        return None

    def _device_label(self, device_id: str) -> str | None:
        d = self.db.one("SELECT * FROM devices WHERE device_id=?", (device_id,))
        if d is None:
            return None
        parts = [x for x in (d["model_number"] or d["device_name"], d["firmware_revision"] and f"fw {d['firmware_revision']}") if x]
        return " · ".join(parts) or None

    # -- stubs, dailies, status ------------------------------------------------------------------

    def reconcile_moves(self, now: float) -> None:
        """Finish note moves a crash interrupted: the new path is committed, the old file may
        still exist. It is removed durably before the marker is cleared. A removal that fails
        keeps the marker, shows in `_status.md` and is retried with backoff."""
        for row in self.db.query("SELECT id, status, error_kind, stale_note_path FROM conversations WHERE stale_note_path IS NOT NULL"):
            attempts, retry_at = self._move_retries.get(row["id"], (0, 0.0))
            if now < retry_at:
                continue
            try:
                remove(self.settings.vault_dir / row["stale_note_path"])
            except OSError as exc:
                attempts += 1
                self._move_retries[row["id"]] = (attempts, now + backoff(attempts))
                log.warning("could not remove old note copy %s (attempt %d): %s", row["stale_note_path"], attempts, exc)
                if row["status"] != "failed":
                    self._set(row["id"], error=f"could not remove the old copy {row['stale_note_path']}: {exc}"[:500],
                              error_kind="move")  # fmt: skip
                continue
            self._move_retries.pop(row["id"], None)
            self.db.execute(
                "UPDATE conversations SET stale_note_path=NULL WHERE id=? AND stale_note_path=?",
                (row["id"], row["stale_note_path"]),
            )
            if row["error_kind"] == "move":
                self._set(row["id"], error=None, error_kind=None)

    def render_stubs(self, now: float | None = None) -> None:
        """In-progress stubs; an existing stub is rewritten at most once a minute (sync tools)."""
        keep: set[str] = set()
        rows = self.db.query(
            "SELECT * FROM conversations WHERE status IN ('open','closed','transcribing','summarizing','failed') AND note_path IS NULL"
        )
        for row in rows:
            try:
                keep.add(self._render_stub(row, now))
            except OSError:
                log.exception("could not write the in-progress stub for %s", row["id"])
                if row["stub_path"]:
                    keep.add(row["stub_path"])
        stub_dir = self.settings.vault_dir / "_in-progress"
        if stub_dir.exists():
            for path in stub_dir.glob("*.md"):
                if f"_in-progress/{path.name}" not in keep:
                    try:
                        remove(path)
                    except OSError:
                        log.exception("could not remove stale stub %s", path)

    def _render_stub(self, row: sqlite3.Row, now: float | None = None) -> str:
        relpath = stub_relpath(self._local(row["start"]), row["id"].replace("-", "")[-6:])
        if (now is not None and row["stub_path"] == relpath and (self.settings.vault_dir / relpath).exists()
                and now - self._stub_written.get(relpath, float("-inf")) < STATUS_INTERVAL):  # fmt: skip
            return relpath
        content = render_stub(
            conv_id=row["id"], status=row["status"], start=row["start"], end=row["end"], tz=self.tz,
            speech_seconds=row["speech_seconds"], waiting_for=row["waiting_for"], error=row["error"],
        )  # fmt: skip
        if now is not None:
            self._stub_written[relpath] = now
        if write_if_changed(self.settings.vault_dir / relpath, content) or row["stub_path"] != relpath:
            self.mark_day(row["start"])
        if row["stub_path"] and row["stub_path"] != relpath:
            remove(self.settings.vault_dir / row["stub_path"])
        if row["stub_path"] != relpath:
            self._set(row["id"], stub_path=relpath)
        return relpath

    def render_dailies(self, days: set[date] | None = None) -> None:
        """Render queued (or the given) days; a day leaves the queue only after its file is written."""
        if days is None:
            days = {date.fromisoformat(r["day"]) for r in self.db.query("SELECT day FROM dirty_days")}
        tz = self.tz
        for day in sorted(days):
            lo = datetime(day.year, day.month, day.day, tzinfo=tz).timestamp()
            hi = (datetime(day.year, day.month, day.day, tzinfo=tz) + timedelta(days=1)).timestamp()
            entries = []
            for row in self.db.query("SELECT * FROM conversations WHERE start >= ? AND start < ? ORDER BY start", (lo, hi)):
                index = json.loads(row["index_json"]) if row["index_json"] else {}
                kind = index.get("kind")
                if row["note_path"] and kind:
                    status = kind
                else:
                    status = "failed" if row["status"] == "failed" else "in_progress"
                entries.append(
                    daily_mod.DailyEntry(
                        start=row["start"], end=row["end"], status=status, title=row["title"] or "Conversation",
                        emoji=index.get("emoji", ""), relpath=row["note_path"], action_items=index.get("action_items", []),
                        speech_seconds=row["speech_seconds"], stt_seconds=index.get("stt_seconds", 0),
                        llm_model=index.get("llm_model"), llm_usage=index.get("llm_usage", {}),
                        late_audio=bool(row["late_audio"]), provisional=bool(row["provisional"]),
                        discard_reason=index.get("discard_reason"),
                    )
                )  # fmt: skip
            path = self.settings.vault_dir / "Daily" / f"{day.isoformat()}.md"
            try:
                if entries:
                    write_if_changed(path, daily_mod.render_daily(day, entries, tz))
                else:
                    remove(path)
            except OSError:
                log.exception("could not write the daily index for %s; it stays queued", day)
                continue
            self.db.execute("DELETE FROM dirty_days WHERE day=?", (day.isoformat(),))

    def render_status(self, server_version: str, now: float | None = None, *, force: bool = True) -> None:
        """`_status.md`; unless forced, rewritten at most once a minute (sync tools)."""
        if not force and now is not None and self._status_written and now - self._status_written[0] < STATUS_INTERVAL:
            return
        db = self.db
        devices = []
        for d in db.query("SELECT * FROM devices ORDER BY last_seen DESC"):
            devices.append(dict(d) | {"heartbeat": json.loads(d["heartbeat_json"]) if d["heartbeat_json"] else {}})
        open_captures = [
            {"capture_id": c["capture_id"], "started": c["capture_started_at"],
             "chunks": db.one("SELECT COUNT(*) AS n FROM chunks WHERE capture_id=?", (c["capture_id"],))["n"]}
            for c in db.query("SELECT * FROM captures WHERE seal_json IS NULL AND source='live_ble' ORDER BY capture_started_at")
        ]  # fmt: skip
        pending_ring = []
        for dev in db.query("SELECT DISTINCT device_id FROM captures WHERE source='live_ble' AND offline_storage IS NOT 0"):
            last_live = db.one(
                "SELECT * FROM captures WHERE device_id=? AND source='live_ble' AND seal_json IS NOT NULL ORDER BY capture_started_at DESC LIMIT 1",
                (dev["device_id"],),
            )
            if last_live is None or last_live["seal_reason"] not in ("ble_disconnected", "app_recovered"):
                continue
            end = seal_end_epoch(last_live) or 0
            resolved = self.ring_watermark(dev["device_id"])
            if resolved is None or resolved < end:
                pending_ring.append(f"`{dev['device_id'][:8]}` disconnected at {self._local(end):%H:%M}; offline audio not synced yet")
        open_convs = [dict(r) for r in db.query("SELECT * FROM conversations WHERE status='open' ORDER BY start")]
        failed = [dict(r) for r in db.query("SELECT * FROM conversations WHERE status='failed' ORDER BY start DESC LIMIT 20")]
        attention = [dict(r) for r in db.query(
            "SELECT * FROM conversations WHERE status<>'failed' AND error_kind IN ('notes','io','move') ORDER BY start DESC LIMIT 20"
        )]  # fmt: skip
        edited = [dict(r) for r in db.query(
            "SELECT * FROM conversations WHERE edited=1 AND frozen=0 AND note_path IS NOT NULL ORDER BY start DESC LIMIT 50"
        )]  # fmt: skip
        failed_chunks = [dict(r) for r in db.query("SELECT * FROM chunks WHERE status='failed' LIMIT 20")]
        snapshot = StatusSnapshot(
            server_version=server_version,
            stt=self.providers.stt_label,
            llm="none" if self.settings.llm_provider == "none" else f"{self.settings.llm_provider}/{self.providers.llm_model}",
            vad=self.vad_label, vad_warning=self.vad_warning, devices=devices, open_captures=open_captures,
            pending_ring=pending_ring, open_conversations=open_convs, queue=queue_counts(db),
            failed_conversations=failed, attention=attention, failed_chunks=failed_chunks, edited=edited,
            conflict_copies=self.conflict_copies(now), read_only=_read_only(db),
            replaying=db.meta("replay_pending") == "1",
        )  # fmt: skip
        content = render_status(snapshot, self.tz)
        if self._status_written is None or self._status_written[1] != content:
            write_if_changed(self.settings.vault_dir / "_status.md", content)
            self._status_written = (now if now is not None else time.time(), content)

    def conflict_copies(self, now: float | None = None) -> list[str]:
        """Notes carrying a conversation's id at a path that is not its note (sync conflict copies);
        rescanned at most hourly. Reported, never deleted."""
        now = time.time() if now is None else now
        cached = getattr(self, "_conflicts", None)
        if cached is not None and now - cached[0] < 3600:
            return cached[1]
        paths = {r["id"]: r["note_path"] for r in self.db.query("SELECT id, note_path FROM conversations WHERE note_path IS NOT NULL")}
        found: list[str] = []
        root = self.settings.vault_dir
        for folder in ("Conversations", "_discarded"):
            base = root / folder
            if not base.exists():
                continue
            for path in sorted(base.rglob("*.md")):
                conv_id = read_note_id(path)
                rel = path.relative_to(root).as_posix()
                if conv_id in paths and paths[conv_id] != rel:
                    found.append(f"{rel} (copy of {paths[conv_id]})")
        self._conflicts = (now, found)
        return found

    def ring_watermark(self, device_id: str, now: float | None = None) -> float | None:
        now = time.time() if now is None else now
        return ring_resolved_until(ring_captures(self.db, device_id, now), processed_ring_ranges(self.db, device_id))

    # -- db helpers ------------------------------------------------------------------------------

    def _row(self, conv_id: str) -> sqlite3.Row:
        row = self.db.one("SELECT * FROM conversations WHERE id=?", (conv_id,))
        if row is None:
            raise KeyError(conv_id)
        return row

    def _set(self, conv_id: str, **fields) -> None:
        """Update operational columns only (nothing a record holds)."""
        cols = ", ".join(f"{k}=?" for k in fields)
        self.db.execute(f"UPDATE conversations SET {cols} WHERE id=?", (*fields.values(), conv_id))

    def _commit(self, conv_id: str, **fields) -> None:
        """Update a finalized conversation: its record first (only rewritten when it changes),
        then the index row."""
        row = self._row(conv_id)
        merged = dict(row) | fields
        if merged["status"] == "open":
            if fields:
                self._set(conv_id, **fields)
            return
        known = {r["capture_id"]: r["seq"] for r in self.db.query(
            "SELECT capture_id, seq FROM known_through WHERE conversation_id=?", (conv_id,))}  # fmt: skip
        record = record_from_row(merged, known)
        data = record_bytes(record)
        sha = sha256_hex(data)
        if sha != row["record_sha"] or not record_path(self.vault, conv_id).exists():
            atomic_write_bytes(record_path(self.vault, conv_id), data)
        self._set(conv_id, record_sha=sha, **fields)

    def _sync_record(self, row) -> None:
        self._commit(row["id"])


ABANDONED_RING_SECONDS = 7 * 86400  # an unsealed ring capture silent this long no longer blocks


def ring_captures(db: Database, device_id: str, now: float):
    """The device's offline-storage captures as `segmenter.RingCapture` evidence."""
    rings = []
    for c in db.query("SELECT * FROM capture_times WHERE device_id=? AND source='device_ring'", (device_id,)):
        stats = db.one(
            "SELECT COUNT(*) AS n, SUM(status='processed') AS done, MAX(received_at) AS latest FROM chunks WHERE capture_id=?",
            (c["capture_id"],),
        )
        sealed = c["seal_json"] is not None
        complete = sealed and stats["n"] == c["last_chunk_sequence"] + 1 and (stats["done"] or 0) == stats["n"]
        abandoned = not sealed and (stats["latest"] or c["created_at"]) < now - ABANDONED_RING_SECONDS
        start = c["capture_started_at"] if c["capture_started_at"] is not None else (c["ring_covers_until"] or c["seal_end"])
        rings.append(
            RingCapture(
                capture_id=c["capture_id"], reason=c["seal_reason"], settled=bool(complete and c["finalized"]) or abandoned,
                generation=c["ring_generation"], start=start, covers_until=c["ring_covers_until"],
                info_read_seq=c["ring_info_read_seq"],
            )
        )  # fmt: skip
    return rings


def processed_ring_ranges(db: Database, device_id: str) -> dict[int | None, list[tuple[int, int]]]:
    """Processed ring sequences of a device as merged ranges per storage generation."""
    ranges: dict[int | None, list[tuple[int, int]]] = {}
    for r in db.query(
        """SELECT gen, MIN(ring_seq) AS lo, MAX(ring_seq) AS hi FROM (
               SELECT k.ring_generation AS gen, s.ring_seq,
                      s.ring_seq - DENSE_RANK() OVER (PARTITION BY k.ring_generation ORDER BY s.ring_seq) AS island
               FROM ring_seen s JOIN captures k ON k.capture_id = s.capture_id WHERE s.device_id=?)
           GROUP BY gen, island ORDER BY gen, lo""",
        (device_id,),
    ):
        ranges.setdefault(r["gen"], []).append((r["lo"], r["hi"]))
    return ranges


def queue_counts(db: Database) -> dict:
    def count(sql: str) -> int:
        return db.one(sql)["n"]

    conversations_failed = count("SELECT COUNT(*) AS n FROM conversations WHERE status='failed'")
    chunks_failed = count("SELECT COUNT(*) AS n FROM chunks WHERE status='failed'")
    return {
        "chunks_pending": count("SELECT COUNT(*) AS n FROM chunks WHERE status='pending'"),
        "conversations_open": count("SELECT COUNT(*) AS n FROM conversations WHERE status='open'"),
        "conversations_pending": count(
            "SELECT COUNT(*) AS n FROM conversations WHERE status IN ('closed','transcribing','summarizing')"
        ),
        "failed": conversations_failed + chunks_failed,  # older phones read only this sum
        "conversations_failed": conversations_failed,
        "chunks_failed": chunks_failed,
        "conversations_retrying": count(
            "SELECT COUNT(*) AS n FROM conversations WHERE status IN ('closed','transcribing','summarizing') "
            "AND error IS NOT NULL AND next_attempt_at IS NOT NULL"
        ),
        "notes_conflicted": count("SELECT COUNT(*) AS n FROM conversations WHERE edited=1 AND frozen=0 AND note_path IS NOT NULL"),
    }


def ring_seen_check(db: Database, device_id: str, capture_id: str, chunk_sequence: int):
    """Callable for `CaptureTimeline`: True if another chunk owns this ring record.

    A record re-read by a later sync belongs to the *earliest received* chunk containing it
    (received_at, capture_id, chunk_sequence), decided from receipts rather than processing order,
    so a rebuild's replay assigns every record to the same chunk as the first pass."""
    me = db.one("SELECT received_at FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, chunk_sequence))
    key = (me["received_at"] if me else float("inf"), capture_id, chunk_sequence)

    def seen(ring_seq: int, digest: str) -> bool:
        for r in db.query(
            "SELECT capture_id, chunk_sequence, received_at FROM ring_records WHERE device_id=? AND ring_seq=? AND record_hash=?",
            (device_id, ring_seq, digest),
        ):
            if (r["received_at"], r["capture_id"], r["chunk_sequence"]) < key:
                return True
        return False

    return seen


def bookmark_owner(db: Database, device_id: str, t: float) -> str | None:
    """The conversation a single tap at `t` belongs to: the one containing it, else the nearest
    within 60 s (the one before wins ties: a tap usually marks what was just said)."""
    best: tuple[float, int, str] | None = None
    for row in db.query(
        "SELECT id, start, end FROM conversations WHERE device_id=? AND start <= ? AND end >= ?",
        (device_id, t + BOOKMARK_REACH, t - BOOKMARK_REACH),
    ):
        if row["start"] <= t <= row["end"]:
            return row["id"]
        before = t > row["end"]
        distance = t - row["end"] if before else row["start"] - t
        key = (distance, 0 if before else 1, row["id"])
        if best is None or key < best:
            best = key
    return best[2] if best else None


def _load_llm_cache(path: Path) -> dict:
    cached = json.loads(path.read_text())
    if "prompt_version" not in cached:
        match = _PROMPT_IN_NAME.search(path.name)
        cached["prompt_version"] = int(match.group(1)) if match else None
    return cached | {"file": path.name}


def _action_text(item, owner_name: str) -> str:
    owner = owner_display(item, owner_name)
    text = item.description + (f" — **{owner}**" if owner else "")
    return text + (f" 📅 {item.due_date.isoformat()}" if item.due_date else "")


def _slug(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9.]+", "-", value).strip("-") or "x"


def _reusable(directory: Path, base: str, ref: str | None, skip: str | None) -> str:
    """The result file to use for `base`: the referenced one or `<base>.json` when present and not
    excluded by a forced reprocess; otherwise a free name (`<base>-2.json`, ...: results are
    write-once, never overwritten)."""
    excluded = set(json.loads(skip)) if skip else set()
    for name in (ref, f"{base}.json"):
        if name and name.startswith(base) and name not in excluded and (directory / name).exists():
            return name
    name, n = f"{base}.json", 2
    while (directory / name).exists():
        name, n = f"{base}-{n}.json", n + 1
    return name


def _read_only(db: Database) -> str | None:
    for key in ("read_only", "divergence", "fenced"):
        value = db.meta(key)
        if value:
            return value
    return None
