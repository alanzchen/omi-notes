"""Median F0 of a speech clip with numpy only (YIN, de Cheveigné & Kawahara 2002).

Copied from the evidence study (`~/Developer/omi-asr-bench/spk/a0-20261109/f0_numpy.py`, REPORT.md
recommendation 6): per 10 ms hop with a 30 ms integration window and lags for 70-400 Hz, the first dip of
the cumulative-mean-normalized difference below 0.20, walked to its local minimum and refined by parabolic
interpolation; a frame is voiced when such a lag exists, its energy is in the clip's top half and above
-55 dBFS, and the F0 lies within 70-400 Hz. Label-level agreement with torchaudio there: r 0.93, median
|Δ| 5.9 Hz. A clip's F0 needs ≥ 20 voiced frames and a sample's ≥ 100, else it is unknown (None).

F0 is review evidence only (`speakers/flags.py`): it orders the review queue and never decides identity.
"""

from __future__ import annotations

import numpy as np

SR = 16000
FMIN, FMAX = 70.0, 400.0
HOP = 160  # 10 ms
WIN = 480  # 30 ms integration window
THRESHOLD = 0.20  # YIN aperiodicity threshold
ABS_FLOOR_DB = -55.0  # frame RMS floor, dBFS
MIN_VOICED = 20  # frames per clip (0.2 s of voiced speech)
SAMPLE_MIN_VOICED = 100  # voiced frames over a sample's clips
ESTIMATOR = "yin-numpy-v1"  # recorded with every measurement


def _frames(x, span, hop):
    n = 1 + max(0, (len(x) - span) // hop)
    idx = np.arange(span)[None, :] + hop * np.arange(n)[:, None]
    return x[idx]


def clip_f0(pcm, sr=SR, fmin=FMIN, fmax=FMAX, threshold=THRESHOLD, min_voiced=MIN_VOICED, energy_quantile=0.5) -> dict:
    """{f0 (None below `min_voiced`), voiced, frames, voiced_frac, aperiodicity} of int16 (or float) mono PCM."""
    x = np.asarray(pcm)
    x = x.astype(np.float64) / 32768.0 if x.dtype.kind in "iu" else x.astype(np.float64)
    tau_min = int(np.floor(sr / fmax))
    tau_max = int(np.ceil(sr / fmin))
    span = WIN + tau_max
    out = dict(f0=None, voiced=0, frames=0, voiced_frac=0.0, aperiodicity=None)
    if len(x) < span:
        return out
    x = x - x.mean()
    fr = _frames(x, span, HOP)  # (n, span)
    n = len(fr)
    out["frames"] = int(n)
    nfft = 1 << int(np.ceil(np.log2(WIN + span)))
    a_ = np.fft.rfft(fr[:, :WIN], nfft)
    b_ = np.fft.rfft(fr, nfft)
    r = np.fft.irfft(np.conj(a_) * b_, nfft)[:, : tau_max + 1]  # r[tau] = sum_{j<WIN} x[j] x[j+tau]
    cs = np.concatenate([np.zeros((n, 1)), np.cumsum(fr * fr, axis=1)], axis=1)
    taus = np.arange(tau_max + 1)
    e0 = cs[:, WIN][:, None]
    et = cs[:, taus + WIN] - cs[:, taus]
    d = np.maximum(e0 + et - 2 * r, 0.0)
    d[:, 0] = 0.0
    cm = np.ones_like(d)
    csum = np.cumsum(d[:, 1:], axis=1)
    cm[:, 1:] = d[:, 1:] * np.arange(1, tau_max + 1)[None, :] / np.where(csum > 0, csum, 1.0)
    # first dip below threshold in [tau_min, tau_max], then walk to the local minimum
    sub = cm[:, tau_min : tau_max + 1]
    below = sub < threshold
    has = below.any(axis=1)
    t = np.argmax(below, axis=1) + tau_min
    rows = np.arange(n)
    for _ in range(tau_max - tau_min):
        nxt = np.minimum(t + 1, tau_max)
        step = has & (t < tau_max) & (cm[rows, nxt] < cm[rows, t])
        if not step.any():
            break
        t = np.where(step, nxt, t)
    # parabolic interpolation
    tl = np.clip(t - 1, 1, tau_max)
    tr = np.clip(t + 1, 1, tau_max)
    a, b, c = cm[rows, tl], cm[rows, t], cm[rows, tr]
    den = a - 2 * b + c
    shift = np.where((den > 0) & (t > 1) & (t < tau_max), 0.5 * (a - c) / np.where(den > 0, den, 1.0), 0.0)
    tau = t + np.clip(shift, -1, 1)
    f0 = sr / tau
    # energy gating on the analysis window
    rms_db = 10 * np.log10(cs[:, WIN] / WIN + 1e-12)
    energetic = (rms_db >= np.quantile(rms_db, energy_quantile)) & (rms_db > ABS_FLOOR_DB)
    voiced = has & energetic & (f0 >= fmin) & (f0 <= fmax)
    nv = int(voiced.sum())
    out.update(voiced=nv, voiced_frac=round(nv / n, 4))
    if nv:
        out["aperiodicity"] = round(float(np.median(cm[rows, t][voiced])), 4)
    if nv >= min_voiced:
        out["f0"] = float(np.median(f0[voiced]))
    return out


def label_f0(results, weights=None, min_voiced=MIN_VOICED) -> float | None:
    """Duration-weighted median of clip F0s that passed the voiced-frame minimum; None if no clip passed."""
    pv = [(r["f0"], (1.0 if weights is None else w)) for r, w in zip(results, weights or [None] * len(results), strict=True)
          if r.get("f0") is not None and r.get("voiced", 0) >= min_voiced]  # fmt: skip
    if not pv:
        return None
    x = np.array([a for a, _ in pv])
    w = np.array([b for _, b in pv], float)
    o = np.argsort(x)
    x, w = x[o], w[o]
    c = np.cumsum(w)
    return float(x[np.searchsorted(c, 0.5 * c[-1])])


def voice_f0(pcm: np.ndarray, spans: list) -> dict:
    """A sample's F0 from its clips (`spans`: [start, end] seconds into `pcm`): {f0 (None unless ≥ 100 voiced
    frames over the clips that passed), voiced, clips, estimator}."""
    results, weights = [], []
    for a, b in spans:
        piece = pcm[int(round(float(a) * SR)) : int(round(float(b) * SR))]
        results.append(clip_f0(piece))
        weights.append(max(float(b) - float(a), 0.0))
    passed = [r for r in results if r["f0"] is not None]
    voiced = int(sum(r["voiced"] for r in passed))
    f0 = label_f0(results, weights) if voiced >= SAMPLE_MIN_VOICED else None
    return {"f0": None if f0 is None else round(f0, 2), "voiced": voiced, "clips": len(passed), "estimator": ESTIMATOR}
