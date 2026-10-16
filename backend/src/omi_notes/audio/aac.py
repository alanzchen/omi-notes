"""AAC (`.m4a`) from the Apple Watch, relayed unchanged by the phone (`aac_m4a_v1`), decoded here.

The phone no longer expands the Watch's AAC into PCM: the server keeps the original file (inside
the chunk envelope in the vault) and decodes it with ffmpeg when it needs samples: once at ingest,
to refuse a damaged or mislabelled file before acknowledging it, and again when the timeline is
built. Decoding is bounded (input size, output size, time). `record_count` is the file's own frame
count (encoder priming removed), so the decoded length must match it; a difference of a few frames
is padded or trimmed to keep the timeline exact, anything larger is refused.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile

import numpy as np

SAMPLE_RATE = 16_000
TIMEOUT_S = 30.0
TOLERANCE = 1024  # samples (64 ms): AAC frame rounding, never a missing stretch


class AacError(ValueError):
    pass


def ffmpeg() -> str | None:
    return shutil.which("ffmpeg")


def available() -> bool:
    return ffmpeg() is not None


def decode(payload: bytes, expected_samples: int) -> np.ndarray:
    """16 kHz mono int16 samples, exactly `expected_samples` long."""
    exe = ffmpeg()
    if exe is None:
        raise AacError("ffmpeg is not installed: this server can't decode AAC")
    if not payload:
        raise AacError("empty AAC payload")
    # mp4 needs a seekable input (its index may be at the end): a private temporary file
    fd, path = tempfile.mkstemp(suffix=".m4a")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(payload)
        limit = (expected_samples + 2 * SAMPLE_RATE) * 2
        try:
            run = subprocess.run(
                [exe, "-nostdin", "-v", "error", "-c:a", "aac", "-i", path, "-f", "s16le", "-ac", "1", "-ar", str(SAMPLE_RATE), "pipe:1"],
                capture_output=True, timeout=TIMEOUT_S, check=False,
            )  # fmt: skip
        except subprocess.TimeoutExpired as exc:
            raise AacError(f"AAC decode took longer than {TIMEOUT_S:.0f} s") from exc
        if run.returncode != 0:
            raise AacError(f"AAC decode failed: {run.stderr.decode(errors='replace').strip()[:300]}")
        if len(run.stdout) > limit:
            raise AacError(f"AAC decodes to more audio than its header says ({len(run.stdout) // 2} > {expected_samples} samples)")
    finally:
        os.unlink(path)
    pcm = np.frombuffer(run.stdout[: len(run.stdout) // 2 * 2], dtype="<i2").astype(np.int16)
    if abs(len(pcm) - expected_samples) > TOLERANCE:
        raise AacError(f"AAC decodes to {len(pcm)} samples, header says {expected_samples}")
    if len(pcm) < expected_samples:
        pcm = np.concatenate([pcm, np.zeros(expected_samples - len(pcm), np.int16)])
    return pcm[:expected_samples]
