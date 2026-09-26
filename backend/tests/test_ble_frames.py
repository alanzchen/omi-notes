from omi_notes.device.ble_frames import MAX_PLC_FRAMES, BleFrameAssembler, encode_notification
from omi_notes.envelope import FLAG_SESSION_START


def feed_all(asm: BleFrameAssembler, notes: list[tuple[int, int, bytes]], flags_first: int = FLAG_SESSION_START):
    events = []
    for i, (seq, idx, payload) in enumerate(notes):
        events += asm.feed(i * 20_000, flags_first if i == 0 else 0, encode_notification(seq, idx, payload))
    return events


def kinds(events):
    return [(e.kind, e.data if e.kind == "frame" else e.count) for e in events if e.kind != "reset"]


def test_single_fragment_frames():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(1, 0, b"a"), (2, 0, b"b"), (3, 0, b"c")]) + asm.flush()
    assert kinds(events) == [("frame", b"a"), ("frame", b"b"), ("frame", b"c")]
    assert events[0].kind == "reset" and events[0].reason == "session_start"


def test_fragmented_frame_reassembly():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(10, 0, b"ab"), (11, 1, b"cd"), (12, 2, b"e"), (13, 0, b"z")]) + asm.flush()
    assert kinds(events) == [("frame", b"abcde"), ("frame", b"z")]


def test_frame_time_is_first_fragment_time():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(10, 0, b"ab"), (11, 1, b"cd"), (12, 0, b"z")])
    frame = next(e for e in events if e.kind == "frame")
    assert frame.t_us == 0


def test_duplicate_dropped():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(5, 0, b"a"), (5, 0, b"a"), (6, 0, b"b")]) + asm.flush()
    assert kinds(events) == [("frame", b"a"), ("frame", b"b")]
    assert asm.stats.duplicates == 1


def test_stale_redelivery_dropped():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(5, 0, b"a"), (6, 0, b"b"), (5, 0, b"a")]) + asm.flush()
    assert kinds(events) == [("frame", b"a"), ("frame", b"b")]


def test_small_loss_emits_pending_then_plc_markers():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(1, 0, b"a"), (2, 0, b"b"), (5, 0, b"e")]) + asm.flush()
    # seq 3 and 4 lost; pending frame "b" is emitted (almost always complete) before 2 PLC frames
    assert kinds(events) == [("frame", b"a"), ("frame", b"b"), ("lost", 2), ("frame", b"e")]
    assert asm.stats.lost_notifications == 2 and asm.stats.dropped_partial == 0


def test_large_loss_is_discontinuity():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(1, 0, b"a"), (1 + MAX_PLC_FRAMES + 5, 0, b"z")]) + asm.flush()
    assert [e.kind for e in events] == ["reset", "frame", "reset", "frame"]
    assert events[2].reason == "gap"


def test_wraparound_is_contiguous():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(65534, 0, b"a"), (65535, 0, b"b"), (0, 0, b"c"), (1, 1, b"d")]) + asm.flush()
    assert kinds(events) == [("frame", b"a"), ("frame", b"b"), ("frame", b"cd")]
    assert asm.stats.lost_notifications == 0


def test_loss_across_wrap():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(65535, 0, b"a"), (1, 0, b"c")]) + asm.flush()
    assert kinds(events) == [("frame", b"a"), ("lost", 1), ("frame", b"c")]


def test_orphan_continuation_is_skipped():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(1, 1, b"x"), (2, 0, b"a")]) + asm.flush()
    assert kinds(events) == [("frame", b"a")]
    assert asm.stats.orphan_fragments == 1


def test_session_start_flushes_and_resets_sequence():
    asm = BleFrameAssembler()
    events = feed_all(asm, [(100, 0, b"a")])
    # reconnect: seq keeps counting on the device, but frames in between were never sent
    events += asm.feed(10_000_000, FLAG_SESSION_START, encode_notification(900, 0, b"b"))
    events += asm.flush()
    assert kinds(events) == [("frame", b"a"), ("frame", b"b")]
    assert [e.reason for e in events if e.kind == "reset"] == ["session_start", "session_start"]
    assert asm.stats.lost_notifications == 0


def test_short_notifications_ignored():
    asm = BleFrameAssembler()
    assert asm.feed(0, 0, b"\x01\x00\x00") == []
    assert asm.stats.malformed == 1


def test_state_roundtrip_mid_frame():
    asm = BleFrameAssembler()
    feed_all(asm, [(10, 0, b"ab"), (11, 1, b"cd")])
    restored = BleFrameAssembler.from_state(asm.to_state())
    events = restored.feed(99, 0, encode_notification(12, 2, b"e")) + restored.feed(100, 0, encode_notification(13, 0, b"z"))
    assert kinds(events) == [("frame", b"abcde")]
