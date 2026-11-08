"""Window planning, budgets and truncation (pure; no models)."""

import numpy as np

from omi_asr import plan

SR = plan.SR


def speech(seconds: float, gaps: list[tuple[float, float]] = (), seed: int = 0) -> np.ndarray:
    """Noise standing for speech, silent over `gaps` (start, end) seconds."""
    pcm = np.random.default_rng(seed).normal(0, 0.1, int(seconds * SR)).astype(np.float32)
    for a, b in gaps:
        pcm[int(a * SR):int(b * SR)] = 0
    return pcm


def test_max_tokens_is_at_least_16k_and_fits_the_context():
    assert plan.moss_max_tokens(60) == 16_384
    assert plan.moss_max_tokens(15 * 60) == 18_000            # 20 per second
    big = plan.moss_max_tokens(20 * 60)                        # 20/s = 24k; the 15.8k prompt leaves 24.9k
    assert big == 24_000 and big + 13.2 * 1200 <= plan.MOSS_CONTEXT
    assert plan.moss_max_tokens(30 * 60) == plan.MOSS_CONTEXT - int(np.ceil(13.2 * 1800)) - 256  # context-bound
    assert plan.qwen_max_tokens(180) == 12 * 180 + 32


def test_up_to_twenty_minutes_is_one_window():
    assert plan.plan_windows(speech(19 * 60)) == [(0.0, 19 * 60)]


def test_longer_audio_is_cut_at_the_longest_pause_between_10_and_15_minutes():
    pcm = speech(45 * 60, gaps=[(11 * 60, 11 * 60 + 0.5), (13 * 60, 13 * 60 + 2.0), (27 * 60, 27 * 60 + 1.0)])
    windows = plan.plan_windows(pcm)
    assert abs(windows[0][1] - (13 * 60 + 1.0)) < 0.05, windows  # middle of the 2 s pause, not the 0.5 s one
    assert all(b - a <= plan.HARD_MAX_WINDOW + 1e-6 for a, b in windows)
    assert windows[0][0] == 0 and windows[-1][1] == 45 * 60
    assert all(x[1] == y[0] for x, y in zip(windows, windows[1:]))


def test_without_any_pause_a_window_still_never_exceeds_twenty_minutes():
    windows = plan.plan_windows(speech(50 * 60))
    assert all(b - a <= plan.HARD_MAX_WINDOW + 1e-6 for a, b in windows) and windows[-1][1] == 50 * 60


def test_truncation_is_the_cap_or_a_last_line_far_before_the_last_speech():
    lines = [{"start": 0, "end": 100.0}]
    assert plan.is_truncated(lines, 16_384, 16_384, last_speech=101)            # hit the cap
    assert plan.is_truncated(lines, 3_000, 16_384, last_speech=600)             # ended at 4:03 of 10 min
    assert not plan.is_truncated(lines, 3_000, 16_384, last_speech=110)
    assert plan.is_truncated([], 10, 16_384, last_speech=60)


def test_a_truncated_window_is_cut_again_at_its_middle_pause():
    pcm = speech(600, gaps=[(100, 101), (290, 292), (500, 501)])
    assert abs(plan.middle_cut(pcm, 0, 600) - 291) < 0.05


def test_qwen_chunks_are_cut_at_moss_pauses_and_at_most_180_s():
    lines = [{"start": t, "end": t + 9.0} for t in range(0, 600, 10)]  # 1 s gaps every 10 s
    lines[15]["end"] = lines[15]["start"] + 7.0                          # a 3 s gap at 157-160 s
    cuts = plan.chunk_cuts(lines, 600)
    assert cuts[0] == 0 and cuts[-1] == 600 and abs(cuts[1] - 158.5) < 1e-6
    assert all(b - a <= 180 for a, b in zip(cuts, cuts[1:]))
