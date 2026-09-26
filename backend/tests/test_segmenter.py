"""Decision tables for the pure segmenter (architecture.md #7-#10)."""

import pytest

from omi_notes.pipeline.segmenter import (
    DeviceTimeline,
    Finalized,
    Params,
    RingCapture,
    Span,
    Speech,
    fully_claimed,
    resolved,
    ring_resolved_until,
    segment,
    subtract,
    union,
)

P = Params()


def speech(*intervals: tuple[float, float], first_id: int = 1) -> list[Speech]:
    return [Speech(first_id + i, a, b) for i, (a, b) in enumerate(intervals)]


def live(speech_list, *, cov=((-500.0, 10_000.0),), spans=((-500.0, None),), **kw) -> DeviceTimeline:
    """A connected device whose chunks cover `cov`."""
    return DeviceTimeline(speech=speech_list, coverage=list(cov), live_spans=[Span(a, b) for a, b in spans], **kw)


def spans_of(cands):
    return [(round(c.start, 3), round(c.end, 3)) for c in cands]


# -- gap rule --------------------------------------------------------------------------------------


@pytest.mark.parametrize("second_start, groups", [(129.9, 1), (130.0, 2), (130.1, 2)])
def test_gap_threshold_119_9_vs_120(second_start, groups):
    cands = segment(live(speech((0, 10), (second_start, second_start + 5))), now=1000, p=P)
    assert len(cands) == groups


def test_gap_rule_is_configurable():
    cands = segment(live(speech((0, 10), (50, 60))), now=1000, p=Params(gap=30))
    assert len(cands) == 2


# -- close rule: open live session -----------------------------------------------------------------


def test_open_session_silence_closes_on_chunk_coverage():
    tl = live(speech((0, 10)), cov=[(-500, 200)], live_open=True)
    (c,) = segment(tl, now=131, p=P)
    assert c.closed and not c.provisional and c.audio_gaps == []


def test_open_session_without_evidence_waits_then_goes_provisional_after_5_min():
    tl = live(speech((0, 10)), cov=[(-500, 60)], live_open=True)
    (c,) = segment(tl, now=10 + 120 + 299, p=P)
    assert not c.closed and c.waiting_for == "end window"
    (c,) = segment(tl, now=10 + 120 + 300, p=P)
    assert c.closed and c.provisional


def test_window_in_future_never_resolves():
    tl = DeviceTimeline(speech=speech((0, 10)), outside_policy="none")
    (c,) = segment(tl, now=100, p=P)
    assert not c.closed
    (c,) = segment(tl, now=130, p=P)
    assert c.closed


def test_heartbeat_style_coverage_counts_as_evidence():
    # chunks end at 20 s, a heartbeat watermark covers through 300 s
    tl = live(speech((0, 10)), cov=[(-500, 20), (-500, 300)], live_open=True)
    (c,) = segment(tl, now=140, p=P)
    assert c.closed and not c.provisional


# -- disconnects and ring sync ---------------------------------------------------------------------


def disconnected(ring=None, policy="wait", live_open=False):
    # connected until 15 s, then out of range; speech just before the disconnect
    return DeviceTimeline(
        speech=speech((0, 10)),
        coverage=[(-500, 15)],
        live_spans=[Span(-500, 15)],
        ring_resolved_until=ring,
        outside_policy=policy,
        live_open=live_open,
    )


def test_disconnect_waits_for_ring_sync():
    (c,) = segment(disconnected(), now=200, p=P)
    assert not c.closed and c.waiting_for == "end window"


def test_ring_sync_complete_resolves_disconnect_gap():
    (c,) = segment(disconnected(ring=600), now=700, p=P)
    assert c.closed and not c.provisional and c.audio_gaps == []


def test_ring_sync_that_does_not_reach_window_end_is_not_enough():
    (c,) = segment(disconnected(ring=100), now=200, p=P)
    assert not c.closed


def test_ring_seal_not_yet_activated_means_unresolved():
    # a sync_complete seal whose chunks are not processed is simply not an input yet
    (c,) = segment(disconnected(ring=None), now=10 + 120 + 1199, p=P)
    assert not c.closed


def test_provisional_after_20_min_without_open_session():
    (c,) = segment(disconnected(), now=10 + 120 + 1200, p=P)
    assert c.closed and c.provisional


def test_late_ring_speech_extends_open_conversation():
    tl = DeviceTimeline(
        speech=speech((0, 10), (100, 110)),  # the second interval arrived with the ring sync
        coverage=[(-500, 15), (100, 110)],
        live_spans=[Span(-500, 15)],
        ring_resolved_until=600,
    )
    (c,) = segment(tl, now=700, p=P)
    assert c.closed and spans_of([c]) == [(0, 110)] and c.audio_gaps == []


def test_device_without_offline_storage_resolves_immediately_but_records_gap():
    tl = DeviceTimeline(
        speech=speech((0, 10), (50, 60)),
        coverage=[(-500, 15), (40, 1000)],
        live_spans=[Span(-500, 15), Span(40, None)],
        outside_policy="loss",
        live_open=True,
    )
    (c,) = segment(tl, now=181, p=P)
    assert c.closed and not c.provisional
    assert c.audio_gaps == [(15, 40)]


def test_same_gap_on_offline_capable_device_is_silence_once_synced():
    tl = DeviceTimeline(
        speech=speech((0, 10), (50, 60)),
        coverage=[(-500, 15), (40, 1000)],
        live_spans=[Span(-500, 15), Span(40, None)],
        outside_policy="wait",
        ring_resolved_until=40,
        live_open=True,
    )
    (c,) = segment(tl, now=181, p=P)
    assert c.closed and c.audio_gaps == []


def test_start_window_after_reconnect_waits_for_ring():
    tl = DeviceTimeline(
        speech=speech((110, 120)),
        coverage=[(-500, 50), (100, 1000)],
        live_spans=[Span(-500, 50), Span(100, None)],
        live_open=True,
    )
    (c,) = segment(tl, now=400, p=P)
    assert not c.closed and c.waiting_for == "start window"
    (c,) = segment(DeviceTimeline(**{**tl.__dict__, "ring_resolved_until": 100.0}), now=400, p=P)
    assert c.closed


def test_missing_chunks_inside_a_live_span_block_closing():
    # capture sealed at 300 but chunk coverage stops at 50 (chunks still in the phone's outbox)
    tl = DeviceTimeline(speech=speech((0, 10)), coverage=[(-500, 50)], live_spans=[Span(-500, 300)],
                        ring_resolved_until=10_000)  # fmt: skip
    (c,) = segment(tl, now=200, p=P)
    assert not c.closed


def test_replay_policy_resolves_outside_time():
    tl = DeviceTimeline(speech=speech((10, 50)), coverage=[(0, 60)], live_spans=[Span(0, 60)], outside_policy="none")
    (c,) = segment(tl, now=171, p=P)
    assert c.closed and c.audio_gaps == []


# -- double tap ------------------------------------------------------------------------------------


def test_double_tap_splits_continuous_speech():
    tl = live(speech((0, 100)), cov=[(-500, 100)], splits=[50.0], live_open=True)
    first, second = segment(tl, now=101, p=P)
    assert spans_of([first, second]) == [(0, 50), (50, 100)]
    assert first.end_explicit and first.closed and not first.provisional
    assert second.start_explicit and not second.closed


def test_double_tap_in_silence_ends_conversation_now():
    tl = live(speech((0, 10), (30, 40)), cov=[(-500, 45)], splits=[20.0], live_open=True)
    first, second = segment(tl, now=45, p=P)
    assert spans_of([first, second]) == [(0, 10), (30, 40)]
    assert first.closed and first.end_explicit
    assert not second.closed


def test_double_tap_long_after_speech_is_a_noop():
    tl = live(speech((0, 10)), cov=[(-500, 500)], splits=[400.0])
    (c,) = segment(tl, now=500, p=P)
    assert not c.end_explicit and c.closed


# -- caps ------------------------------------------------------------------------------------------


def test_soft_cap_splits_at_next_20s_gap():
    ivs = [(t, t + 10) for t in range(0, 3 * 3600 + 300, 15)]  # 5 s gaps: one long conversation
    cut = next(i for i, iv in enumerate(ivs) if iv[0] > 3 * 3600 + 60)
    ivs = ivs[:cut] + [(a + 25, b + 25) for a, b in ivs[cut:]]  # one 30 s gap just after 3 h 01 m
    tl = live(speech(*ivs), cov=[(-500, 20_000)])
    parts = segment(tl, now=20_000, p=P)
    assert len(parts) == 2
    assert parts[0].end_explicit and parts[0].closed
    assert parts[1].start_explicit
    assert 3 * 3600 < parts[0].end < 3 * 3600 + 120
    assert parts[1].start - parts[0].end == pytest.approx(30)


def test_hard_cap_cuts_continuous_speech():
    tl = live(speech((0, 4 * 3600)), cov=[(-500, 20_000)])
    parts = segment(tl, now=20_000, p=P)
    assert [round(p.start) for p in parts] == [0, 11400]
    assert parts[0].end == pytest.approx(11400)
    assert parts[0].closed and parts[0].end_explicit


def test_gap_under_20s_after_soft_cap_does_not_split():
    ivs = [(t, t + 10) for t in range(0, 3 * 3600 + 400, 15)]
    parts = segment(live(speech(*ivs), cov=[(-500, 20_000)]), now=20_000, p=P)
    assert len(parts) == 1


# -- late audio ------------------------------------------------------------------------------------


def test_late_speech_near_finalized_window_is_its_own_note():
    fin = Finalized("conv-a", 0, 60, watermark=5)
    tl = live(speech((0, 60), first_id=3) + speech((100, 110), first_id=7), finalized=[fin])
    (c,) = segment(tl, now=1000, p=P)
    assert spans_of([c]) == [(100, 110)] and c.late_audio and c.related_id == "conv-a"


def test_late_speech_inside_finalized_window():
    fin = Finalized("conv-a", 0, 60, watermark=5)
    tl = live(speech((20, 30), first_id=9), finalized=[fin])
    (c,) = segment(tl, now=1000, p=P)
    assert c.late_audio and c.related_id == "conv-a"


def test_claimed_speech_produces_nothing_and_normal_speech_is_not_late():
    fin = Finalized("conv-a", 0, 60, watermark=5)
    tl = live(speech((0, 60), first_id=3) + speech((300, 310), first_id=8), finalized=[fin])
    (c,) = segment(tl, now=1000, p=P)
    assert spans_of([c]) == [(300, 310)] and not c.late_audio
    assert fully_claimed(tl) == [3]


def test_speech_after_explicit_split_is_not_late():
    fin = Finalized("conv-a", 0, 50, watermark=5, end_explicit=True)
    tl = live(speech((60, 70), first_id=8), finalized=[fin])
    (c,) = segment(tl, now=1000, p=P)
    assert not c.late_audio


def test_groups_never_span_a_finalized_conversation():
    fin = Finalized("conv-a", 100, 110, watermark=5)
    tl = live(speech((40, 50), (160, 170), first_id=8), finalized=[fin])
    cands = segment(tl, now=1000, p=P)
    assert len(cands) == 2 and all(c.late_audio for c in cands)


def test_partially_claimed_interval_leaves_remainder():
    fin = Finalized("conv-a", 0, 50, watermark=5, end_explicit=True)
    tl = live(speech((0, 100), first_id=1), finalized=[fin], splits=[50.0])
    (c,) = segment(tl, now=1000, p=P)
    assert spans_of([c]) == [(50, 100)] and c.start_explicit


# -- blocks and helpers ----------------------------------------------------------------------------


def test_blocks_are_padded_and_merge_under_two_seconds():
    (c,) = segment(live(speech((0, 5), (6.5, 8), (20, 25))), now=1000, p=P)
    # 300 ms pre-roll / 1 s tail; (−0.3, 6) and (6.2, 9) merge, (19.7, 26) stays apart
    assert c.blocks == pytest.approx([(-0.3, 9.0), (19.7, 26.0)])
    assert c.speech_seconds == pytest.approx(5 + 1.5 + 5)  # unpadded speech


def test_blocks_never_cross_an_explicit_split():
    first, second = segment(live(speech((0, 100)), cov=[(-500, 100)], splits=[50.0], live_open=True), now=101, p=P)
    assert first.blocks == pytest.approx([(-0.3, 50.0)]) and second.blocks == pytest.approx([(50.0, 101.0)])


def test_losses_are_reported_but_do_not_block_closing():
    tl = live(speech((0, 10), (13, 20)), cov=[(-500, 500)], losses=[(10.2, 12.8), (15, 15.3)])
    (c,) = segment(tl, now=200, p=P)
    assert c.closed and not c.provisional
    assert c.audio_gaps == [(10.2, 12.8)]  # sub-second dropouts are counted, not listed
    assert c.lost_seconds == pytest.approx(2.9)


def test_interval_helpers():
    assert union([(0, 1), (1.1, 2), (5, 6)]) == [(0, 2), (5, 6)]
    assert subtract([(0, 10)], [(2, 3), (5, 6)]) == [(0, 2), (3, 5), (6, 10)]
    tl = DeviceTimeline(speech=[], coverage=[(0, 60), (60.1, 120)])
    assert resolved(tl, 0, 120, now=200)  # adjacent chunks with float slivers


# -- ring sync evidence (pure) ----------------------------------------------------------------------


def ring(cid, *, covers, read, gen=1, settled=True, reason="sync_complete", start=None):
    return RingCapture(cid, reason, settled, gen, start if start is not None else covers - 30, covers, read)


G1_EARLY = {1: [(1000, 1199)]}


@pytest.mark.parametrize(
    "rings, processed, expected",
    [
        pytest.param([ring("s2", covers=2000, read=1520)], {}, 2000, id="first-ever sync"),
        pytest.param(
            [ring("s0", covers=1000, read=1000), ring("s2", covers=2000, read=1520)],
            G1_EARLY,
            1000,
            id="earlier capture unknown to the server: records 1200-1519 never arrived",
        ),
        pytest.param(
            [ring("s0", covers=1000, read=1000), ring("s2", covers=2000, read=1520)],
            {1: [(1000, 1519)]},
            2000,
            id="contiguous",
        ),
        pytest.param(
            [ring("s0", covers=1000, read=1000), ring("s1", covers=1500, read=1520), ring("s2", covers=2000, read=1541)],
            {1: [(1000, 1020), (1520, 1540)]},
            1000,
            id="a hole is never bridged by later records",
        ),
        pytest.param(
            [ring("s0", covers=1000, read=1000), ring("s1", covers=1500, read=1021), ring("s2", covers=2000, read=1541)],
            {1: [(1000, 1020), (1021, 1540)]},
            2000,
            id="adjacent ranges form one run",
        ),
        pytest.param(
            [ring("s0", covers=1000, read=1000, gen=1), ring("s2", covers=2000, read=40, gen=2)],
            G1_EARLY,
            2000,
            id="generation change (storage reset / reflash)",
        ),
        pytest.param(
            [ring("s1", covers=1500, read=1200, reason="sync_interrupted", settled=False),
             ring("s2", covers=2000, read=1200)],
            {},
            None,
            id="known earlier capture still uploading",
        ),  # fmt: skip
        pytest.param(
            [ring("s1", covers=1500, read=1200, reason="sync_interrupted"), ring("s2", covers=2000, read=1301)],
            {1: [(1200, 1300)]},
            2000,
            id="interrupted earlier sync, processed, then resumed",
        ),
        pytest.param([ring("s2", covers=2000, read=0, settled=False)], {}, None, id="own chunks not processed yet"),
        pytest.param([ring("s2", covers=2000, read=0, reason="app_recovered")], {}, None, id="app_recovered carries no evidence"),
        pytest.param(
            [ring("s3", covers=3000, read=1600, start=2900, settled=False), ring("s2", covers=2000, read=0)],
            {},
            2000,
            id="a later sync still uploading does not block an earlier one",
        ),
    ],
)
def test_ring_watermark(rings, processed, expected):
    assert ring_resolved_until(rings, processed) == expected


def test_many_short_losses_are_not_bridged_into_a_gap():
    losses = [(10 + i * 0.1, 10 + i * 0.1 + 0.02) for i in range(40)]  # 40 × 20 ms, 100 ms apart
    (c,) = segment(live(speech((0, 20)), cov=[(-500, 500)], losses=losses), now=200, p=P)
    assert c.lost_seconds == pytest.approx(0.8) and c.audio_gaps == []
