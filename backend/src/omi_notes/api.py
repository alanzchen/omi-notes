"""HTTP API (capture-format-v1.md, "HTTP API"). Disk and CPU work runs in the threadpool."""

from __future__ import annotations

import hmac
import json
import logging
import threading
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse

from . import PROTOCOL_VERSION, __version__
from .db import Database
from .envelope import MAX_BODY_BYTES
from .ingest import ApiError, capture_status, put_chunk, put_event, put_seal
from .pipeline.conversations import queue_counts
from .pipeline.worker import Worker
from .settings import Settings
from .util import iso_utc_epoch

log = logging.getLogger(__name__)
MAX_JSON_BYTES = 64 * 1024


def create_app(settings: Settings, *, start_worker: bool = True, worker: Worker | None = None) -> FastAPI:
    if not settings.omi_notes_token:
        raise RuntimeError("OMI_NOTES_TOKEN is not set (run `omi-notes pair` to generate one)")
    db = Database(settings.db_path)
    settings.notes_dir.mkdir(parents=True, exist_ok=True)
    token = settings.omi_notes_token.encode()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        stop = threading.Event()
        thread = None
        if start_worker:
            w = worker or Worker(settings, Database(settings.db_path))
            thread = threading.Thread(target=w.run_forever, args=(stop,), name="omi-notes-worker", daemon=True)
            thread.start()
        yield
        stop.set()
        if thread is not None:
            thread.join(timeout=30)

    app = FastAPI(title="omi-notes", version=__version__, lifespan=lifespan)
    app.state.db = db
    app.state.settings = settings

    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(exc.body(), status_code=exc.status)

    @app.middleware("http")
    async def _auth(request: Request, call_next):
        if request.url.path.startswith("/v1/"):
            header = request.headers.get("authorization", "")
            scheme, _, presented = header.partition(" ")
            if scheme.lower() != "bearer" or not hmac.compare_digest(presented.strip().encode(), token):
                return JSONResponse({"error": "unauthorized", "detail": "bad or missing bearer token"}, status_code=401)
        return await call_next(request)

    async def read_body(request: Request, limit: int) -> bytes:
        declared = request.headers.get("content-length")
        if declared is not None:
            if not declared.isdigit():
                raise ApiError(400, "bad_length", "invalid Content-Length")
            if int(declared) > limit:
                raise ApiError(413, "too_large", f"body exceeds {limit} bytes")
        body = bytearray()
        async for part in request.stream():
            body.extend(part)
            if len(body) > limit:
                raise ApiError(413, "too_large", f"body exceeds {limit} bytes")
        if declared is not None and int(declared) != len(body):
            raise ApiError(400, "length_mismatch", "body length does not match Content-Length")
        return bytes(body)

    async def read_json(request: Request) -> object:
        raw = await read_body(request, MAX_JSON_BYTES)
        try:
            return json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ApiError(422, "invalid_json", str(exc)) from exc

    @app.get("/healthz")
    async def healthz() -> dict:
        return {"ok": True}

    @app.get("/v1/status")
    def status() -> dict:
        return {
            "ok": True,
            "server_version": __version__,
            "protocol_version": PROTOCOL_VERSION,
            "server_time": iso_utc_epoch(time.time()),
            "stt": {
                "provider": settings.stt_provider,
                "ready": settings.stt_provider == "fake"
                or (settings.stt_provider == "deepgram" and bool(settings.deepgram_api_key))
                or (settings.stt_provider == "openai" and bool(settings.stt_base_url)),
            },
            "llm": {
                "provider": settings.llm_provider,
                "ready": settings.llm_provider in ("fake", "none")
                or (settings.llm_provider == "anthropic" and bool(settings.anthropic_api_key))
                or (settings.llm_provider == "openai" and bool(settings.llm_base_url)),
            },
            "queue": queue_counts(db),
            "notes_dir": str(settings.notes_dir),
        }

    @app.put("/v1/captures/{capture_id}/chunks/{chunk_sequence}")
    async def upload_chunk(capture_id: str, chunk_sequence: int, request: Request) -> JSONResponse:
        body = await read_body(request, MAX_BODY_BYTES)
        status_code, payload = await run_in_threadpool(
            put_chunk, db, settings, capture_id, chunk_sequence, body, request.headers.get("x-content-sha256")
        )
        return JSONResponse(payload, status_code=status_code)

    @app.put("/v1/captures/{capture_id}/seal")
    async def seal(capture_id: str, request: Request) -> JSONResponse:
        raw = await read_json(request)
        status_code, payload = await run_in_threadpool(put_seal, db, capture_id, raw)
        return JSONResponse(payload, status_code=status_code)

    @app.get("/v1/captures/{capture_id}")
    def get_capture(capture_id: str) -> JSONResponse:
        payload = capture_status(db, capture_id)
        if payload is None:
            return JSONResponse({"error": "not_found", "detail": "unknown capture"}, status_code=404)
        return JSONResponse(payload)

    @app.put("/v1/events/{event_id}")
    async def event(event_id: str, request: Request) -> JSONResponse:
        raw = await read_json(request)
        status_code, payload = await run_in_threadpool(put_event, db, event_id, raw)
        return JSONResponse(payload, status_code=status_code)

    @app.get("/v1/conversations/recent")
    def recent(limit: int = 20) -> dict:
        limit = max(1, min(limit, 200))
        rows = db.query("SELECT * FROM conversations ORDER BY start DESC LIMIT ?", (limit,))
        return {
            "conversations": [
                {
                    "id": r["id"],
                    "status": r["status"],
                    "started_at": iso_utc_epoch(r["start"]),
                    "ended_at": iso_utc_epoch(r["end"]),
                    "title": r["title"] if r["note_path"] else None,
                    "note_path": r["note_path"],
                    "late_audio": bool(r["late_audio"]),
                    "provisional": bool(r["provisional"]),
                }
                for r in rows
            ]
        }

    return app
