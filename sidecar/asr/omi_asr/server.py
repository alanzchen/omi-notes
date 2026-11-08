"""OpenAI-compatible transcription endpoint on 127.0.0.1 (FastAPI).

POST /v1/audio/transcriptions (multipart): file (16 kHz mono FLAC/WAV from Omi; other rates resampled),
model, language (ignored: the models detect it), response_format (ignored: always the diarized shape),
`context` (terms, comma or newline separated; Layer-1 context plugs in here; `prompt` is accepted as the
same, never sent to MOSS), max_tokens (ignored: budgets are computed per window).
Answer: {text, language, duration, segments: [{start, end, speaker_id, text}], omi_asr: {...}}, the shape
Omi's `openai_diarized` style reads. GET /health → {ok, version, models_loaded, self_test}; 503 with a
`reason` when the startup self-test failed or a transcription is stuck past its deadline.

The service is Omi's only transcription engine, so it guards itself: at startup it loads the models
and runs Qwen on a second of synthetic audio (MLX works), and a watchdog exits the process (launchd's KeepAlive
starts a fresh one) when a request runs past 300 s + its audio length (normal is ~0.1x).
"""

from __future__ import annotations

import asyncio
import contextlib
import io
import logging
import os
import threading
import time

import numpy as np
import soundfile as sf
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from . import VERSION, plan
from .engine import Engine

log = logging.getLogger("omi_asr")
MAX_SECONDS = float(os.environ.get("OMI_ASR_MAX_SECONDS", str(2 * 3600)))
DEADLINE_BASE = 300.0
WATCHDOG_EXIT = 70


class Guard:
    """Self-test state and the deadline of the request in progress."""

    def __init__(self, engine: Engine, exit=os._exit) -> None:
        self.engine, self.exit = engine, exit
        self.self_test_state = "pending"
        self.busy_since: float | None = None
        self.deadline: float | None = None
        self.lock = threading.Lock()

    def self_test(self) -> None:
        try:
            with self.lock:  # under the deadline too: a hang at startup is caught
                self.busy_since = time.time()
                self.deadline = self.busy_since + DEADLINE_BASE
            try:
                self.engine.self_test()
            finally:
                with self.lock:
                    self.busy_since = self.deadline = None
            self.self_test_state = "ok"
            log.info("self-test passed")
        except Exception as exc:  # anything at all: the engine can't serve
            self.self_test_state = f"failed: {type(exc).__name__}: {exc}"[:300]
            log.error("self-test failed: %s", self.self_test_state)

    def run(self, pcm: np.ndarray, context: list[str]) -> dict:
        with self.lock:
            self.busy_since = time.time()
            self.deadline = self.busy_since + DEADLINE_BASE + len(pcm) / plan.SR
        try:
            return self.engine.transcribe(pcm, context)
        finally:
            with self.lock:
                self.busy_since = self.deadline = None

    def problem(self) -> str | None:
        if self.self_test_state.startswith("failed"):
            return f"startup self-test {self.self_test_state}"
        deadline = self.deadline
        if deadline is not None and time.time() > deadline:
            return f"a transcription is stuck (running {time.time() - (self.busy_since or 0):.0f} s)"
        return None

    def check(self) -> None:
        """Watchdog: a stuck transcription holds the models' lock for good; start over."""
        problem = self.problem()
        if problem and problem.startswith("a transcription is stuck"):
            log.critical("%s: exiting so launchd restarts the service", problem)
            self.exit(WATCHDOG_EXIT)


def decode(data: bytes) -> np.ndarray:
    pcm, rate = sf.read(io.BytesIO(data), dtype="float32", always_2d=True)
    mono = pcm.mean(axis=1)
    if rate != plan.SR:
        from math import gcd

        from scipy.signal import resample_poly

        g = gcd(int(rate), plan.SR)
        mono = resample_poly(mono, plan.SR // g, int(rate) // g).astype(np.float32)
    return mono


def terms(*values: str | None) -> list[str]:
    out: list[str] = []
    for v in values:
        for t in (v or "").replace("\n", ",").split(","):
            if t.strip() and t.strip() not in out:
                out.append(t.strip())
    return out[:50]


def create_app(engine: Engine | None = None, *, self_test: bool = False, exit=os._exit) -> FastAPI:
    engine = engine or Engine()
    guard = Guard(engine, exit=exit)

    @contextlib.asynccontextmanager
    async def lifespan(_: FastAPI):
        async def idle_watch() -> None:  # unload the models after a quiet spell (they hold ~10 GB)
            while True:
                await asyncio.sleep(60)
                await run_in_threadpool(engine.unload_if_idle)

        async def watchdog() -> None:
            while True:
                await asyncio.sleep(15)
                guard.check()

        loop = asyncio.get_running_loop()
        tasks = [loop.create_task(idle_watch()), loop.create_task(watchdog())]
        if self_test:
            threading.Thread(target=guard.self_test, name="self-test", daemon=True).start()
        yield
        for task in tasks:
            task.cancel()

    app = FastAPI(title="omi-asr", version=VERSION, lifespan=lifespan)
    app.state.guard = guard

    @app.get("/health")
    def health() -> JSONResponse:
        problem = guard.problem()
        body = {"ok": problem is None, "version": VERSION, "models_loaded": engine.loaded, "self_test": guard.self_test_state}
        if problem:
            body["reason"] = problem
        return JSONResponse(body, status_code=503 if problem else 200)

    @app.post("/v1/audio/transcriptions")
    async def transcriptions(file: UploadFile = File(...), model: str = Form("omi-asr"), language: str | None = Form(None),
                             response_format: str | None = Form(None), context: str | None = Form(None),
                             prompt: str | None = Form(None), max_tokens: int | None = Form(None)) -> dict:  # fmt: skip
        data = await file.read()
        try:
            pcm = decode(data)
        except Exception as exc:  # soundfile raises assorted types for undecodable input
            raise HTTPException(400, f"audio could not be decoded: {exc}") from exc
        if len(pcm) == 0:
            raise HTTPException(400, "empty audio")
        if len(pcm) / plan.SR > MAX_SECONDS:
            raise HTTPException(413, f"audio longer than {MAX_SECONDS:.0f} s")
        result = await run_in_threadpool(guard.run, pcm, terms(context, prompt))
        log.info("transcribed %.0f s in %.1f s (rtf %.3f, %d segments)", result["duration"], result["omi_asr"]["seconds"],
                 result["omi_asr"]["rtf"], len(result["segments"]))  # fmt: skip
        return result

    return app


def main() -> None:
    import uvicorn

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    host = os.environ.get("OMI_ASR_HOST", "127.0.0.1")
    if host not in ("127.0.0.1", "::1", "localhost"):
        raise SystemExit("omi-asr binds to loopback only")
    self_test = os.environ.get("OMI_ASR_SELF_TEST", "1") != "0"
    uvicorn.run(create_app(self_test=self_test), host=host, port=int(os.environ.get("OMI_ASR_PORT", "18793")), log_level="info")


if __name__ == "__main__":
    main()
