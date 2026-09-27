"""The restart-safe worker loop.

Each `tick(now)`:
1. decode + VAD every ready chunk (contiguous prefix per capture, in order);
2. finalize sealed captures whose last chunk was processed before the seal arrived;
3. attach late button events (bookmarks, double taps) to finished notes;
4. segment each device with unclaimed speech (pure `segmenter.segment`) and apply the result:
   create/update/delete open conversations, finalize closed ones;
5. advance closed conversations through STT → LLM → markdown;
6. refresh in-progress stubs, daily indexes and `_status.md`;
7. hourly raw-retention cleanup.
`now` is injectable so tests can drive time. `run_forever` holds the host lock (index dir) and the
vault's writer lease, renews the lease and stops writing if another writer takes it (fencing).
"""

from __future__ import annotations

import json
import logging
import threading
import time
from collections import OrderedDict
from pathlib import Path

from .. import __version__
from ..audio.timeline import RING_RECORD_SECONDS, CaptureTimeline, ChunkDecode
from ..audio.vad import MIN_SPEECH, VadChoice, VadStream, make_vad
from ..db import Database
from ..envelope import OPUS_CODECS, parse_envelope
from ..ingest import seal_end_epoch
from ..lock import worker_lock
from ..notes.writer import remove
from ..rebuild import advance_processed
from ..records import record_from_row, write_record
from ..settings import Settings
from ..speakers import enroll
from ..util import uuid7_for
from ..vault import LEASE_RENEW_SECONDS, LeaseError, Vault
from . import segmenter as seg
from .conversations import (
    BOOKMARK_REACH,
    PENDING,
    SOURCE_LABEL,
    ConversationPipeline,
    Providers,
    backoff,
    bookmark_owner,
    processed_ring_ranges,
    ring_captures,
    ring_seen_check,
)

log = logging.getLogger(__name__)

MAX_CHUNK_ATTEMPTS = 5
CHUNKS_PER_TICK = 200
TIMELINE_CACHE = 32
RETENTION_INTERVAL = 3600.0
LATE_EVENT_HORIZON = 7 * 86400


class Worker:
    def __init__(
        self,
        settings: Settings,
        db: Database,
        *,
        providers: Providers | None = None,
        vad: VadChoice | None = None,
        clock=time.time,
    ) -> None:
        self.settings = settings
        self.db = db
        self.vault = Vault.open(settings)
        self.clock = clock
        self.take_over = False
        self.vad = vad or make_vad(settings.vad_backend, settings.vad_model_path, settings.vad_threshold)
        self.providers = providers or Providers(settings)
        self.pipeline = ConversationPipeline(settings, db, self.providers, self.vad.vad.name, self.vad.warning)
        self.enrollments = enroll.EnrollmentProcessor(self)
        self.params = seg.Params(
            gap=settings.conversation_gap_seconds,
            provisional_wait_open=settings.provisional_wait_open_seconds,
            provisional_wait=settings.provisional_wait_seconds,
            soft_max=settings.soft_max_conversation_seconds,
            hard_max=settings.hard_max_conversation_seconds,
        )
        self.lock = worker_lock(self.vault)
        self._decoders: OrderedDict[str, tuple[int, CaptureTimeline, VadStream]] = OrderedDict()
        self._last_retention = 0.0
        self._reconciled = False

    # -- loop ------------------------------------------------------------------------------------

    def tick(self, now: float | None = None) -> dict:
        now = self.clock() if now is None else now
        blocked = read_only_reason(self.db)
        if blocked:
            self._status(now, force=False)
            return {"chunks": 0, "segmentation_changes": 0, "conversations": 0, "read_only": blocked}
        if not self._reconciled:
            self.pipeline.reconcile_days()  # daily indexes may be stale after a crash
            self._reconciled = True
        self.pipeline.reconcile_moves(now)
        chunks = self.process_chunks(now)
        self.finalize_sealed(now)
        if self.replaying and not self._ready_chunks():
            # Recreate the estimated overwritten-record losses without refreshing notes: the
            # records already hold whatever those losses changed before the rebuild.
            self.reconcile_dropped(now, silent=True)
            self.db.set_meta("replay_pending", None)
            log.info("replay after the index rebuild finished")
        changed = advanced = 0
        if not self.replaying:
            # Gated during a replay: they read speech/coverage/losses the replay is still re-deriving.
            self.reconcile_dropped(now)
            self.apply_late_events(now)
            changed = self.segment_all(now)
            try:
                self.pipeline.relabel(now)
            except Exception:
                log.exception("could not re-run speaker assignment")
            try:
                self.enrollments.run(now)
            except Exception:
                log.exception("could not process voice enrollments")
            advanced = self.pipeline.run(now)
            self.pipeline.render_stubs(now)
            self.pipeline.render_dailies()
        self._status(now)
        if not self.replaying and now - self._last_retention >= RETENTION_INTERVAL:
            self.check_divergence()
            self.retention(now)
            self._last_retention = now
        return {"chunks": chunks, "segmentation_changes": changed, "conversations": advanced}

    def check_divergence(self) -> list[str]:
        """Sync conflict copies / duplicate records under `_omi/` stop all writes until resolved."""
        problems = self.vault.divergence()
        reason = ("vault divergence (a sync conflict): " + "; ".join(problems[:5])) if problems else None
        if reason != self.db.meta("divergence"):
            if reason:
                log.error("%s", reason)
            self.db.set_meta("divergence", reason)
        return problems

    @property
    def replaying(self) -> bool:
        return self.db.meta("replay_pending") == "1"

    def _ready_chunks(self) -> bool:
        return self.db.one(
            """SELECT 1 FROM chunks c JOIN captures k ON k.capture_id = c.capture_id
               WHERE c.status='pending' AND c.chunk_sequence = k.processed_through + 1 LIMIT 1"""
        ) is not None

    def _status(self, now: float, force: bool = False) -> None:
        try:
            self.pipeline.render_status(__version__, now, force=force)
        except OSError:
            log.exception("could not write _status.md")

    def run_forever(self, stop: threading.Event) -> None:
        if not self.lock.acquire():
            log.error("another worker (pid %s) holds %s; not processing", self.lock.owner(), self.lock.path)
            return
        try:
            try:
                writer_id = self.vault.acquire_lease(take_over=self.take_over)
            except LeaseError as exc:
                log.error("%s", exc)
                self.db.set_meta("fenced", str(exc))
                return
            self.db.set_meta("fenced", None)
            renewed = time.time()
            self.pipeline.release_all_claims()  # we own the lock: no other worker is running
            log.info("worker started (tick %.1fs, VAD %s)", self.settings.worker_tick_seconds, self.vad.vad.name)
            while not stop.is_set():
                if not self.vault.check_lease(writer_id):
                    reason = "another backend took over this vault's writer lease; this one stopped writing"
                    log.error(reason)
                    self.db.set_meta("fenced", reason)
                    return
                if time.time() - renewed >= LEASE_RENEW_SECONDS:
                    self.vault.renew_lease(writer_id)
                    renewed = time.time()
                try:
                    result = self.tick()
                    busy = result["chunks"] or result["conversations"]
                except Exception:
                    log.exception("worker tick failed")
                    busy = False
                if not busy:
                    stop.wait(self.settings.worker_tick_seconds)
        finally:
            self.lock.release()

    # -- chunks ----------------------------------------------------------------------------------

    def process_chunks(self, now: float) -> int:
        done = 0
        while done < CHUNKS_PER_TICK:
            ready = self.db.query(
                """SELECT c.capture_id, c.chunk_sequence FROM chunks c JOIN captures k ON k.capture_id = c.capture_id
                   WHERE c.status='pending' AND c.chunk_sequence = k.processed_through + 1
                     AND (c.next_attempt_at IS NULL OR c.next_attempt_at <= ?)
                   ORDER BY c.received_at LIMIT 50""",
                (now,),
            )
            if not ready:
                break
            for row in ready:
                try:
                    ok = self.process_chunk(row["capture_id"], row["chunk_sequence"], now)
                except Exception as exc:  # e.g. a storage error while committing: retry later
                    self._chunk_failed(row["capture_id"], row["chunk_sequence"], exc, now)
                    ok = False
                done += int(ok)
        return done

    def _restore(self, capture, carry_seq: int) -> tuple[CaptureTimeline, VadStream]:
        """Decoder + VAD state as it was after chunk `carry_seq` (-1 = capture start)."""
        carry = None
        if carry_seq >= 0:
            row = self.db.one(
                "SELECT carry_json FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture["capture_id"], carry_seq)
            )
            carry = json.loads(row["carry_json"]) if row and row["carry_json"] else None
        timeline = CaptureTimeline(OPUS_CODECS.get(capture["codec_id"] or 21, 320), carry)
        return timeline, VadStream(self.vad.vad, (carry or {}).get("vad"))

    def process_chunk(self, capture_id: str, seq: int, now: float) -> bool:
        capture = self.db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
        chunk = self.db.one("SELECT * FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq))
        try:
            env = parse_envelope((self.vault.root / chunk["path"]).read_bytes())
            cached = self._decoders.pop(capture_id, None)
            timeline, vad = (cached[1], cached[2]) if cached and cached[0] == seq else self._restore(capture, seq - 1)
            timeline.ring_seen = ring_seen_check(self.db, capture["device_id"], capture_id, seq)
            # The seal's flush (pending frame, open speech) is always done by `_finalize` as the
            # virtual chunk last + 1, whether the seal arrived before or after this chunk: the
            # result must not depend on arrival order, or a rebuild's replay could differ.
            result = timeline.decode_chunk(env, final=False)
            speech, open_segment = self._detect(vad, result, False)
        except Exception as exc:  # VAD/IO errors are retryable, never "silence"
            self._chunk_failed(capture_id, seq, exc, now)
            return False

        losses = list(result.losses)
        if chunk["source"] == "device_ring":
            coverage = [(p.start, p.end, "ring") for p in result.pieces]
        else:
            coverage = [(chunk["start_epoch"], chunk["end_epoch"], "live")]
        with self.db.tx() as conn:
            self._store_detection(conn, capture, seq, result, speech, open_segment, losses, coverage, vad, now)
            conn.execute("UPDATE captures SET processed_through=? WHERE capture_id=?", (seq, capture_id))
            advance_processed(conn, capture_id)  # over chunks already processed (raw expired)
        self._decoders[capture_id] = (seq + 1, timeline, vad)
        while len(self._decoders) > TIMELINE_CACHE:
            self._decoders.popitem(last=False)
        return True

    def _chunk_failed(self, capture_id: str, seq: int, exc: Exception, now: float) -> None:
        self._decoders.pop(capture_id, None)
        chunk = self.db.one("SELECT attempts FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq))
        attempts = chunk["attempts"] + 1
        status = "failed" if attempts >= MAX_CHUNK_ATTEMPTS else "pending"
        log.warning("chunk %s#%d failed (attempt %d): %s", capture_id, seq, attempts, exc)
        self.db.execute(
            "UPDATE chunks SET attempts=?, status=?, error=?, next_attempt_at=? WHERE capture_id=? AND chunk_sequence=?",
            (attempts, status, f"{type(exc).__name__}: {exc}"[:500], now + backoff(attempts), capture_id, seq),
        )

    @staticmethod
    def _detect(vad: VadStream, result: ChunkDecode, final: bool):
        speech: list[tuple[float, float]] = []
        for piece in result.pieces:
            if not piece.continues:
                speech += vad.end_run()
            speech += vad.feed(piece.pcm, piece.start)
        if final:
            return speech + vad.end_run(), None
        return speech, vad.open_segment()

    def _store_detection(self, conn, capture, seq, result, speech, open_segment, losses, coverage, vad, now) -> None:
        """Record what chunk `seq` added (runs in the chunk's transaction)."""
        capture_id, device = capture["capture_id"], capture["device_id"]
        conn.execute("DELETE FROM coverage WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq))
        conn.execute("DELETE FROM losses WHERE capture_id=? AND chunk_sequence=?", (capture_id, seq))
        store_speech(conn, device, capture_id, seq, speech, open_segment)
        conn.executemany(
            "INSERT INTO coverage (device_id, kind, start, end, capture_id, chunk_sequence) VALUES (?,?,?,?,?,?)",
            [(device, kind, a, b, capture_id, seq) for a, b, kind in coverage],
        )
        conn.executemany(
            "INSERT INTO losses (device_id, start, end, kind, count, capture_id, chunk_sequence) VALUES (?,?,?,?,?,?,?)",
            [(device, a, b, kind, count, capture_id, seq) for a, b, kind, count in losses],
        )
        conn.executemany(
            "INSERT OR IGNORE INTO ring_seen (device_id, ring_seq, record_hash, capture_id, chunk_sequence) VALUES (?,?,?,?,?)",
            [(device, rs, digest, capture_id, seq) for rs, digest in result.ring_records],
        )
        carry = result.carry | {"vad": vad.to_state()}
        conn.execute(
            """UPDATE chunks SET status='processed', processed_at=?, error=NULL, next_attempt_at=NULL,
                   carry_json=?, runs_json=?, stats_json=?, audio_start=?, audio_end=?
               WHERE capture_id=? AND chunk_sequence=?""",
            (now, json.dumps(carry), json.dumps([[p.start, len(p.pcm)] for p in result.pieces]), json.dumps(result.stats),
             min((p.start for p in result.pieces), default=None), max((p.end for p in result.pieces), default=None),
             capture_id, seq),
        )  # fmt: skip

    def reconcile_dropped(self, now: float, *, silent: bool = False) -> None:
        """Losses for records the device overwrote before a sync could read them. INFO `dropped` is
        treated as a cumulative counter: the loss is the increase over the device's previous sync
        (a decrease, or a different generation, means storage was reset). Until both seals have
        arrived the generations may be unknown, so the estimate is recomputed idempotently each
        tick and frozen once the evidence is complete. Its length is estimated."""
        for capture in self.db.query(
            """SELECT * FROM captures WHERE source='device_ring' AND ring_dropped IS NOT NULL
               AND dropped_reconciled=0 AND capture_started_at IS NOT NULL"""
        ):
            try:
                self._reconcile_dropped(capture, now, silent=silent)
            except Exception:
                log.exception("could not reconcile dropped records for capture %s", capture["capture_id"])

    def _reconcile_dropped(self, capture, now: float, *, silent: bool = False) -> None:
        capture_id = capture["capture_id"]
        first_audio = self.db.one(
            "SELECT MIN(audio_start) AS t FROM chunks WHERE capture_id=? AND status='processed'", (capture_id,)
        )["t"]
        if first_audio is None:
            return
        previous = self.db.one(
            """SELECT ring_dropped, ring_generation, seal_json FROM captures WHERE device_id=? AND source='device_ring'
               AND capture_id<>? AND ring_dropped IS NOT NULL AND capture_started_at < ?
               ORDER BY capture_started_at DESC LIMIT 1""",
            (capture["device_id"], capture_id, capture["capture_started_at"]),
        )
        current, baseline = capture["ring_dropped"], 0
        if previous is not None and previous["ring_dropped"] <= current:
            generations = (previous["ring_generation"], capture["ring_generation"])
            if None in generations or generations[0] == generations[1]:
                baseline = previous["ring_dropped"]
        delta = current - baseline
        loss = (first_audio - delta * RING_RECORD_SECONDS, first_audio) if delta > 0 else None
        complete = capture["seal_json"] is not None and (previous is None or previous["seal_json"] is not None)
        before = self.db.one("SELECT start, end, count FROM losses WHERE capture_id=? AND kind='ring_dropped'", (capture_id,))
        old = (before["start"], before["end"]) if before else None
        # One transaction: the loss rows, the finalized conversations they affect, and the frozen flag
        # commit together. (`refresh_losses` runs on this thread's connection, inside the transaction.)
        # A crash rolls everything back, so the next tick still sees the old interval and refreshes
        # both it and the new one, whether the estimate grew, shrank or disappeared.
        with self.db.tx() as conn:
            conn.execute("DELETE FROM losses WHERE capture_id=? AND kind='ring_dropped'", (capture_id,))
            if loss:
                conn.execute(
                    """INSERT INTO losses (device_id, start, end, kind, count, capture_id, chunk_sequence)
                       VALUES (?,?,?,?,?,?,0)""",
                    (capture["device_id"], *loss, "ring_dropped", delta, capture_id),
                )
            if (old != loss or complete) and not silent:
                self.refresh_losses(capture["device_id"], [x for x in (old, loss) if x] + [(first_audio, first_audio)], now)
            if complete:
                conn.execute("UPDATE captures SET dropped_reconciled=1 WHERE capture_id=?", (capture_id,))

    def refresh_losses(self, device: str, intervals: list[tuple[float, float]], now: float) -> None:
        """Loss evidence changed after conversations near it were finalized: recompute their
        `audio_gaps`/`lost_seconds` and queue a cached re-render (no provider calls)."""
        gap = self.params.gap
        lo, hi = min(a for a, _ in intervals) - gap, max(b for _, b in intervals) + gap
        for conv in self.db.query(
            "SELECT * FROM conversations WHERE device_id=? AND status<>'open' AND end >= ? AND start <= ?", (device, lo, hi)
        ):
            if self.db.one(
                """SELECT 1 FROM chunks WHERE device_id=? AND raw_deleted=1 AND audio_start IS NOT NULL
                   AND audio_start <= ? AND audio_end >= ?""",
                (device, conv["end"] + gap, conv["start"] - gap),
            ):
                continue  # raw already expired around it: its recorded evidence stays as it was
            timeline = seg.DeviceTimeline(speech=[], **self._evidence(device, conv["start"] - gap - 5, conv["end"] + gap + 5, now))
            gaps, lost = seg.window_evidence(timeline, conv["start"], conv["end"], now, self.params)
            if json.dumps(gaps) != conv["gaps_json"] or abs(lost - conv["lost_seconds"]) > 1e-6:
                fields = {"gaps_json": json.dumps(gaps), "lost_seconds": lost}
                record = record_from_row(dict(conv) | fields, self._known_map([conv["id"]]).get(conv["id"], {}))
                sha = write_record(self.vault, record)
                self.db.execute(
                    """UPDATE conversations SET gaps_json=?, lost_seconds=?, needs_render=(note_path IS NOT NULL),
                           record_sha=?, updated_at=? WHERE id=?""",
                    (json.dumps(gaps), lost, sha, now, conv["id"]),
                )

    def finalize_sealed(self, now: float) -> None:
        """Flush what an already-processed last chunk still held (pending BLE frame, open speech)."""
        for capture in self.db.query(
            """SELECT * FROM captures WHERE seal_json IS NOT NULL AND finalized=0
               AND processed_through >= last_chunk_sequence"""
        ):
            try:
                self._finalize(capture)
            except Exception:
                log.exception("could not finalize capture %s", capture["capture_id"])

    def _finalize(self, capture) -> None:
        last = capture["last_chunk_sequence"]
        if last < 0:
            self.db.execute("UPDATE captures SET finalized=1 WHERE capture_id=?", (capture["capture_id"],))
            return
        chunk = self.db.one("SELECT * FROM chunks WHERE capture_id=? AND chunk_sequence=?", (capture["capture_id"], last))
        timeline, vad = self._restore(capture, last)
        flushed = timeline.finish(capture["capture_started_at"] or 0.0)
        speech, _ = self._detect(vad, flushed, final=True)
        self._decoders.pop(capture["capture_id"], None)
        with self.db.tx() as conn:
            # Flushed speech belongs to the virtual chunk last + 1: a conversation finalized before
            # the flush has known_through <= last, so it does not know this speech.
            store_speech(conn, capture["device_id"], capture["capture_id"], last + 1, speech, None)
            conn.executemany(
                "INSERT INTO losses (device_id, start, end, kind, count, capture_id, chunk_sequence) VALUES (?,?,?,?,?,?,?)",
                [(capture["device_id"], a, b, kind, n, capture["capture_id"], last) for a, b, kind, n in flushed.losses],
            )
            runs = json.loads(chunk["runs_json"] or "[]") + [[p.start, len(p.pcm)] for p in flushed.pieces]
            stats = json.loads(chunk["stats_json"] or "{}")
            stats["frames"] = stats.get("frames", 0) + flushed.stats["frames"]
            stats["final"] = True
            ends = [x for x in [chunk["audio_end"], *(p.end for p in flushed.pieces)] if x is not None]
            starts = [x for x in [chunk["audio_start"], *(p.start for p in flushed.pieces)] if x is not None]
            conn.execute(
                """UPDATE chunks SET runs_json=?, stats_json=?, carry_json=?, audio_start=?, audio_end=?
                   WHERE capture_id=? AND chunk_sequence=?""",
                (json.dumps(runs), json.dumps(stats), json.dumps(flushed.carry | {"vad": vad.to_state()}),
                 min(starts, default=None), max(ends, default=None), capture["capture_id"], last),
            )  # fmt: skip
            conn.execute("UPDATE captures SET finalized=1 WHERE capture_id=?", (capture["capture_id"],))

    # -- late events -----------------------------------------------------------------------------

    def apply_late_events(self, now: float) -> None:
        """Bookmarks and double taps that land in an already finished note annotate it (it is
        re-rendered, never reopened)."""
        for ev in self.db.query("SELECT * FROM event_times WHERE type='button' AND code IN (1, 2) AND applied=0"):
            try:
                self._apply_late_event(ev, now)
            except Exception:
                log.exception("could not apply button event %s", ev["event_id"])

    def _apply_late_event(self, ev, now: float) -> None:
        t = ev["t"]
        if ev["code"] == 1:
            owner = bookmark_owner(self.db, ev["device_id"], t)
            conv = self.db.one("SELECT * FROM conversations WHERE id=?", (owner,)) if owner else None
        else:
            conv = self.db.one(
                "SELECT * FROM conversations WHERE device_id=? AND start < ? AND end > ? AND status<>'open'",
                (ev["device_id"], t, t),
            )
            if conv is None and self.db.one(
                "SELECT 1 FROM conversations WHERE device_id=? AND (abs(start - ?) < 0.001 OR abs(end - ?) < 0.001)",
                (ev["device_id"], t, t),
            ):
                self.db.execute("UPDATE events SET applied=1 WHERE event_id=?", (ev["event_id"],))  # used as a split
                return
        if conv is not None and conv["status"] != "open":
            if conv["note_path"]:
                self.db.execute("UPDATE conversations SET needs_render=1 WHERE id=?", (conv["id"],))
            self.db.execute("UPDATE events SET applied=1 WHERE event_id=?", (ev["event_id"],))
        elif now - t > LATE_EVENT_HORIZON:
            self.db.execute("UPDATE events SET applied=1 WHERE event_id=?", (ev["event_id"],))

    # -- segmentation ----------------------------------------------------------------------------

    def segment_all(self, now: float) -> int:
        devices = {r["device_id"] for r in self.db.query("SELECT DISTINCT device_id FROM speech WHERE claimed_by IS NULL")}
        devices |= {r["device_id"] for r in self.db.query("SELECT DISTINCT device_id FROM conversations WHERE status='open'")}
        changes = 0
        for device in sorted(devices):
            try:
                changes += self.segment_device(device, now)
            except Exception:  # one device's bad data must not stall the others
                log.exception("segmentation failed for device %s", device)
        return changes

    def device_timeline(self, device: str, now: float) -> tuple[seg.DeviceTimeline, int] | None:
        rows = self.db.query(
            """SELECT id, start, end, capture_id, chunk_sequence FROM speech
               WHERE device_id=? AND claimed_by IS NULL ORDER BY start, capture_id, chunk_sequence, id""",
            (device,),
        )
        if not rows:
            return None
        gap = self.params.gap
        lo = min(r["start"] for r in rows) - gap - 5
        hi = max(r["end"] for r in rows) + gap + 5
        convs = self.db.query(
            "SELECT * FROM conversations WHERE device_id=? AND status<>'open' AND end >= ? AND start <= ? ORDER BY start",
            (device, lo - gap, hi + gap),
        )
        known = self._known_map([r["id"] for r in convs])
        finalized = [
            seg.Finalized(r["id"], r["start"], r["end"], known.get(r["id"], {}), bool(r["start_explicit"]), bool(r["end_explicit"]))
            for r in convs
        ]
        return seg.DeviceTimeline(
            speech=[seg.Speech(r["id"], r["start"], r["end"], r["capture_id"], r["chunk_sequence"]) for r in rows],
            splits=self.effective_splits(device, lo - gap, hi + gap, now),
            finalized=finalized,
            **self._evidence(device, lo, hi, now),
        )

    def _known_map(self, conv_ids: list[str]) -> dict[str, dict[str, int]]:
        known: dict[str, dict[str, int]] = {}
        for i in range(0, len(conv_ids), 500):
            part = conv_ids[i : i + 500]
            for r in self.db.query(
                f"SELECT * FROM known_through WHERE conversation_id IN ({','.join('?' * len(part))})", tuple(part)
            ):
                known.setdefault(r["conversation_id"], {})[r["capture_id"]] = r["seq"]
        return known

    def known_through(self, device: str, start: float, end: float) -> dict[str, int]:
        """What a conversation closing now knows, per capture: everything processed so far (the
        seal flush counts as chunk last + 1). Finalized captures whose audio is nowhere near the
        window can never matter to it and are left out."""
        gap = self.params.gap
        lo, hi = start - gap - 5, end + gap + 5
        known: dict[str, int] = {}
        for r in self.db.query(
            """SELECT k.capture_id, k.processed_through, k.finalized, k.last_chunk_sequence FROM captures k
               WHERE k.device_id=? AND (k.finalized=0 OR EXISTS (
                   SELECT 1 FROM chunks c WHERE c.capture_id = k.capture_id AND c.audio_start IS NOT NULL
                   AND c.audio_start <= ? AND c.audio_end >= ?))""",
            (device, hi, lo),
        ):
            if r["finalized"] and r["last_chunk_sequence"] is not None:
                known[r["capture_id"]] = r["last_chunk_sequence"] + 1
            elif r["processed_through"] >= 0:
                known[r["capture_id"]] = r["processed_through"]
        return known

    def _evidence(self, device: str, lo: float, hi: float, now: float) -> dict:
        """Coverage, capture spans, sync watermark, policy and losses around [lo, hi]."""
        gap = self.params.gap
        coverage = [
            (r["start"], r["end"])
            for r in self.db.query(
                "SELECT start, end FROM coverage WHERE device_id=? AND kind IN ('live','ring') AND end >= ? AND start <= ?",
                (device, lo, hi),
            )
        ]
        # Heartbeat watermarks: the furthest active one per capture.
        for r in self.db.query(
            """SELECT k.capture_started_at AS s, MAX(c.through_offset_us) AS t FROM coverage c
               JOIN captures k ON k.capture_id = c.capture_id
               WHERE c.device_id=? AND c.kind='heartbeat' AND k.capture_started_at IS NOT NULL
                 AND k.capture_started_at <= ? AND k.processed_through >= c.requires_chunk
               GROUP BY c.capture_id""",
            (device, hi),
        ):
            if r["s"] + r["t"] / 1e6 >= lo:
                coverage.append((r["s"], r["s"] + r["t"] / 1e6))
        losses = [
            (r["start"], r["end"])
            for r in self.db.query(
                "SELECT start, end FROM losses WHERE device_id=? AND end >= ? AND start <= ?", (device, lo - gap, hi + gap)
            )
        ]
        return {
            "coverage": coverage,
            "live_spans": self._live_spans(device, lo, hi),
            "ring_resolved_until": self.ring_watermark(device, now),
            "outside_policy": self._outside_policy(device),
            "live_open": self._live_open(device),
            "losses": losses,
        }

    def _live_spans(self, device: str, lo: float, hi: float) -> list[seg.Span]:
        """Spans of live/replay captures near [lo, hi], using monotonic seal ends."""
        live_like = "device_id=? AND source IN ('live_ble','wav_replay') AND capture_started_at IS NOT NULL"
        captures = self.db.query(
            f"""SELECT * FROM capture_times WHERE {live_like} AND capture_started_at <= ?
                AND (seal_json IS NULL OR seal_end >= ?) ORDER BY capture_started_at""",
            (device, hi, lo),
        )
        following = self.db.one(
            f"SELECT capture_started_at FROM captures WHERE {live_like} AND capture_started_at > ? ORDER BY capture_started_at LIMIT 1",
            (device, hi),
        )
        spans: list[seg.Span] = []
        for i, cap in enumerate(captures):
            end = seal_end_epoch(cap)
            if end is not None:
                got = self.db.one(
                    "SELECT COUNT(*) AS n, MAX(end_epoch) AS e FROM chunks WHERE capture_id=?", (cap["capture_id"],)
                )
                if got["n"] == cap["last_chunk_sequence"] + 1:
                    # Every chunk is here: the chunks are the whole capture; anything the seal
                    # claims beyond the last chunk is outside the connection (disconnect gap).
                    end = min(end, got["e"]) if got["e"] is not None else cap["capture_started_at"]
            elif i + 1 < len(captures):
                end = captures[i + 1]["capture_started_at"]  # one BLE connection at a time
            elif following is not None:
                end = following["capture_started_at"]
            spans.append(seg.Span(cap["capture_started_at"], end))
        return spans

    def _outside_policy(self, device: str) -> seg.OutsidePolicy:
        """How time outside live connections resolves: replay-only devices need no evidence; a
        device that cannot record offline has known losses there; everything else waits for a
        processed offline-storage sync."""
        sources = {r["source"] for r in self.db.query("SELECT DISTINCT source FROM captures WHERE device_id=?", (device,))}
        if sources == {"wav_replay"}:
            return "none"
        live = self.db.one(
            "SELECT offline_storage FROM captures WHERE device_id=? AND source='live_ble' AND capture_started_at IS NOT NULL "
            "ORDER BY capture_started_at DESC LIMIT 1",
            (device,),
        )
        return "loss" if live is not None and live["offline_storage"] == 0 else "wait"

    def _live_open(self, device: str) -> bool:
        latest = self.db.one(
            """SELECT seal_json FROM captures WHERE device_id=? AND source IN ('live_ble','wav_replay')
               AND capture_started_at IS NOT NULL ORDER BY capture_started_at DESC LIMIT 1""",
            (device,),
        )
        return latest is not None and latest["seal_json"] is None

    def ring_watermark(self, device: str, now: float) -> float | None:
        return seg.ring_resolved_until(ring_captures(self.db, device, now), processed_ring_ranges(self.db, device))

    def capture_reached(self, capture_id: str, t: float) -> bool:
        """The capture's audio up to `t` has been processed (or the whole capture has)."""
        reached = self.db.one(
            """SELECT MAX(c.end_epoch) AS m FROM chunks c JOIN captures k ON k.capture_id = c.capture_id
               WHERE c.capture_id=? AND c.chunk_sequence <= k.processed_through""",
            (capture_id,),
        )["m"]
        cap = self.db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
        complete = cap is not None and cap["last_chunk_sequence"] is not None and cap["processed_through"] >= cap["last_chunk_sequence"]
        return complete or (reached is not None and reached >= t)

    def capture_end(self, capture_id: str) -> float | None:
        """Wall-clock end of the capture's audio received so far."""
        return self.db.one("SELECT MAX(end_epoch) AS m FROM chunks WHERE capture_id=?", (capture_id,))["m"]

    def enrollment_windows(self, device: str, now: float) -> list:
        return enroll.settle(enroll.windows(self.db, device), now, self.enrollments.capture_finished, self.capture_end)

    def effective_splits(self, device: str, lo: float, hi: float, now: float) -> list[float]:
        """Double-tap times and voice-enrollment window boundaries in [lo, hi] whose capture audio
        up to that moment has been processed."""
        points = [(ev["t"], ev["capture_id"]) for ev in self.db.query(
            "SELECT * FROM event_times WHERE device_id=? AND type='button' AND code=2 AND t BETWEEN ? AND ?",
            (device, lo, hi),
        )]  # fmt: skip
        points += [(t, cap) for t, cap in enroll.boundaries(self.enrollment_windows(device, now)) if lo <= t <= hi]
        return sorted(t for t, cap in points if not cap or self.capture_reached(cap, t))

    def segment_device(self, device: str, now: float) -> int:
        """Apply `segmenter.segment` for one device. Open conversations are recomputed every tick
        (their id derives from device + start, so the same decision gets the same id after a
        rebuild); a closing one gets its permanent record written before the index says so."""
        timeline = self.device_timeline(device, now)
        open_rows = {r["id"]: r for r in self.db.query("SELECT * FROM conversations WHERE device_id=? AND status='open'", (device,))}
        candidates = seg.segment(timeline, now, self.params) if timeline else []
        if timeline:
            for speech_id in seg.fully_claimed(timeline):
                self.db.execute("UPDATE speech SET claimed_by='*' WHERE id=?", (speech_id,))
        keep: set[str] = set()
        changes = 0
        windows = self.enrollment_windows(device, now)
        for c in candidates:
            conv_id = self._conversation_id(device, c.start)
            keep.add(conv_id)
            fields = {
                "start": c.start,
                "end": c.end,
                "speech_seconds": c.speech_seconds,
                "blocks_json": json.dumps(c.blocks),
                "gaps_json": json.dumps(c.audio_gaps),
                "lost_seconds": c.lost_seconds,
                "late_audio": int(c.late_audio),
                "related_id": c.related_id,
                "start_explicit": int(c.start_explicit),
                "end_explicit": int(c.end_explicit),
                "waiting_for": c.waiting_for or None,
            }
            current = open_rows.get(conv_id)
            if current is None:
                self.db.execute(
                    "INSERT INTO conversations (id, device_id, start, end, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
                    (conv_id, device, c.start, c.end, "open", now, now),
                )
                current = self.db.one("SELECT * FROM conversations WHERE id=?", (conv_id,))
                changes += 1
            verdict = enroll.classify(windows, c.start, c.end, now, self.enrollments.capture_finished) if c.closed else None
            if verdict and verdict[0] == "wait":
                # its enrollment window's end isn't known yet: stay open, so the reading can't reach STT
                fields["waiting_for"] = "voice enrollment"
                if any(current[k] != v for k, v in fields.items()):
                    fields["updated_at"] = now
                    self.db.execute(f"UPDATE conversations SET {', '.join(f'{k}=?' for k in fields)} WHERE id=?",
                                    (*fields.values(), conv_id))  # fmt: skip
                continue
            if c.closed:
                sources, clock_suspect = self._sources(device, c.start, c.end)
                fields |= {"status": "closed", "provisional": int(c.provisional), "finalized_at": now,
                           "sources_json": json.dumps(sources), "clock_suspect": int(clock_suspect), "waiting_for": None}  # fmt: skip
                if verdict and verdict[0] == "inside":
                    # the wearer's enrollment reading: finalized as discarded, never transcribed
                    fields |= {"status": "discarded", "enrollment_id": verdict[1], "stub_path": None}
                    if current["stub_path"]:
                        remove(self.settings.vault_dir / current["stub_path"])
                self._close(current, fields, self.known_through(device, c.start, c.end), now)
                self.pipeline.mark_day(c.start)
                changes += 1
                log.info("conversation %s closed (%s)%s%s", conv_id, device[:8], " provisionally" if c.provisional else "",
                         " as a voice enrollment" if verdict else "")  # fmt: skip
            elif any(current[k] != v for k, v in fields.items()):
                fields["updated_at"] = now
                self.db.execute(f"UPDATE conversations SET {', '.join(f'{k}=?' for k in fields)} WHERE id=?",
                                (*fields.values(), conv_id))  # fmt: skip
                self.pipeline.mark_day(c.start)
        for conv_id, r in open_rows.items():
            if conv_id not in keep:
                if r["stub_path"]:
                    remove(self.settings.vault_dir / r["stub_path"])
                self.db.execute("DELETE FROM conversations WHERE id=?", (conv_id,))
                self.pipeline.mark_day(r["start"])
                changes += 1
        return changes

    def _conversation_id(self, device: str, start: float) -> str:
        conv_id = uuid7_for(start, f"{device}|{start:.6f}")
        clash = self.db.one("SELECT status FROM conversations WHERE id=?", (conv_id,))
        if clash is not None and clash["status"] != "open":  # late audio starting exactly at a finalized start
            conv_id = uuid7_for(start, f"{device}|{start:.6f}|late")
        return conv_id

    def _close(self, row, fields: dict, known: dict[str, int], now: float) -> None:
        """Finalize: the permanent record first, then the index (row, known_through, claims)."""
        conv_id = row["id"]
        record = record_from_row(dict(row) | fields, known)
        sha = write_record(self.vault, record)
        fields = fields | {"record_sha": sha, "updated_at": now}
        with self.db.tx() as conn:
            conn.execute(f"UPDATE conversations SET {', '.join(f'{k}=?' for k in fields)} WHERE id=?",
                         (*fields.values(), conv_id))  # fmt: skip
            conn.execute("DELETE FROM known_through WHERE conversation_id=?", (conv_id,))
            conn.executemany("INSERT INTO known_through (conversation_id, capture_id, seq) VALUES (?,?,?)",
                             [(conv_id, cap, seq) for cap, seq in known.items()])  # fmt: skip
            conn.execute(
                """UPDATE speech SET claimed_by=? WHERE device_id=? AND claimed_by IS NULL AND start >= ? AND end <= ?
                   AND chunk_sequence <= (SELECT k.seq FROM known_through k
                                          WHERE k.conversation_id=? AND k.capture_id = speech.capture_id)""",
                (conv_id, row["device_id"], fields["start"] - 1e-6, fields["end"] + 1e-6, conv_id),
            )
            # A bookmark near finished notes may now belong to this conversation: re-render them
            # (from cache) so a note never keeps a bookmark it lost, whatever order things arrived in.
            reach = BOOKMARK_REACH
            conn.execute(
                """UPDATE conversations SET needs_render=1 WHERE device_id=? AND id<>? AND note_path IS NOT NULL
                   AND status IN ('done','discarded','failed') AND end >= ? AND start <= ? AND EXISTS (
                       SELECT 1 FROM event_times e WHERE e.device_id = conversations.device_id AND e.type='button'
                       AND e.code=1 AND e.t BETWEEN conversations.start - ? AND conversations.end + ?)""",
                (row["device_id"], conv_id, fields["start"] - 2 * reach, fields["end"] + 2 * reach, reach, reach),
            )

    def _sources(self, device: str, start: float, end: float) -> tuple[list[str], bool]:
        rows = self.db.query(
            """SELECT source, stats_json FROM chunks WHERE device_id=? AND status='processed'
               AND audio_start IS NOT NULL AND audio_start <= ? AND audio_end >= ?""",
            (device, end, start),
        )
        sources = sorted({SOURCE_LABEL.get(r["source"], r["source"]) for r in rows})
        clock_suspect = any(json.loads(r["stats_json"] or "{}").get("clock_suspect") for r in rows)
        return sources, clock_suspect

    # -- retention -------------------------------------------------------------------------------

    def retention(self, now: float) -> int:
        """Delete raw chunk files older than RAW_RETENTION_DAYS, except any chunk inside the decode
        range (first..last chunk of each capture, empty ones included) of a conversation that is
        unfinished, finished within the retention period, or still being assembled."""
        cutoff = now - self.settings.raw_retention_days * 86400
        protected: set[tuple[str, int]] = set()
        placeholders = ",".join("?" * (len(PENDING) + 1))
        needed = self.db.query(
            f"""SELECT device_id, start, end FROM conversations
                WHERE status IN ({placeholders}) OR COALESCE(done_at, 0) > ?""",
            (*PENDING, "failed", cutoff),
        )
        spans = [(r["device_id"], r["start"], r["end"]) for r in needed]
        spans += [
            (r["device_id"], r["start"], r["end"])
            for r in self.db.query("SELECT device_id, start, end FROM speech WHERE claimed_by IS NULL")
        ]
        # an undecided voice enrollment keeps its window's audio until the result is written
        spans += [(w.device_id, w.start, w.end if w.end is not None else now) for w in self.enrollments.undecided()]
        for device, start, end in spans:
            for r in self.db.query(
                """SELECT capture_id, MIN(chunk_sequence) AS lo, MAX(chunk_sequence) AS hi FROM chunks
                   WHERE device_id=? AND audio_start IS NOT NULL AND audio_start <= ? AND audio_end >= ?
                   GROUP BY capture_id""",
                (device, end + 2, start - 2),
            ):
                protected.update((r["capture_id"], s) for s in range(r["lo"], r["hi"] + 1))
        by_capture: dict[str, list] = {}
        for chunk in self.db.query(
            "SELECT * FROM chunks WHERE status='processed' AND raw_deleted=0 AND received_at < ? ORDER BY capture_id, chunk_sequence",
            (cutoff,),
        ):
            if (chunk["capture_id"], chunk["chunk_sequence"]) not in protected:
                by_capture.setdefault(chunk["capture_id"], []).append(chunk)
        deleted = 0
        for capture_id, chunks in by_capture.items():
            try:
                deleted += self._expire(capture_id, chunks, now)
            except Exception:  # one capture's problem must not stop the others
                log.exception("retention: could not expire raw audio of capture %s", capture_id)
        if deleted:
            log.info("retention: deleted %d raw chunks", deleted)
        try:  # every pass, so a cleanup a crash interrupted is finished
            self.pipeline.speakers.reconcile_vectors()
        except Exception:
            log.exception("retention: could not reconcile stored voice vectors")
        return deleted

    def _expire(self, capture_id: str, chunks: list, now: float) -> int:
        """Delete raw chunks of one capture: first `capture.json` (what they contributed: chunk
        facts, coverage, losses, ring ownership, tentative speech, continuation checkpoints), then
        a `<seq>.gone` tombstone per chunk, then the `.omnc` files, then the index."""
        capture = self.db.one("SELECT * FROM captures WHERE capture_id=?", (capture_id,))
        device = capture["device_id"]
        already = {r["chunk_sequence"] for r in self.db.query(
            "SELECT chunk_sequence FROM chunks WHERE capture_id=? AND raw_deleted=1", (capture_id,))}  # fmt: skip
        seqs = sorted(already | {c["chunk_sequence"] for c in chunks})
        Vault.write_json(self.vault.capture_json_path(device, capture_id), self._evidence_for(capture, set(seqs)))
        for chunk in chunks:
            path = self.vault.root / chunk["path"]
            header = parse_envelope(path.read_bytes()).header.model_dump(mode="json")
            tomb = {"sha256": chunk["sha256"], "size": chunk["size"], "header": header, "deleted_at": now}
            Vault.write_json(self.vault.tombstone_path(device, capture_id, chunk["chunk_sequence"]), tomb, pretty=False)
        for chunk in chunks:
            remove(self.vault.root / chunk["path"])
        with self.db.tx() as conn:
            conn.executemany("UPDATE chunks SET raw_deleted=1 WHERE capture_id=? AND chunk_sequence=?",
                             [(capture_id, c["chunk_sequence"]) for c in chunks])  # fmt: skip
        self._prune_voices(device, chunks)
        return len(chunks)

    def _prune_voices(self, device: str, chunks: list) -> None:
        """Unknown-voice vectors live only as long as the conversation's raw audio."""
        self.pipeline.speakers.reconcile_vectors()

    def _evidence_for(self, capture, seqs: set[int]) -> dict:
        capture_id = capture["capture_id"]
        marks = ",".join("?" * len(seqs))
        args = (capture_id, *sorted(seqs))
        deleted = {}
        for c in self.db.query(f"SELECT * FROM chunks WHERE capture_id=? AND chunk_sequence IN ({marks})", args):
            seq = c["chunk_sequence"]
            deleted[str(seq)] = {
                "audio_start": c["audio_start"],
                "audio_end": c["audio_end"],
                "runs": json.loads(c["runs_json"] or "[]"),
                "stats": json.loads(c["stats_json"] or "{}"),
                # continuation checkpoint: decoding can resume after the last deleted chunk of a run
                "carry": json.loads(c["carry_json"]) if c["carry_json"] and seq + 1 not in seqs else None,
            }
        rows = lambda sql: [list(r) for r in self.db.query(sql.format(marks=marks), args)]  # noqa: E731
        return {
            "capture_id": capture_id,
            "device_id": capture["device_id"],
            "finalized": bool(capture["finalized"]),
            "deleted": deleted,
            "coverage": rows("""SELECT chunk_sequence, kind, start, end FROM coverage WHERE capture_id=?
                                AND chunk_sequence IN ({marks}) AND kind IN ('live','ring') ORDER BY id"""),
            "losses": rows("""SELECT chunk_sequence, start, end, kind, count FROM losses WHERE capture_id=?
                              AND chunk_sequence IN ({marks}) AND kind <> 'ring_dropped' ORDER BY id"""),
            "ring_seen": rows("""SELECT chunk_sequence, ring_seq, record_hash FROM ring_seen WHERE capture_id=?
                                 AND chunk_sequence IN ({marks}) ORDER BY ring_seq"""),
            "ring_records": rows("""SELECT chunk_sequence, ring_seq, record_hash FROM ring_records WHERE capture_id=?
                                    AND chunk_sequence IN ({marks}) ORDER BY ring_seq"""),
            "speech_open": rows("""SELECT chunk_sequence, start, end FROM speech WHERE capture_id=? AND open=1
                                   AND chunk_sequence IN ({marks}) ORDER BY id"""),
        }


def store_speech(conn, device: str, capture_id: str, seq: int, completed: list, open_segment) -> None:
    """Store VAD speech so that audio, once stored, keeps its row identity.

    Speech still in progress at a chunk end is stored as *tentative* (`open=1`) rows. When a later
    chunk continues it, the existing rows are kept (confirmed, or extended in place by less than
    `MIN_SPEECH`) and only the genuinely new stretch gets a new row. So a conversation finalized
    over a tentative row (a double-tap split, a provisional close) never sees that audio again
    under a new identity, which would otherwise make it "late audio" a second time. A segment
    that ends up shorter than `MIN_SPEECH` drops the tentative rows nobody has claimed yet.
    """
    tentative = conn.execute(
        "SELECT id, start, end FROM speech WHERE capture_id=? AND open=1 ORDER BY end", (capture_id,)
    ).fetchall()
    seg_start = min((r["start"] for r in tentative), default=None)

    def continues(a: float) -> bool:
        return seg_start is not None and abs(a - seg_start) < 1e-6

    def insert(a: float, b: float, is_open: int) -> None:
        conn.execute(
            "INSERT INTO speech (device_id, start, end, capture_id, chunk_sequence, open) VALUES (?,?,?,?,?,?)",
            (device, a, b, capture_id, seq, is_open),
        )

    def extend(b: float, is_open: int) -> None:
        last = tentative[-1]
        if b - last["end"] >= MIN_SPEECH:
            insert(last["end"], b, is_open)
        elif b > last["end"]:
            conn.execute("UPDATE speech SET end=? WHERE id=?", (b, last["id"]))

    for a, b in completed:
        if continues(a):
            if b - a >= MIN_SPEECH:
                extend(b, 0)
            else:
                # Kept only for a conversation finalized *over* them: one that knew the rows but not
                # this chunk (a conversation finalized later saw them deleted). The rule reads
                # known_through, not the current set of conversations, so a rebuild's replay (which
                # has every record from the start) decides exactly as the first pass did.
                conn.execute(
                    """DELETE FROM speech WHERE capture_id=? AND open=1 AND NOT EXISTS (
                           SELECT 1 FROM conversations c JOIN known_through k
                             ON k.conversation_id = c.id AND k.capture_id = speech.capture_id
                           WHERE c.device_id = speech.device_id AND c.status <> 'open'
                             AND k.seq >= speech.chunk_sequence AND k.seq < ?
                             AND c.start < speech.end AND c.end > speech.start)""",
                    (capture_id, seq),
                )
            conn.execute("UPDATE speech SET open=0 WHERE capture_id=? AND open=1", (capture_id,))
            tentative, seg_start = [], None
        elif b - a >= MIN_SPEECH:
            insert(a, b, 0)
    if open_segment:
        a, b = open_segment
        if continues(a):
            extend(b, 1)
        else:
            insert(a, b, 1)


def read_only_reason(db: Database) -> str | None:
    """Why the vault must not be written right now (incomplete vault, divergence, lost lease)."""
    for key in ("read_only", "divergence", "fenced"):
        value = db.meta(key)
        if value:
            return value
    return None
