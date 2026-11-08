"""Qwen units onto MOSS lines (pure; no models)."""

from omi_asr.merge import Unit, assign, moss_lines, spans_for


def test_moss_lines_drop_unlabelled_segments_and_strip_markers():
    raw = [{"start": 1, "end": 2, "speaker_id": "S01", "text": "[1.00][S01] 你好"}, {"start": 2, "end": 3, "text": "noise"}]
    assert moss_lines(raw, offset=10) == [{"start": 11.0, "end": 12.0, "speaker": "S01", "moss_text": "你好"}]


def test_units_go_to_the_line_holding_their_midpoint_and_keep_punctuation():
    text = "我们用 Overleaf 写，好吗？"
    items = [("我", 0.0, 0.2), ("们", 0.2, 0.4), ("用", 0.4, 0.6), ("Overleaf", 0.7, 1.2), ("写", 1.3, 1.5),
             ("好", 3.0, 3.2), ("吗", 3.2, 3.4)]
    units = spans_for(text, items, offset=100.0)
    lines = [{"start": 100.0, "end": 101.6, "speaker": "S01", "moss_text": "我们用欧贝利写"},
             {"start": 102.9, "end": 103.5, "speaker": "S02", "moss_text": "好吗"},
             {"start": 104.0, "end": 104.5, "speaker": "S01", "moss_text": "嗯"}]
    out, stats = assign(lines, units)
    assert [s["text"] for s in out] == ["我们用 Overleaf 写，", "好吗？", "嗯"]   # the empty line keeps MOSS text
    assert [s["speaker"] for s in out] == ["S01", "S02", "S01"]
    assert stats == {"units": 7, "units_outside_lines": 0, "lines_with_moss_text": 1}


def test_a_unit_outside_every_line_goes_to_the_nearest_and_is_counted():
    lines = [{"start": 0.0, "end": 1.0, "speaker": "S01", "moss_text": "a"}, {"start": 10.0, "end": 11.0, "speaker": "S02", "moss_text": "b"}]
    out, stats = assign(lines, [Unit(8.0, 8.4, "late")])
    assert out[1]["text"] == "late" and stats["units_outside_lines"] == 1
