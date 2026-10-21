"""Minimal ctypes binding to libopus (decoder + encoder).

We bind libopus directly instead of using `opuslib`: that package locates the library with
`ctypes.util.find_library`, which misses Homebrew's `/opt/homebrew/lib` on Apple Silicon, and
it is unmaintained. Only the handful of calls we need are bound.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
from functools import lru_cache

import numpy as np

OPUS_OK = 0
OPUS_APPLICATION_VOIP = 2048
OPUS_APPLICATION_AUDIO = 2049
OPUS_APPLICATION_RESTRICTED_LOWDELAY = 2051
OPUS_SET_BITRATE_REQUEST = 4002
OPUS_SET_VBR_REQUEST = 4006
OPUS_SET_COMPLEXITY_REQUEST = 4010

# Opus packets decode to at most 120 ms. Omi hit real failures sizing the decode buffer from the
# nominal wire frame (backend/routers/listen/receiver.py, issue #10701), so always allow 120 ms.
MAX_FRAME_SAMPLES_16K = 1920

_CANDIDATES = (
    "/opt/homebrew/lib/libopus.0.dylib",
    "/opt/homebrew/lib/libopus.dylib",
    "/usr/local/lib/libopus.0.dylib",
    "/usr/local/lib/libopus.dylib",
    "libopus.so.0",
    "libopus.so",
)


class OpusError(RuntimeError):
    pass


@lru_cache(maxsize=1)
def _lib() -> ctypes.CDLL:
    paths: list[str] = []
    if env := os.environ.get("OMI_NOTES_LIBOPUS"):
        paths.append(env)
    paths.extend(_CANDIDATES)
    if found := ctypes.util.find_library("opus"):
        paths.append(found)
    errors = []
    for path in paths:
        try:
            lib = ctypes.CDLL(path)
        except OSError as exc:
            errors.append(f"{path}: {exc}")
            continue
        _declare(lib)
        return lib
    raise OpusError(
        "libopus not found (brew install opus / apt install libopus0, or set OMI_NOTES_LIBOPUS). "
        + "; ".join(errors)
    )


def _declare(lib: ctypes.CDLL) -> None:
    c_int_p = ctypes.POINTER(ctypes.c_int)
    lib.opus_decoder_create.argtypes = [ctypes.c_int32, ctypes.c_int, c_int_p]
    lib.opus_decoder_create.restype = ctypes.c_void_p
    lib.opus_decoder_destroy.argtypes = [ctypes.c_void_p]
    lib.opus_decoder_destroy.restype = None
    lib.opus_decode.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_int16),
        ctypes.c_int,
        ctypes.c_int,
    ]
    lib.opus_decode.restype = ctypes.c_int
    lib.opus_encoder_create.argtypes = [ctypes.c_int32, ctypes.c_int, ctypes.c_int, c_int_p]
    lib.opus_encoder_create.restype = ctypes.c_void_p
    lib.opus_encoder_destroy.argtypes = [ctypes.c_void_p]
    lib.opus_encoder_destroy.restype = None
    lib.opus_encode.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int16),
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int32,
    ]
    lib.opus_encode.restype = ctypes.c_int32
    # opus_encoder_ctl is variadic. Declaring only the fixed parameters makes ctypes use
    # ffi_prep_cif_var for the extra argument, which Apple arm64's variadic ABI requires.
    lib.opus_encoder_ctl.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.opus_encoder_ctl.restype = ctypes.c_int
    lib.opus_strerror.argtypes = [ctypes.c_int]
    lib.opus_strerror.restype = ctypes.c_char_p
    lib.opus_get_version_string.argtypes = []
    lib.opus_get_version_string.restype = ctypes.c_char_p


def _strerror(code: int) -> str:
    return _lib().opus_strerror(code).decode(errors="replace")


def version() -> str:
    return _lib().opus_get_version_string().decode(errors="replace")


class OpusDecoder:
    """Stateful mono decoder. Feed packets in order; call `conceal()` for a lost packet."""

    def __init__(self, sample_rate: int = 16000, channels: int = 1) -> None:
        if channels != 1:
            raise ValueError("only mono is supported")
        self.sample_rate = sample_rate
        err = ctypes.c_int()
        self._handle = _lib().opus_decoder_create(sample_rate, channels, ctypes.byref(err))
        if err.value != OPUS_OK or not self._handle:
            raise OpusError(f"opus_decoder_create: {_strerror(err.value)}")
        self._max = MAX_FRAME_SAMPLES_16K * sample_rate // 16000
        self._buf = (ctypes.c_int16 * self._max)()

    def decode(self, packet: bytes) -> np.ndarray:
        n = _lib().opus_decode(self._handle, packet, len(packet), self._buf, self._max, 0)
        if n < 0:
            raise OpusError(f"opus_decode: {_strerror(n)}")
        return np.frombuffer(self._buf, dtype=np.int16, count=n).copy()

    def conceal(self, frame_samples: int) -> np.ndarray:
        """Packet-loss concealment for one missing frame of `frame_samples` samples."""
        frame_samples = min(frame_samples, self._max)
        n = _lib().opus_decode(self._handle, None, 0, self._buf, frame_samples, 0)
        if n < 0:
            return np.zeros(frame_samples, dtype=np.int16)
        return np.frombuffer(self._buf, dtype=np.int16, count=n).copy()

    def close(self) -> None:
        if self._handle:
            _lib().opus_decoder_destroy(self._handle)
            self._handle = None

    def __del__(self) -> None:  # pragma: no cover - best effort
        try:
            self.close()
        except Exception:
            pass


class OpusEncoder:
    """Used by dev tooling and tests to synthesize firmware-like Opus streams."""

    def __init__(
        self,
        sample_rate: int = 16000,
        application: int = OPUS_APPLICATION_RESTRICTED_LOWDELAY,
        bitrate: int = 32000,
        complexity: int = 3,
    ) -> None:
        lib = _lib()
        err = ctypes.c_int()
        self._handle = lib.opus_encoder_create(sample_rate, 1, application, ctypes.byref(err))
        if err.value != OPUS_OK or not self._handle:
            raise OpusError(f"opus_encoder_create: {_strerror(err.value)}")
        for request, value in (
            (OPUS_SET_BITRATE_REQUEST, bitrate),
            (OPUS_SET_VBR_REQUEST, 1),
            (OPUS_SET_COMPLEXITY_REQUEST, complexity),
        ):
            rc = lib.opus_encoder_ctl(self._handle, request, ctypes.c_int32(value))
            if rc != OPUS_OK:
                raise OpusError(f"opus_encoder_ctl({request}): {_strerror(rc)}")
        self._out = ctypes.create_string_buffer(4000)

    def encode(self, pcm: np.ndarray) -> bytes:
        pcm = np.ascontiguousarray(pcm, dtype=np.int16)
        ptr = pcm.ctypes.data_as(ctypes.POINTER(ctypes.c_int16))
        n = _lib().opus_encode(self._handle, ptr, len(pcm), self._out, len(self._out))
        if n < 0:
            raise OpusError(f"opus_encode: {_strerror(n)}")
        return self._out.raw[:n]

    def close(self) -> None:
        if self._handle:
            _lib().opus_encoder_destroy(self._handle)
            self._handle = None

    def __del__(self) -> None:  # pragma: no cover - best effort
        try:
            self.close()
        except Exception:
            pass
