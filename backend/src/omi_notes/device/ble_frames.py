"""Live BLE notification → Opus frame reassembly (device-protocol.md, "Live audio notification framing").

Firmware framing is `[seq:u16 LE][fragment_index:u8][payload…]`. `seq` counts notifications (not
frames), wraps at 65536 and is never reset on reconnect; a frame ends when the next fragment 0
arrives. The assembler is stateful per capture and its state round-trips through JSON so chunk
processing can resume exactly where the previous chunk stopped.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

from ..envelope import FLAG_SESSION_START

# Lost notifications up to this count are concealed with Opus PLC; larger gaps are treated as a
# discontinuity (decoder reset, new timeline run anchored on the next receive time).
MAX_PLC_FRAMES = 25
# A sequence number at most this far *behind* the last one is a stale re-delivery and dropped.
# Anything further behind cannot be stale (receive times only move forward): it is a jump, and
# the assembler resynchronizes on it instead of discarding audio until the counter wraps around.
STALE_WINDOW = 64


@dataclass(frozen=True)
class FrameEvent:
    """`frame`: one complete Opus packet; `lost`: `count` missing frames (PLC); `reset`: discontinuity
    (`reason` session_start | gap | resync; `count` = notifications known to be lost, if any)."""

    kind: Literal["frame", "lost", "reset"]
    t_us: int
    data: bytes = b""
    count: int = 0
    reason: str = ""


@dataclass
class AssemblerStats:
    notifications: int = 0
    frames: int = 0
    duplicates: int = 0
    lost_notifications: int = 0
    dropped_partial: int = 0
    orphan_fragments: int = 0
    malformed: int = 0
    discontinuities: int = 0

    def as_dict(self) -> dict[str, int]:
        return dict(self.__dict__)


@dataclass
class BleFrameAssembler:
    last_seq: int | None = None
    pending: bytearray | None = None
    pending_idx: int = 0
    pending_t_us: int = 0
    stats: AssemblerStats = field(default_factory=AssemblerStats)

    def feed(self, t_us: int, flags: int, data: bytes) -> list[FrameEvent]:
        """Consume one raw notification received at capture-relative monotonic time `t_us`."""
        events: list[FrameEvent] = []
        if flags & FLAG_SESSION_START:
            # The pending frame is almost always complete (one notification per frame at normal
            # MTU); if it is not, the decoder turns the failure into a lost frame.
            events.extend(self.flush())
            events.append(FrameEvent("reset", t_us, reason="session_start"))
            self.last_seq = None
        if len(data) <= 3:
            self.stats.malformed += 1
            return events
        self.stats.notifications += 1
        seq = data[0] | (data[1] << 8)
        idx = data[2]
        payload = data[3:]

        if self.last_seq is not None:
            gap = (seq - self.last_seq) & 0xFFFF
            behind = (self.last_seq - seq) & 0xFFFF
            if gap == 0 or behind <= STALE_WINDOW:
                self.stats.duplicates += 1  # exact duplicate or a stale re-delivery
                return events
            if gap >= 0x8000:
                # Far outside the window either way: the counter jumped. Resynchronize.
                if self.pending is not None:
                    self.pending = None
                    self.stats.dropped_partial += 1
                self.stats.discontinuities += 1
                events.append(FrameEvent("reset", t_us, reason="resync"))
            elif gap > 1:
                lost = gap - 1
                self.stats.lost_notifications += lost
                # The pending frame precedes the loss. At normal MTU every frame is a single
                # notification, so it is almost always complete: emit it and let a decode failure
                # count as a lost frame, rather than always discarding ~one frame of good audio.
                events.extend(self.flush())
                if lost <= MAX_PLC_FRAMES:
                    events.append(FrameEvent("lost", t_us, count=lost))
                else:
                    self.stats.discontinuities += 1
                    events.append(FrameEvent("reset", t_us, count=lost, reason="gap"))
        self.last_seq = seq

        if idx == 0:
            events.extend(self.flush())
            self.pending = bytearray(payload)
            self.pending_idx = 0
            self.pending_t_us = t_us
        elif self.pending is not None and idx == self.pending_idx + 1:
            self.pending.extend(payload)
            self.pending_idx = idx
        else:
            # Continuation without its start (fragment 0 lost) or an index jump.
            self.stats.orphan_fragments += 1
            if self.pending is not None:
                self.pending = None
                self.stats.dropped_partial += 1
                events.append(FrameEvent("lost", t_us, count=1))
        return events

    def flush(self) -> list[FrameEvent]:
        """Emit the pending frame as complete (at a session boundary or the end of a capture)."""
        if self.pending is None:
            return []
        frame = FrameEvent("frame", self.pending_t_us, data=bytes(self.pending))
        self.pending = None
        self.stats.frames += 1
        return [frame]

    def to_state(self) -> dict:
        return {
            "last_seq": self.last_seq,
            "pending": self.pending.hex() if self.pending is not None else None,
            "pending_idx": self.pending_idx,
            "pending_t_us": self.pending_t_us,
        }

    @classmethod
    def from_state(cls, state: dict | None) -> BleFrameAssembler:
        if not state:
            return cls()
        pending = state.get("pending")
        return cls(
            last_seq=state.get("last_seq"),
            pending=bytearray.fromhex(pending) if pending is not None else None,
            pending_idx=int(state.get("pending_idx", 0)),
            pending_t_us=int(state.get("pending_t_us", 0)),
        )


def encode_notification(seq: int, fragment_index: int, payload: bytes) -> bytes:
    """Firmware-format notification bytes (used by dev tooling and tests)."""
    return bytes((seq & 0xFF, (seq >> 8) & 0xFF, fragment_index & 0xFF)) + payload
