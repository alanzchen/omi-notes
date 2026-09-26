"""Per-device conversation segmentation: pure functions, no I/O (architecture.md #7-#10).

Inputs describe one device: speech intervals (padded VAD output), evidence coverage, the live
capture spans, the ring-sync watermark, effective double-tap splits and the conversations that
are already finalized. `segment()` returns every not-yet-finalized conversation as a `Candidate`
saying whether it can close now (and whether that close is provisional).

Rules:
- A gap without speech of `gap` seconds or more splits conversations (`gap >= 120` splits,
  Omi's `gap_splits`). A double-tap at T splits at T.
- Soft cap: past `soft_max` seconds split at the next gap of >= 20 s; hard cap at `hard_max`.
- A conversation spanning [S, E] closes when both boundary windows [S-gap, S] and [E, E+gap] are
  *resolved* (explicit split boundaries need no window). A point in time is resolved by evidence
  (a processed live chunk, an active heartbeat watermark, ring audio), or, outside every live
  capture span, by the device's ring-sync watermark (`sync_complete` seal whose chunks are all
  processed), or immediately when the device cannot fill disconnect gaps (`offline_storage=false`,
  the gap is then a known loss) or the audio came from developer replay.
- Otherwise the close is provisional once `now >= E + gap + wait` (`wait` is short while a live
  capture is unsealed, longer otherwise).
- Finalized conversations are never reopened. Speech that shows up later (a higher speech id
  than the conversation's watermark) inside or within `gap` of a finalized window becomes its own
  conversation with `late_audio=True` and `related_id` set.

Checking the *start* window as well as the end is slightly stricter than architecture.md #8
spells out: after a reconnect, the first live speech must wait for the ring sync so late offline
speech just before it joins the same conversation instead of becoming a late-audio fragment.

Speech intervals are unpadded VAD output (silence is measured between real speech); STT blocks
get 300 ms pre-roll / 1 s tail padding here, clipped at explicit split boundaries. Known losses
(missing notifications, ring sequence gaps, overwritten offline records) are reported with the
audio gaps but never block closing: waiting cannot bring them back.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

Interval = tuple[float, float]
OutsidePolicy = Literal["wait", "loss", "none"]

# Slivers left by float arithmetic between adjacent coverage intervals are ignored.
EPS = 0.25
# Uncovered stretches shorter than this are not reported as audio gaps in notes.
MIN_REPORTED_GAP = 1.0
# Unclaimed remainders of partially claimed speech shorter than this are ignored (VAD minimum).
MIN_REMAINDER = 0.25


@dataclass(frozen=True)
class Speech:
    id: int
    start: float
    end: float


@dataclass(frozen=True)
class Span:
    """A live capture's time span; `end=None` while it is the device's newest capture and unsealed."""

    start: float
    end: float | None


@dataclass(frozen=True)
class Finalized:
    id: str
    start: float
    end: float
    watermark: int
    start_explicit: bool = False
    end_explicit: bool = False


@dataclass(frozen=True)
class Params:
    gap: float = 120.0
    provisional_wait_open: float = 300.0
    provisional_wait: float = 1200.0
    soft_max: float = 10800.0
    hard_max: float = 11400.0
    soft_split_gap: float = 20.0
    block_merge_gap: float = 2.0
    pre_roll: float = 0.3
    tail: float = 1.0


@dataclass(frozen=True)
class DeviceTimeline:
    speech: list[Speech]
    coverage: list[Interval] = field(default_factory=list)
    live_spans: list[Span] = field(default_factory=list)
    ring_resolved_until: float | None = None
    outside_policy: OutsidePolicy = "wait"
    live_open: bool = False
    splits: list[float] = field(default_factory=list)
    finalized: list[Finalized] = field(default_factory=list)
    losses: list[Interval] = field(default_factory=list)


@dataclass
class Candidate:
    start: float
    end: float
    speech_ids: tuple[int, ...]
    blocks: list[Interval]
    speech_seconds: float
    closed: bool
    provisional: bool
    late_audio: bool
    related_id: str | None
    start_explicit: bool
    end_explicit: bool
    audio_gaps: list[Interval]
    waiting_for: str
    lost_seconds: float = 0.0


@dataclass
class _Piece:
    start: float
    end: float
    speech_id: int
    late_of: str | None = None


# -- interval helpers ----------------------------------------------------------------------------


def union(intervals: list[Interval]) -> list[Interval]:
    out: list[list[float]] = []
    for a, b in sorted(intervals):
        if b <= a:
            continue
        if out and a <= out[-1][1] + EPS:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


def subtract(base: list[Interval], remove: list[Interval]) -> list[Interval]:
    """`base` minus `remove` (both arbitrary lists); result sorted and disjoint."""
    result = union(base)
    for ra, rb in union(remove):
        nxt: list[Interval] = []
        for a, b in result:
            if rb <= a or ra >= b:
                nxt.append((a, b))
                continue
            if a < ra:
                nxt.append((a, ra))
            if rb < b:
                nxt.append((rb, b))
        result = nxt
    return [(a, b) for a, b in result if b - a > 1e-9]


def merge_exact(intervals: list[Interval]) -> list[Interval]:
    """Union without `union`'s sliver bridging (losses are measured, not smoothed)."""
    out: list[list[float]] = []
    for a, b in sorted(intervals):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        elif b > a:
            out.append([a, b])
    return [(a, b) for a, b in out]


def intersect(base: list[Interval], other: list[Interval]) -> list[Interval]:
    out: list[Interval] = []
    for a, b in union(base):
        for c, d in union(other):
            lo, hi = max(a, c), min(b, d)
            if hi > lo:
                out.append((lo, hi))
    return union(out)


# -- resolution ----------------------------------------------------------------------------------


def _span_intervals(tl: DeviceTimeline, horizon: float) -> list[Interval]:
    return [(s.start, s.end if s.end is not None else horizon) for s in tl.live_spans]


def _outside_resolved(tl: DeviceTimeline, pieces: list[Interval], *, count_loss: bool) -> list[Interval]:
    """Portions of `pieces` (already outside live spans) that the outside policy resolves."""
    if tl.outside_policy == "none" or (tl.outside_policy == "loss" and count_loss):
        return pieces
    if tl.outside_policy == "wait" and tl.ring_resolved_until is not None:
        return intersect(pieces, [(float("-inf"), tl.ring_resolved_until)])
    return []


def resolved(tl: DeviceTimeline, a: float, b: float, now: float) -> bool:
    """True when every moment of [a, b] is accounted for (see module docstring)."""
    if b > now:
        return False
    open_parts = subtract([(a, b)], tl.coverage)
    if not open_parts:
        return True
    horizon = max(now, b) + 1.0
    inside = intersect(open_parts, _span_intervals(tl, horizon))
    if any(y - x > EPS for x, y in inside):
        return False
    outside = subtract(open_parts, _span_intervals(tl, horizon))
    leftover = subtract(outside, _outside_resolved(tl, outside, count_loss=True))
    return not any(y - x > EPS for x, y in leftover)


def audio_gaps(tl: DeviceTimeline, a: float, b: float, now: float) -> list[Interval]:
    """Stretches of [a, b] with no audio evidence that are not explained as silence."""
    open_parts = subtract([(a, b)], tl.coverage)
    horizon = max(now, b) + 1.0
    outside = subtract(open_parts, _span_intervals(tl, horizon))
    gaps = subtract(open_parts, _outside_resolved(tl, outside, count_loss=False))
    return [(x, y) for x, y in gaps if y - x >= MIN_REPORTED_GAP]


# -- grouping ------------------------------------------------------------------------------------


def _unclaimed_pieces(tl: DeviceTimeline, gap: float) -> list[_Piece]:
    pieces: list[_Piece] = []
    for s in tl.speech:
        parts = [(s.start, s.end)]
        claimed = [(f.start, f.end) for f in tl.finalized if s.id <= f.watermark]
        if claimed:
            # A sliver left beside a finalized window is the tail of audio it already has.
            parts = [(a, b) for a, b in subtract(parts, claimed) if b - a >= MIN_REMAINDER]
        if not parts:
            continue
        late_of = None
        best = float("inf")
        for f in tl.finalized:
            if s.id <= f.watermark:
                continue
            lo = f.start - (0.0 if f.start_explicit else gap)
            hi = f.end + (0.0 if f.end_explicit else gap)
            if s.end > lo and s.start < hi:
                distance = max(0.0, f.start - s.end, s.start - f.end)
                if distance < best:
                    best, late_of = distance, f.id
        pieces.extend(_Piece(x, y, s.id, late_of) for x, y in parts)
    pieces.sort(key=lambda p: (p.start, p.end))
    return pieces


def _cut_at(pieces: list[_Piece], t: float) -> list[_Piece]:
    out: list[_Piece] = []
    for p in pieces:
        if p.start < t < p.end:
            out.append(_Piece(p.start, t, p.speech_id, p.late_of))
            out.append(_Piece(t, p.end, p.speech_id, p.late_of))
        else:
            out.append(p)
    return out


@dataclass
class _Group:
    pieces: list[_Piece]
    start_explicit: bool = False
    end_explicit: bool = False

    @property
    def start(self) -> float:
        return self.pieces[0].start

    @property
    def end(self) -> float:
        return max(p.end for p in self.pieces)


def _group(tl: DeviceTimeline, pieces: list[_Piece], p: Params) -> list[_Group]:
    splits = sorted(tl.splits)
    for t in splits:
        pieces = _cut_at(pieces, t)
    pieces.sort(key=lambda x: (x.start, x.end))
    groups: list[_Group] = []
    for piece in pieces:
        if groups:
            g = groups[-1]
            end = g.end
            split_between = any(end - 1e-9 <= t <= piece.start + 1e-9 for t in splits)
            finalized_between = any(end <= f.start and f.end <= piece.start for f in tl.finalized)
            if piece.start - end < p.gap and not split_between and not finalized_between:
                g.pieces.append(piece)
                continue
        groups.append(_Group([piece]))
    for i, g in enumerate(groups):
        prev_end = groups[i - 1].end if i > 0 else float("-inf")
        next_start = groups[i + 1].start if i + 1 < len(groups) else float("inf")
        g.end_explicit = any(g.end - 1e-9 <= t <= next_start and t < g.end + p.gap for t in splits)
        g.start_explicit = any(prev_end <= t <= g.start + 1e-9 and t > g.start - p.gap for t in splits)
    return groups


def _apply_caps(group: _Group, p: Params) -> list[_Group]:
    parts: list[_Group] = []
    pieces = group.pieces
    start_explicit = group.start_explicit
    while pieces:
        soft_at = pieces[0].start + p.soft_max
        hard_at = pieces[0].start + p.hard_max
        head: list[_Piece] | None = None
        tail: list[_Piece] = []
        for k, piece in enumerate(pieces):
            if k and piece.start > soft_at and piece.start - pieces[k - 1].end >= p.soft_split_gap:
                head, tail = pieces[:k], pieces[k:]
                break
            if piece.end > hard_at:
                if piece.start < hard_at:
                    cut = _cut_at([piece], hard_at)
                    head, tail = pieces[:k] + cut[:1], cut[1:] + pieces[k + 1 :]
                else:
                    head, tail = pieces[:k], pieces[k:]
                break
        if head is None or not head:
            parts.append(_Group(pieces, start_explicit, group.end_explicit))
            break
        parts.append(_Group(head, start_explicit, True))
        pieces, start_explicit = tail, True
    return parts


# -- entry point ---------------------------------------------------------------------------------


def segment(tl: DeviceTimeline, now: float, p: Params | None = None) -> list[Candidate]:
    p = p or Params()
    pieces = _unclaimed_pieces(tl, p.gap)
    groups = [part for g in _group(tl, pieces, p) for part in _apply_caps(g, p)]
    wait = p.provisional_wait_open if tl.live_open else p.provisional_wait
    candidates: list[Candidate] = []
    for g in groups:
        start, end = g.start, g.end
        start_ok = g.start_explicit or resolved(tl, start - p.gap, start, now)
        end_ok = g.end_explicit or resolved(tl, end, end + p.gap, now)
        closed = start_ok and end_ok
        provisional = not closed and now >= end + p.gap + wait
        waiting_for = "" if closed else ("end window" if not end_ok else "start window")
        late = [x.late_of for x in g.pieces if x.late_of]
        lo = start if g.start_explicit else float("-inf")
        hi = end if g.end_explicit else float("inf")
        blocks = pad_blocks([(x.start, x.end) for x in g.pieces], p, lo, hi)
        gaps, lost = window_evidence(tl, start, end, now, p)
        candidates.append(
            Candidate(
                start=start,
                end=end,
                speech_ids=tuple(sorted({x.speech_id for x in g.pieces})),
                blocks=blocks,
                speech_seconds=sum(b - a for a, b in union([(x.start, x.end) for x in g.pieces])),
                closed=closed or provisional,
                provisional=provisional,
                late_audio=bool(late),
                related_id=late[0] if late else None,
                start_explicit=g.start_explicit,
                end_explicit=g.end_explicit,
                audio_gaps=gaps,
                waiting_for=waiting_for,
                lost_seconds=lost,
            )
        )
    return candidates


def window_evidence(tl: DeviceTimeline, start: float, end: float, now: float, p: Params) -> tuple[list[Interval], float]:
    """A conversation's reported audio gaps and seconds of known loss. Losses inside it or just
    around it count (it may have begun or ended in them); sub-second ones are only counted."""
    near = [(a, b) for a, b in merge_exact(tl.losses) if b > start - p.gap and a < end + p.gap]
    lost = sum(min(b, end + p.gap) - max(a, start - p.gap) for a, b in near)
    gaps = union(audio_gaps(tl, start, end, now) + [(a, b) for a, b in near if b - a >= MIN_REPORTED_GAP])
    return [(a, b) for a, b in gaps], round(lost, 3)


def pad_blocks(speech: list[Interval], p: Params, lo: float = float("-inf"), hi: float = float("inf")) -> list[Interval]:
    """STT blocks: speech padded 300 ms before / 1 s after, merged when < 2 s apart, kept within
    [lo, hi] (explicit split boundaries must not leak audio into the neighbouring conversation)."""
    padded = [(max(lo, a - p.pre_roll), min(hi, b + p.tail)) for a, b in speech]
    return union_gapped([(a, b) for a, b in padded if b > a], p.block_merge_gap)


@dataclass(frozen=True)
class RingCapture:
    """What the ring watermark needs to know about one offline-storage capture."""

    capture_id: str
    reason: str | None  # seal reason; None while unsealed
    settled: bool  # sealed and every chunk received + processed (or abandoned)
    generation: int | None
    start: float | None  # sync start (capture_started_at), else its coverage/seal time
    covers_until: float | None
    info_read_seq: int | None


def contiguous_through(ranges: list[tuple[int, int]]) -> tuple[int, int] | None:
    """(first, last) of the unbroken run of sequences starting at the lowest one processed."""
    run: tuple[int, int] | None = None
    for lo, hi in sorted(ranges):
        if run is None:
            run = (lo, hi)
        elif lo <= run[1] + 1:
            run = (run[0], max(run[1], hi))
        else:
            break
    return run


def ring_resolved_until(rings: list[RingCapture], processed: dict[int | None, list[tuple[int, int]]]) -> float | None:
    """How far a device's disconnect gaps are proven covered by offline-storage syncs.

    A `sync_complete` capture counts only when it is settled, every earlier ring capture of the
    same generation known to the server is settled too, and ring records are contiguous up to
    where it started reading: within its generation, the records processed so far (`processed`,
    ranges of ring sequences per generation) form one unbroken run from the lowest sequence ever
    seen through `info_read_seq - 1`. A generation with no records before `info_read_seq` (the
    first sync, or the first after a storage reset/reflash) needs nothing more.
    """
    best: float | None = None
    for c in rings:
        if c.reason != "sync_complete" or not c.settled or c.covers_until is None or c.info_read_seq is None:
            continue
        same_gen = [o for o in rings if o is not c and (o.generation is None or o.generation == c.generation)]
        earlier = [o for o in same_gen if o.start is None or o.start <= c.covers_until]
        if not all(o.settled for o in earlier):
            continue
        run = contiguous_through(processed.get(c.generation, []))
        if run is not None and run[0] < c.info_read_seq and run[1] < c.info_read_seq - 1:
            continue  # some records before this sync's read pointer never reached the server
        best = c.covers_until if best is None else max(best, c.covers_until)
    return best


def fully_claimed(tl: DeviceTimeline) -> list[int]:
    """Speech ids entirely inside finalized windows (e.g. a row cut by a split or the hard cap)."""
    ids = []
    for s in tl.speech:
        claimed = [(f.start, f.end) for f in tl.finalized if s.id <= f.watermark]
        if claimed and not [p for p in subtract([(s.start, s.end)], claimed) if p[1] - p[0] >= MIN_REMAINDER]:
            ids.append(s.id)
    return ids


def union_gapped(intervals: list[Interval], max_gap: float) -> list[Interval]:
    """Merge intervals closer than `max_gap` (speech blocks for STT)."""
    out: list[list[float]] = []
    for a, b in sorted(intervals):
        if out and a - out[-1][1] < max_gap:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]
