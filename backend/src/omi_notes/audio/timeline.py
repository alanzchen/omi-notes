"""Decode a capture's chunks, in order, into timestamped PCM *pieces*.

One `CaptureTimeline` decodes one capture with ONE Opus decoder whose state carries across chunk
boundaries; it is reset at `SESSION_START` and at discontinuities. After each chunk the timing and
framing state is exported as a JSON "carry" dict and stored with the chunk. Restoring from the
carry of chunk n-1 and decoding chunk n reproduces exactly the timestamps the first pass produced,
which is how the STT stage re-decodes audio on demand (PCM is never persisted). The Opus decoder's
internal state is not serialized: a restored timeline starts with a fresh decoder, which only
affects the first few milliseconds of the first frame.

Timing:
- live (`ble_notifications_v1`): sample-count timing anchored on the receive time of the first
  frame of a run (`capture_started_at + chunk_start_offset_us + t_offset_us`). A frame received
  more than 1.5 s after the expected position starts a new run (the mic sleeps during silence, or
  frames vanished before getting a sequence number). Early (bursty) arrivals are ignored.
- ring (`ring_records_v1`): anchored on each record's device RTC second; a timestamp more than
  1.5 s beyond the expected position starts a new run. A timestamp more than 2 s *behind* it (the
  device clock was corrected) also starts a new, re-anchored run and is counted as
  `clock_suspect`. Records already stored for the device by another chunk (same ring sequence and
  bytes) are skipped.

Known losses (missing notifications, ring sequence gaps) are reported as `losses` intervals so
notes can warn about them; silence (mic asleep, timestamp jumps with contiguous records) is not.
- pcm (`pcm16le_v1`): the chunk's samples start at `chunk_start_offset_us`.
"""

from __future__ import annotations

import hashlib
from collections.abc import Callable
from dataclasses import dataclass, field

import numpy as np

from ..device.ble_frames import AssemblerStats, BleFrameAssembler, FrameEvent
from ..device.ring_records import parse_record
from ..envelope import Envelope
from . import aac
from .opus import OpusDecoder, OpusError

SAMPLE_RATE = 16000
RUN_GAP_SECONDS = 1.5
CLOCK_BACK_TOLERANCE = 2.0  # ring timestamps are whole seconds; sample timing may run ~1 s ahead
RING_RECORD_SECONDS = 0.1  # ~5 frames per 444-byte record; used to size losses of unknown length
PCM_CONTINUITY_SECONDS = 0.05

# (start epoch, end epoch, kind, count of lost notifications/records)
Loss = tuple[float, float, str, int]

# (device ring sequence, sha1 of record bytes) -> True if another chunk already owns this record
RingSeen = Callable[[int, str], bool]


@dataclass
class Piece:
    """Contiguous decoded audio. `continues` = sample-continuous with the previous piece of this capture."""

    start: float
    pcm: np.ndarray
    continues: bool = False

    @property
    def end(self) -> float:
        return self.start + len(self.pcm) / SAMPLE_RATE


@dataclass
class ChunkDecode:
    pieces: list[Piece]
    stats: dict
    carry: dict
    ring_records: list[tuple[int, str]] = field(default_factory=list)
    losses: list[Loss] = field(default_factory=list)


@dataclass
class _Stats:
    frames: int = 0
    plc_frames: int = 0
    decode_errors: int = 0
    runs: int = 0
    resets: int = 0
    ring_records: int = 0
    ring_duplicates: int = 0
    ring_seq_gaps: int = 0
    clock_suspect: int = 0


class CaptureTimeline:
    def __init__(self, frame_samples: int, carry: dict | None = None, ring_seen: RingSeen | None = None) -> None:
        carry = carry or {}
        self.frame_samples = frame_samples or 320
        self.assembler = BleFrameAssembler.from_state(carry.get("assembler"))
        self.run_start: float | None = carry.get("run_start")
        self.run_samples: int = int(carry.get("run_samples", 0))
        self.last_ring_seq: int | None = carry.get("last_ring_seq")
        # A discontinuity whose end is only known when the next audio arrives: [start, kind, count].
        self.loss_open: list | None = carry.get("loss_open")
        self.ring_seen = ring_seen
        self.decoder = OpusDecoder()
        self._pieces: list[Piece] = []
        self._current: list[np.ndarray] = []
        self._current_start: float | None = None
        self._current_continues = False
        self._stats = _Stats()
        self._losses: list[Loss] = []

    # -- public ----------------------------------------------------------------------------------

    def decode_chunk(self, env: Envelope, *, final: bool = False) -> ChunkDecode:
        """Decode one chunk. `final` = last chunk of a sealed capture (flush the pending frame)."""
        self._begin_chunk()
        header = env.header
        ring_records: list[tuple[int, str]] = []
        if header.payload_format == "ble_notifications_v1":
            anchor = header.capture_started_at.timestamp()
            base_us = header.chunk_start_offset_us
            for rec in env.ble_records():
                for event in self.assembler.feed(base_us + rec.t_offset_us, rec.flags, rec.data):
                    self._on_live_event(event, anchor)
            if final:
                for event in self.assembler.flush():
                    self._on_live_event(event, anchor)
        elif header.payload_format == "ring_records_v1":
            first = header.ring.first_sequence  # type: ignore[union-attr]
            for index, raw in enumerate(env.ring_records()):
                ring_seq = first + index
                digest = hashlib.sha1(raw).hexdigest()
                if self.ring_seen is not None and self.ring_seen(ring_seq, digest):
                    self._stats.ring_duplicates += 1
                    self._discontinuity()
                    self.last_ring_seq = ring_seq
                    continue
                ring_records.append((ring_seq, digest))
                self._on_ring_record(ring_seq, raw)
        else:
            if header.payload_format == "aac_m4a_v1":
                pcm = aac.decode(env.payload, header.record_count)
            else:
                pcm = np.frombuffer(env.payload, dtype="<i2").astype(np.int16)
            start = header.chunk_start_epoch
            expected = self._expected()
            if expected is None or abs(start - expected) > PCM_CONTINUITY_SECONDS:
                self._new_run(start)
            self._append(pcm)

        return self._result(final, ring_records)

    def finish(self, anchor: float) -> ChunkDecode:
        """Flush the frame still pending from an already-processed last chunk (seal came later)."""
        self._begin_chunk()
        for event in self.assembler.flush():
            self._on_live_event(event, anchor)
        return self._result(True, [])

    def carry(self) -> dict:
        return {
            "assembler": self.assembler.to_state(),
            "run_start": self.run_start,
            "run_samples": self.run_samples,
            "last_ring_seq": self.last_ring_seq,
            "loss_open": self.loss_open,
        }

    def _result(self, final: bool, ring_records: list[tuple[int, str]]) -> ChunkDecode:
        self._close_piece()
        stats = dict(self._stats.__dict__)
        stats.update({f"ble_{k}": v for k, v in self.assembler.stats.as_dict().items()})
        stats["final"] = final
        return ChunkDecode(self._pieces, stats, self.carry(), ring_records, self._losses)

    # -- live ------------------------------------------------------------------------------------

    def _on_live_event(self, event: FrameEvent, anchor: float) -> None:
        if event.kind == "reset":
            expected = self._expected()
            if event.reason != "session_start" and expected is not None:
                self.loss_open = [expected, f"ble_{event.reason}", event.count]
            self._discontinuity()
            return
        if event.kind == "lost":
            expected = self._expected()
            if expected is None:
                return  # nothing to conceal before the first frame of a run
            self._losses.append((expected, expected + event.count * self.frame_samples / SAMPLE_RATE, "ble_lost", event.count))
            for _ in range(event.count):
                self._append(self.decoder.conceal(self.frame_samples))
                self._stats.plc_frames += 1
            return
        received = anchor + event.t_us / 1e6
        expected = self._expected()
        if expected is None or received > expected + RUN_GAP_SECONDS:
            self._close_loss(received)
            self._new_run(received)
        self._decode(event.data)

    def _close_loss(self, until: float, minimum: float = 0.0) -> None:
        if self.loss_open is None:
            return
        start, kind, count = self.loss_open
        self._losses.append((start, max(until, start + minimum), kind, count))
        self.loss_open = None

    # -- ring ------------------------------------------------------------------------------------

    def _on_ring_record(self, ring_seq: int, raw: bytes) -> None:
        self._stats.ring_records += 1
        record = parse_record(raw)
        stamp = float(record.timestamp)
        if self.last_ring_seq is not None and ring_seq != self.last_ring_seq + 1:
            self._stats.ring_seq_gaps += 1
            missing = ring_seq - self.last_ring_seq - 1
            expected = self._expected()
            if missing > 0 and expected is not None:
                self.loss_open = [expected, "ring_seq_gap", missing]
            self._discontinuity()
            self._close_loss(stamp, minimum=max(missing, 0) * RING_RECORD_SECONDS)
        self.last_ring_seq = ring_seq
        expected = self._expected()
        if expected is None or stamp > expected + RUN_GAP_SECONDS:
            self._new_run(stamp)
        elif stamp < expected - CLOCK_BACK_TOLERANCE:
            self._stats.clock_suspect += 1  # device clock corrected backwards: re-anchor, flag it
            self._new_run(stamp)
        for frame in record.frames:
            self._decode(frame)

    # -- shared ----------------------------------------------------------------------------------

    def _decode(self, packet: bytes) -> None:
        try:
            pcm = self.decoder.decode(packet)
        except OpusError:
            self._stats.decode_errors += 1
            pcm = self.decoder.conceal(self.frame_samples)
        self._stats.frames += 1
        self._append(pcm)

    def _expected(self) -> float | None:
        if self.run_start is None:
            return None
        return self.run_start + self.run_samples / SAMPLE_RATE

    def _discontinuity(self) -> None:
        self._stats.resets += 1
        self._close_piece()
        self.run_start = None
        self.run_samples = 0
        self.decoder.close()
        self.decoder = OpusDecoder()

    def _new_run(self, start: float) -> None:
        self._close_piece()
        self._stats.runs += 1
        self.run_start = start
        self.run_samples = 0
        self._current_start = start
        self._current_continues = False

    def _begin_chunk(self) -> None:
        self._pieces = []
        self._losses = []
        self._stats = _Stats()
        self.assembler.stats = AssemblerStats()
        self._current = []
        if self.run_start is not None:
            self._current_start = self.run_start + self.run_samples / SAMPLE_RATE
            self._current_continues = True
        else:
            self._current_start = None

    def _append(self, pcm: np.ndarray) -> None:
        if self._current_start is None:
            # Audio that continues a run restored from carry but whose piece was closed.
            self._current_start = self._expected()
            self._current_continues = True
        self._current.append(pcm)
        self.run_samples += len(pcm)

    def _close_piece(self) -> None:
        if self._current and self._current_start is not None:
            pcm = np.concatenate(self._current).astype(np.int16, copy=False)
            if len(pcm):
                self._pieces.append(Piece(self._current_start, pcm, self._current_continues))
        self._current = []
        self._current_start = None
        self._current_continues = False
