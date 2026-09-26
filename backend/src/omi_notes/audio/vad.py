"""Voice activity detection → unpadded speech intervals in absolute epoch seconds.

Silero (ONNX, CPU) is the default: 512-sample windows at 16 kHz, each prefixed with the last 64
samples of the previous window as context (what the official `OnnxWrapper` does; Omi's
`utils/stt/vad.py` documents that the recurrent state misbehaves without it). An energy detector
is the fallback when the model file is missing; `_status.md` then shows a warning.

Detection is *streaming*: a `VadStream` carries the model state, the partial window and any open
speech segment across pieces and chunk boundaries (its state round-trips through the chunk carry,
tagged with the backend and model version), so speech that straddles a 60 s rotation is judged as
one segment. If the backend changes between chunks (e.g. the Silero model was installed after
the energy fallback ran), the model state is rebuilt while the open segment carries on. Streams
return raw segments; the 250 ms minimum is applied to complete segments by the caller. Intervals are stored unpadded, because segmentation measures
silence between real speech; the 300 ms / 1 s padding exists only for STT blocks
(`segmenter.pad_blocks`). A VAD failure raises `VadError`: callers treat it as retryable, never as
silence.
"""

from __future__ import annotations

import base64
import hashlib
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import numpy as np

from .timeline import SAMPLE_RATE

log = logging.getLogger(__name__)

MIN_SPEECH = 0.25
CONTINUITY_TOLERANCE = 0.05

Interval = tuple[float, float]


class VadError(RuntimeError):
    pass


class VadModel(Protocol):
    """Stateless scorer; per-stream state is passed in and returned."""

    name: str
    version: str  # changes whenever persisted model state would no longer be compatible
    window: int
    on: float  # a window at or above this starts/continues speech
    off: float  # below this counts as silence
    min_silence_windows: int  # this many silent windows end a segment

    def initial_state(self) -> dict: ...

    def classify(self, windows: np.ndarray, state: dict) -> tuple[np.ndarray, dict]: ...


def _pack(array: np.ndarray) -> str:
    return base64.b64encode(np.ascontiguousarray(array).tobytes()).decode()


def _unpack(text: str, dtype, shape) -> np.ndarray:
    return np.frombuffer(base64.b64decode(text), dtype=dtype).reshape(shape).copy()


class SileroVad:
    name = "silero"
    window = 512
    CONTEXT = 64

    def __init__(self, model_path: Path, threshold: float = 0.5) -> None:
        import onnxruntime as ort

        options = ort.SessionOptions()
        options.inter_op_num_threads = 1
        options.intra_op_num_threads = 1
        self.session = ort.InferenceSession(str(model_path), sess_options=options, providers=["CPUExecutionProvider"])
        self.version = hashlib.sha256(model_path.read_bytes()).hexdigest()[:12]
        self.on = threshold
        self.off = max(threshold - 0.15, 0.01)  # hysteresis like silero's get_speech_timestamps
        self.min_silence_windows = 3  # ~100 ms
        self._sr = np.array(SAMPLE_RATE, dtype=np.int64)

    def initial_state(self) -> dict:
        return {"rnn": _pack(np.zeros((2, 1, 128), np.float32)), "ctx": _pack(np.zeros((1, self.CONTEXT), np.float32))}

    def classify(self, windows: np.ndarray, state: dict) -> tuple[np.ndarray, dict]:
        rnn = _unpack(state["rnn"], np.float32, (2, 1, 128))
        context = _unpack(state["ctx"], np.float32, (1, self.CONTEXT))
        probs = np.empty(len(windows), dtype=np.float32)
        for i, window in enumerate(windows):
            x = np.concatenate([context, window.reshape(1, -1)], axis=1)
            out, rnn = self.session.run(None, {"input": x, "state": rnn, "sr": self._sr})
            probs[i] = out[0][0]
            context = x[:, -self.CONTEXT :]
        return probs, {"rnn": _pack(rnn), "ctx": _pack(context)}

    def probabilities(self, pcm: np.ndarray) -> np.ndarray:
        audio = pcm.astype(np.float32) / 32768.0
        audio = np.concatenate([audio, np.zeros(-len(audio) % self.window, np.float32)])
        probs, _ = self.classify(audio.reshape(-1, self.window), self.initial_state())
        return probs


class EnergyVad:
    """Crude RMS detector: 20 ms frames above max(-42 dBFS, tracked noise floor + 10 dB)."""

    name = "energy"
    version = "1"
    window = 320
    on = off = 0.5
    min_silence_windows = 10  # 200 ms hangover
    FLOOR_RISE_DB = 0.05  # per frame: the floor follows quiet stretches, creeps up otherwise

    def initial_state(self) -> dict:
        return {"floor": -90.0}

    def classify(self, windows: np.ndarray, state: dict) -> tuple[np.ndarray, dict]:
        floor = float(state["floor"])
        rms = np.sqrt(np.mean(windows.astype(np.float64) ** 2, axis=1))
        db = 20 * np.log10(np.maximum(rms, 1e-9))
        probs = np.empty(len(windows), dtype=np.float32)
        for i, level in enumerate(db):
            floor = min(float(level), floor + self.FLOOR_RISE_DB)
            probs[i] = 1.0 if level > max(-42.0, floor + 10.0) else 0.0
        return probs, {"floor": floor}


class VadStream:
    """Streaming segmenter for one capture. `feed` returns completed (raw) segments;
    `open_segment` reports speech still in progress at the current end; `end_run` closes it
    (discontinuity or end of capture)."""

    def __init__(self, model: VadModel, state: dict | None = None) -> None:
        self.model = model
        state = state or {}
        saved = state.get("model")
        if saved and state.get("backend") == self.backend:
            self.model_state = saved
        else:
            if saved:
                log.info("VAD backend changed (%s → %s): rebuilding model state", state.get("backend"), self.backend)
            self.model_state = model.initial_state()
        self.remainder = _unpack(state["rem"], np.float32, (-1,)) if state.get("rem") else np.zeros(0, np.float32)
        self.pos: float | None = state.get("pos")  # epoch of remainder[0]
        self.seg_start: float | None = state.get("seg_start")
        self.silence_since: float | None = state.get("silence_since")

    @property
    def backend(self) -> str:
        return f"{self.model.name}:{self.model.version}"

    @property
    def end(self) -> float | None:
        return None if self.pos is None else self.pos + len(self.remainder) / SAMPLE_RATE

    def to_state(self) -> dict:
        return {
            "backend": self.backend,
            "model": self.model_state,
            "rem": _pack(self.remainder) if len(self.remainder) else "",
            "pos": self.pos,
            "seg_start": self.seg_start,
            "silence_since": self.silence_since,
        }

    def feed(self, pcm: np.ndarray, start: float) -> list[Interval]:
        out: list[Interval] = []
        if self.end is not None and abs(self.end - start) > CONTINUITY_TOLERANCE:
            out += self.end_run()
        if self.pos is None:
            self.pos = start
        buffer = np.concatenate([self.remainder, pcm.astype(np.float32) / 32768.0])
        w = self.model.window
        n = len(buffer) // w
        step = w / SAMPLE_RATE
        try:
            probs, self.model_state = self.model.classify(buffer[: n * w].reshape(n, w), self.model_state)
        except Exception as exc:  # onnxruntime and numpy raise assorted types
            raise VadError(f"{self.model.name} VAD failed: {exc}") from exc
        needed = self.model.min_silence_windows * step - 1e-9
        for i, p in enumerate(probs):
            t = self.pos + i * step
            if p >= self.model.on:
                self.silence_since = None
                if self.seg_start is None:
                    self.seg_start = t
            elif self.seg_start is not None and p < self.model.off:
                if self.silence_since is None:
                    self.silence_since = t
                elif t - self.silence_since >= needed:
                    out.append((self.seg_start, self.silence_since))
                    self.seg_start = self.silence_since = None
        self.remainder = buffer[n * w :]
        self.pos += n * step
        return out

    def open_segment(self) -> Interval | None:
        if self.seg_start is None:
            return None
        return (self.seg_start, self.silence_since if self.silence_since is not None else self.end)

    def end_run(self) -> list[Interval]:
        segment = self.open_segment()
        self.model_state = self.model.initial_state()
        self.remainder = np.zeros(0, np.float32)
        self.pos = self.seg_start = self.silence_since = None
        return [segment] if segment else []


def long_enough(segments: list[Interval]) -> list[Interval]:
    return [(a, b) for a, b in segments if b - a >= MIN_SPEECH]


def speech_intervals(model: VadModel, pcm: np.ndarray, start: float) -> list[Interval]:
    """One-shot detection over a single contiguous buffer (tests, tooling)."""
    stream = VadStream(model)
    return long_enough(stream.feed(pcm, start) + stream.end_run())


@dataclass
class VadChoice:
    vad: VadModel
    warning: str | None


def make_vad(backend: str, model_path: Path, threshold: float) -> VadChoice:
    if backend == "energy":
        return VadChoice(EnergyVad(), None)
    if not model_path.exists():
        warning = (
            f"Silero VAD model missing at {model_path}; using the crude energy detector. "
            "Run `omi-notes fetch-models`."
        )
        log.warning(warning)
        return VadChoice(EnergyVad(), warning)
    return VadChoice(SileroVad(model_path, threshold), None)
