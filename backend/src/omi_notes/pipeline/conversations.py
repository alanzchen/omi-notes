"""Conversation stages after close: audio → STT → relevance → LLM → markdown; plus stubs,
daily indexes and `_status.md`.

Every stage is idempotent and cached under `DATA_DIR/derived/conversations/<id>/`:
- `stt-<provider>-<model>-<lang>-<audio_sha16>.json`: raw provider response (+ when it was made)
- `transcript.json`: wall-clock segments derived from it (cheap to recompute)
- `llm-<model>-p<PROMPT_VERSION>-<transcript_sha16>.json`: structured notes (+ when/usage); the
  exact file a note was rendered from is recorded on the conversation (`llm_ref`)
Rendering is a pure function of the DB row and these files, so `omi-notes rebuild` makes zero
API calls. A conversation is advanced only under a durable claim, so two processes can never
work on the same one.
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
    link_target,
    read_note_id,
    remove,
    stub_relpath,
    with_suffix_id,
    write_if_changed,
)
from ..providers import LlmProvider, LlmRequest, ProviderError, SttProvider, SttRequest
from ..settings import Settings
from ..spool import atomic_write_bytes
from ..util import canonical_json, sha256_hex
from . import prompt
from .relevance import deterministic_relevance
from .segmenter import RingCapture, ring_resolved_until
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


class CacheMiss(RuntimeError):
    """`rebuild` needs a cached provider result that does not exist."""


def backoff(attempts: int) -> float:
    return min(3600.0, 30.0 * 2 ** max(0, attempts - 1))


@dataclass
class Providers:
    """Lazily constructed so a missing key fails the conversation visibly instead of the server."""

    settings: Settings
    _stt: SttProvider | None = None
    _llm: LlmProvider | None = None

    @property
    def stt(self) -> SttProvider:
        if self._stt is None:
            if self.settings.stt_provider == "fake":
                from ..providers.fake import FakeStt

                self._stt = FakeStt()
            else:
                from ..providers.deepgram import DeepgramStt

                self._stt = DeepgramStt(self.settings.deepgram_api_key, self.settings.stt_model)
        return self._stt

    @property
    def llm(self) -> LlmProvider:
        if self._llm is None:
            if self.settings.llm_provider == "fake":
                from ..providers.fake import FakeLlm

                self._llm = FakeLlm()
            else:
                from ..providers.anthropic_llm import AnthropicLlm

                self._llm = AnthropicLlm(
                    self.settings.anthropic_api_key, self.settings.llm_model, self.settings.llm_effort
                )
        return self._llm

    @property
    def stt_label(self) -> str:
        if self.settings.stt_provider == "fake":
            return "fake/fake-stt"
        return f"deepgram/{self.settings.stt_model}"

    @property
    def llm_model(self) -> str:
        return "fake-llm" if self.settings.llm_provider == "fake" else self.settings.llm_model


class ConversationPipeline:
    def __init__(self, settings: Settings, db: Database, providers: Providers, vad_label: str, vad_warning: str | None) -> None:
        self.settings = settings
        self.db = db
        self.providers = providers
        self.vad_label = vad_label
        self.vad_warning = vad_warning
        self._move_retries: dict[str, tuple[int, float]] = {}

    # -- paths / days ----------------------------------------------------------------------------

    def conv_dir(self, conv_id: str) -> Path:
        return self.settings.derived_dir / "conversations" / conv_id

    def _local(self, epoch: float) -> datetime:
        return datetime.fromtimestamp(epoch, self.settings.tz)

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

    def run(self, now: float, *, limit: int = 20) -> int:
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
        except Exception as exc:  # a bug or unexpected I/O error must not stop the worker loop
            log.exception("conversation %s failed in %s", conv_id, stage)
            self._fail(conv_id, stage, ProviderError(f"{type(exc).__name__}: {exc}"), now)

    def _consume_reprocess(self, row: sqlite3.Row) -> sqlite3.Row:
        """Apply `reprocess` requests (a counter plus accumulated force flags, stored apart from the
        execution status). Caches are dropped here, in the process that owns the pipeline; the
        compare-and-swap on the counter means a request arriving meanwhile is never lost: it is
        applied too, or left pending for the next pass."""
        while True:
            conv_dir = self.conv_dir(row["id"])
            patterns = (["stt-*.json", "transcript.json"] if row["force_restt"] else []) + (
                ["llm-*.json"] if row["force_llm"] else []
            )
            for pattern in patterns:
                for path in conv_dir.glob(pattern):
                    path.unlink()
            status = "summarizing" if (conv_dir / "transcript.json").exists() else "closed"
            cur = self.db.execute(
                """UPDATE conversations SET reprocess_handled=?, force_restt=0, force_llm=0, status=?, attempts=0,
                       error=NULL, error_kind=NULL, failed_stage=NULL, next_attempt_at=NULL
                   WHERE id=? AND reprocess_request=?""",
                (row["reprocess_request"], status, row["id"], row["reprocess_request"]),
            )
            row = self._row(row["id"])
            if cur.rowcount == 1:
                return row

    def _rerender(self, row: sqlite3.Row, now: float) -> None:
        """Re-render a finished note (late bookmark/double tap, `rebuild`) from caches only. The
        flag is cleared by a successful write; failures are retried with backoff."""
        error = (row["error"] or "summary failed") if row["status"] == "failed" else None
        try:
            self.summarize_and_render(row["id"], now, cache_only=True, summary_error=error)
        except CacheMiss as exc:
            log.warning("conversation %s: nothing cached to re-render (%s)", row["id"], exc)
            self._set(row["id"], needs_render=0)
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
            self._set(conv_id, status="failed", failed_stage=stage, attempts=attempts, error=str(exc)[:500],
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
            env = parse_envelope(Path(chunk["path"]).read_bytes())
            timeline.ring_seen = ring_seen_check(self.db, capture["device_id"], capture["capture_id"], seq)
            final = bool(json.loads(chunk["stats_json"] or "{}").get("final"))
            pieces.extend(timeline.decode_chunk(env, final=final).pieces)
        return pieces

    def transcribe(self, conv_id: str, now: float) -> None:
        row = self._row(conv_id)
        audio = self.conversation_audio(row)
        if len(audio.pcm) == 0:
            raise ProviderError("no decodable audio under this conversation's speech", terminal=True, kind="audio")
        audio_sha = sha256_hex(audio.pcm.tobytes() + canonical_json([list(b) for b in audio.blocks_out]).encode())
        stt = self.providers.stt
        name = f"stt-{stt.name}-{_slug(stt.model)}-{_slug(self.settings.stt_language)}-{audio_sha[:16]}.json"
        path = self.conv_dir(conv_id) / name
        if path.exists():
            cached = json.loads(path.read_text())
        else:
            response = stt.transcribe(
                SttRequest(flac=audio.flac(), duration=audio.duration, blocks=audio.blocks_out,
                           language=self.settings.stt_language, keyterms=self.settings.keyterms)
            )  # fmt: skip
            cached = {"created_at": now, "provider": stt.name, "model": stt.model, "response": response}
            atomic_write_bytes(path, json.dumps(cached).encode())
        segments = merge_same_speaker(segments_from_deepgram(cached["response"], audio.timemap))
        language = self.settings.stt_language
        if language == "multi":
            language = detected_language(cached["response"]) or language
        transcript = {
            "segments": segments,
            "language": language,
            "audio_sha": audio_sha,
            "stt": f"{cached['provider']}/{cached['model']}",
            "stt_file": name,
            "transcribed_at": cached["created_at"],
            "submitted_seconds": round(audio.duration, 3),
            "missing": audio.missing,
        }
        atomic_write_bytes(self.conv_dir(conv_id) / "transcript.json", json.dumps(transcript, indent=1).encode())
        self._set(conv_id, status="summarizing", audio_sha=audio_sha, stt_ref=name, language=language,
                  transcript_sha=sha256_hex(canonical_json(segments).encode()), attempts=0, error=None,
                  error_kind=None, next_attempt_at=None, updated_at=now)  # fmt: skip

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
        name = f"llm-{_slug(self.providers.llm_model)}-p{prompt.PROMPT_VERSION}-{row['transcript_sha'][:16]}.json"
        path = conv_dir / name
        if path.exists():
            return _load_llm_cache(path)
        user = prompt.build_user_message(
            segments=segments, start=row["start"], end=row["end"], tz=self.settings.tz,
            timezone_name=self.settings.timezone, language=language,
            owner_name=self.settings.owner_name, bookmarks=self.bookmarks(row),
            provisional=bool(row["provisional"]), audio_gaps=json.loads(row["gaps_json"]), now=now,
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
        self.render(row, kind, segments, language, transcript, notes, llm_cached, discard_reason, summary_error, verdict, rule, now)

    def render(self, row, kind, segments, language, transcript, notes, llm_cached, discard_reason, summary_error, verdict, rule, now) -> None:
        """Publish the note crash-safely: read the user's My Notes (refusing ambiguous markers),
        durably write the new file, record its path, and only then remove a previous location."""
        conv_id = row["id"]
        notes_dir = self.settings.notes_dir
        if row["stale_note_path"]:
            remove(notes_dir / row["stale_note_path"])  # finish a move interrupted by a crash
            self._set(conv_id, stale_note_path=None)
        related = None
        if row["related_id"]:
            rel = self.db.one("SELECT note_path FROM conversations WHERE id=?", (row["related_id"],))
            related = link_target(rel["note_path"]) if rel and rel["note_path"] else row["related_id"]
        data = NoteData(
            id=conv_id, status=kind, start=row["start"], end=row["end"], tz=self.settings.tz,
            segments=segments, speech_seconds=row["speech_seconds"], notes=notes,
            provisional=bool(row["provisional"]), late_audio=bool(row["late_audio"]), related=related,
            audio_gaps=json.loads(row["gaps_json"]), sources=json.loads(row["sources_json"]),
            device=self._device_label(row["device_id"]), language=language,
            stt=transcript.get("stt", ""), llm=llm_cached["model"] if llm_cached else None,
            prompt_version=llm_cached["prompt_version"] if llm_cached else None, revision=0,
            processed_at=llm_cached["created_at"] if llm_cached else transcript.get("transcribed_at"),
            bookmarks=self.bookmarks(row), late_double_taps=self.late_double_taps(row),
            discard_reason=discard_reason, summary_error=summary_error, owner_name=self.settings.owner_name,
            lost_seconds=row["lost_seconds"], clock_suspect=bool(row["clock_suspect"]),
        )  # fmt: skip
        content_sha = sha256_hex(render_note(data, "").encode())
        revision = row["revision"] if row["content_sha"] == content_sha and row["revision"] else row["revision"] + 1
        data.revision = revision

        old = row["note_path"]
        relpath = self._target_path(row, kind, data)
        user_notes = self._user_notes(conv_id, relpath, old)
        write_if_changed(notes_dir / relpath, render_note(data, user_notes))
        moved = old if old and old != relpath else None

        failed = row["status"] == "failed"
        index = {
            "kind": kind,
            "emoji": notes.emoji if notes else "",
            "action_items": [_action_text(i, self.settings.owner_name) for i in notes.action_items] if notes else [],
            "llm_model": llm_cached["model"] if llm_cached else None,
            "llm_usage": llm_cached.get("usage", {}) if llm_cached else {},
            "stt_seconds": transcript.get("submitted_seconds", 0),
            "discard_reason": discard_reason,
            "relevance": [verdict, rule],
        }
        self._set(
            conv_id,
            status="failed" if failed and kind == "transcript_only" else ("discarded" if kind == "discarded" else "done"),
            note_path=relpath, stale_note_path=moved, stub_path=None, revision=revision, content_sha=content_sha,
            title=title_of(data), index_json=json.dumps(index, ensure_ascii=False), needs_render=0, relevance=rule,
            llm_ref=llm_cached["file"] if llm_cached else None,
            prompt_version=llm_cached["prompt_version"] if llm_cached else None,
            llm_status="ok" if llm_cached else ("none" if self.settings.llm_provider == "none" else ("failed" if summary_error else None)),
            next_attempt_at=None, done_at=row["done_at"] or now, updated_at=now,
            **({} if failed else {"error": None, "error_kind": None, "failed_stage": None, "attempts": 0}),
        )  # fmt: skip
        if moved:
            remove(notes_dir / moved)
            self._set(conv_id, stale_note_path=None)
        if row["stub_path"]:
            remove(notes_dir / row["stub_path"])
        self.mark_day(row["start"])

    def _target_path(self, row: sqlite3.Row, kind: str, data: NoteData) -> str:
        conv_id, old = row["id"], row["note_path"]
        start_local = self._local(row["start"])
        short = conv_id.replace("-", "")[-6:]
        if kind == "discarded":
            return old if old and old.startswith("_discarded/") else discarded_relpath(start_local, short)
        if old and old.startswith("Conversations/"):
            return old  # frozen at first completion
        base = conversation_relpath(start_local, title_of(data))
        for candidate in (base, with_suffix_id(base, short), with_suffix_id(base, conv_id)):
            if self.db.one("SELECT 1 FROM conversations WHERE note_path=? AND id<>?", (candidate, conv_id)):
                continue
            path = self.settings.notes_dir / candidate
            # Our own file (published before a crash lost the ledger update) is reused, not dodged.
            if not path.exists() or read_note_id(path) == conv_id:
                return candidate
        raise UserRegionError(f"no free file name for {conv_id} near {base}")

    def _user_notes(self, conv_id: str, relpath: str, old: str | None) -> str | None:
        for candidate in dict.fromkeys(p for p in (relpath, old) if p):
            path = self.settings.notes_dir / candidate
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
                remove(self.settings.notes_dir / row["stale_note_path"])
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

    def render_stubs(self) -> None:
        keep: set[str] = set()
        rows = self.db.query(
            "SELECT * FROM conversations WHERE status IN ('open','closed','transcribing','summarizing','failed') AND note_path IS NULL"
        )
        for row in rows:
            try:
                keep.add(self._render_stub(row))
            except OSError:
                log.exception("could not write the in-progress stub for %s", row["id"])
                if row["stub_path"]:
                    keep.add(row["stub_path"])
        stub_dir = self.settings.notes_dir / "_in-progress"
        if stub_dir.exists():
            for path in stub_dir.glob("*.md"):
                if f"_in-progress/{path.name}" not in keep:
                    try:
                        remove(path)
                    except OSError:
                        log.exception("could not remove stale stub %s", path)

    def _render_stub(self, row: sqlite3.Row) -> str:
        relpath = stub_relpath(self._local(row["start"]), row["id"].replace("-", "")[-6:])
        content = render_stub(
            conv_id=row["id"], status=row["status"], start=row["start"], end=row["end"], tz=self.settings.tz,
            speech_seconds=row["speech_seconds"], waiting_for=row["waiting_for"], error=row["error"],
        )  # fmt: skip
        if write_if_changed(self.settings.notes_dir / relpath, content) or row["stub_path"] != relpath:
            self.mark_day(row["start"])
        if row["stub_path"] and row["stub_path"] != relpath:
            remove(self.settings.notes_dir / row["stub_path"])
        if row["stub_path"] != relpath:
            self._set(row["id"], stub_path=relpath)
        return relpath

    def render_dailies(self, days: set[date] | None = None) -> None:
        """Render queued (or the given) days; a day leaves the queue only after its file is written."""
        if days is None:
            days = {date.fromisoformat(r["day"]) for r in self.db.query("SELECT day FROM dirty_days")}
        tz = self.settings.tz
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
            path = self.settings.notes_dir / "Daily" / f"{day.isoformat()}.md"
            try:
                if entries:
                    write_if_changed(path, daily_mod.render_daily(day, entries, tz))
                else:
                    remove(path)
            except OSError:
                log.exception("could not write the daily index for %s; it stays queued", day)
                continue
            self.db.execute("DELETE FROM dirty_days WHERE day=?", (day.isoformat(),))

    def render_status(self, server_version: str) -> None:
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
        failed_chunks = [dict(r) for r in db.query("SELECT * FROM chunks WHERE status='failed' LIMIT 20")]
        snapshot = StatusSnapshot(
            server_version=server_version,
            stt=self.providers.stt_label,
            llm="none" if self.settings.llm_provider == "none" else f"{self.settings.llm_provider}/{self.providers.llm_model}",
            vad=self.vad_label, vad_warning=self.vad_warning, devices=devices, open_captures=open_captures,
            pending_ring=pending_ring, open_conversations=open_convs, queue=queue_counts(db),
            failed_conversations=failed, attention=attention, failed_chunks=failed_chunks,
        )  # fmt: skip
        write_if_changed(self.settings.notes_dir / "_status.md", render_status(snapshot, self.settings.tz))

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
        cols = ", ".join(f"{k}=?" for k in fields)
        self.db.execute(f"UPDATE conversations SET {cols} WHERE id=?", (*fields.values(), conv_id))


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

    return {
        "chunks_pending": count("SELECT COUNT(*) AS n FROM chunks WHERE status='pending'"),
        "conversations_open": count("SELECT COUNT(*) AS n FROM conversations WHERE status='open'"),
        "conversations_pending": count(
            "SELECT COUNT(*) AS n FROM conversations WHERE status IN ('closed','transcribing','summarizing')"
        ),
        "failed": count("SELECT COUNT(*) AS n FROM conversations WHERE status='failed'")
        + count("SELECT COUNT(*) AS n FROM chunks WHERE status='failed'"),
    }


def ring_seen_check(db: Database, device_id: str, capture_id: str, chunk_sequence: int):
    """Callable for `CaptureTimeline`: True if another chunk already owns this ring record."""

    def seen(ring_seq: int, digest: str) -> bool:
        owner = db.one(
            "SELECT capture_id, chunk_sequence FROM ring_seen WHERE device_id=? AND ring_seq=? AND record_hash=?",
            (device_id, ring_seq, digest),
        )
        return owner is not None and (owner["capture_id"], owner["chunk_sequence"]) != (capture_id, chunk_sequence)

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
