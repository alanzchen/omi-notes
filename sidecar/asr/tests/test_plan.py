"""Window planning, budgets and truncation (pure; no models)."""

import math
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
    assert plan.moss_max_tokens(60) == 2_400  # 40 per second for short windows (2026-11-10)
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


def test_a_short_window_s_moss_cap_scales_with_its_length_but_long_windows_keep_theirs():
    # 2026-11-09 20:08: MOSS looped on a 7 s window to the 16,384-token floor (97 s of GPU) before the request failed
    # honestly; real windows in the sidecar log ran 5.4-9.9 tokens per audio second
    from omi_asr import plan

    assert plan.moss_max_tokens(7) == 1024
    assert plan.moss_max_tokens(60) == 2400  # 40 per second: 4x the densest real window
    for seconds in (5, 30, 120, 300):
        assert plan.moss_max_tokens(seconds) >= max(1024, 40 * seconds) - 1
    for seconds in (410, 600, 750, 900, 1200):  # unchanged where 40/s reaches the old floor
        old = max(256, min(plan.MOSS_CONTEXT - math.ceil(plan.MOSS_PROMPT_TOKENS_PER_SECOND * seconds) - 256,
                           max(16_384, math.ceil(20 * seconds))))
        assert plan.moss_max_tokens(seconds) == old


def test_the_retry_cap_after_a_short_cap_hit_is_4x_but_never_past_the_long_budget():
    assert plan.moss_retry_tokens(7.3) == 4096 and plan.moss_max_tokens(7.3) == 1024
    assert plan.moss_retry_tokens(30) == 4800 and plan.moss_max_tokens(30) == 1200
    assert plan.moss_retry_tokens(120) == 16_384  # the long budget: 160/s would be 19,200
    for seconds in (410, 600, 1200):
        assert plan.moss_retry_tokens(seconds) == plan.moss_max_tokens(seconds), "long windows get no second try"
