"""OpenAI-compatible transcription endpoint on 127.0.0.1 (FastAPI).

POST /v1/audio/transcriptions (multipart): file (16 kHz mono FLAC/WAV from Omi; other rates resampled),
model, language (ignored: the models detect it), response_format (ignored: always the diarized shape),
`context` (terms, comma or newline separated; Layer-1 context plugs in here; `prompt` is accepted as the
same, never sent to MOSS), max_tokens (ignored: budgets are computed per window).
Answer: {text, language, duration, segments: [{start, end, speaker_id, text}], omi_asr: {...}}, the shape
Omi's `openai_diarized` style reads. GET /health → {ok, version, models_loaded}.
"""

from __future__ import annotations

import asyncio
import contextlib
import io
import logging
import os

import numpy as np
import soundfile as sf
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from starlette.concurrency import run_in_threadpool

from . import VERSION, plan
from .engine import Engine

log = logging.getLogger("omi_asr")
MAX_SECONDS = float(os.environ.get("OMI_ASR_MAX_SECONDS", str(2 * 3600)))


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


def create_app(engine: Engine | None = None) -> FastAPI:
    engine = engine or Engine()

    @contextlib.asynccontextmanager
    async def lifespan(_: FastAPI):
        async def idle_watch() -> None:  # unload the models after a quiet spell (they hold ~10 GB)
            while True:
                await asyncio.sleep(60)
                await run_in_threadpool(engine.unload_if_idle)

        task = asyncio.get_running_loop().create_task(idle_watch())
        yield
        task.cancel()

    app = FastAPI(title="omi-asr", version=VERSION, lifespan=lifespan)

    @app.get("/health")
    def health() -> dict:
        return {"ok": True, "version": VERSION, "models_loaded": engine.loaded}

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
        result = await run_in_threadpool(engine.transcribe, pcm, terms(context, prompt))
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
    uvicorn.run(create_app(), host=host, port=int(os.environ.get("OMI_ASR_PORT", "18793")), log_level="info")


if __name__ == "__main__":
    main()
