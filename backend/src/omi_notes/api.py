"""HTTP API (capture-format-v1.md, "HTTP API"). Disk and CPU work runs in the threadpool."""

from __future__ import annotations

import hmac
import json
import logging
import threading
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta
from datetime import time as dt_time

from fastapi import FastAPI, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, Response

from . import PROTOCOL_VERSION, __version__, operations, search, views
from .envelope import MAX_BODY_BYTES
from .ingest import ApiError, Ingest, capture_status
from .lock import api_lock
from .pipeline.conversations import ConversationPipeline, Providers, queue_counts
from .pipeline.worker import Worker, read_only_reason
from .rebuild import open_index
from .settings import Settings
from .speakers.service import SpeakerService
from .util import UUID_RE, iso_utc_epoch
from .vault import LeaseError, Vault, VaultBusy

log = logging.getLogger(__name__)
MAX_JSON_BYTES = 64 * 1024
# Index fields that decide which artifacts a conversation view shows.
_GENERATION = ("status", "revision", "written_sha", "transcript_sha", "llm_ref", "speakers_revision", "note_path", "edited")


def _day(value: str | None, tz, *, next_day: bool = False) -> float | None:
    """Midnight (local, the vault's time zone) starting a YYYY-MM-DD day, or the next one."""
    if value is None:
        return None
    try:
        day = date.fromisoformat(value)
    except ValueError as exc:
        raise ApiError(422, "invalid_date", "dates are YYYY-MM-DD") from exc
    if next_day:
        day += timedelta(days=1)
    return datetime.combine(day, dt_time.min, tzinfo=tz).timestamp()


def create_app(
    settings: Settings, *, start_worker: bool = True, worker: Worker | None = None, take_over: bool = False
) -> FastAPI:
    if not settings.omi_notes_token:
        raise RuntimeError("OMI_NOTES_TOKEN is not set (run `omi-notes pair` to generate one)")
    # Before anything that writes (VAULT.json, the index sweep): a second server must not touch
    # the vault or the live index at all. The lifespan takes the lock for real.
    probe = api_lock(Vault(settings.vault_dir, lock_root=settings.lock_dir))
    if probe.held_elsewhere():
        raise VaultBusy(f"another backend (pid {probe.owner()}) is already serving this vault ({settings.vault_dir})")
    vault = Vault.open(settings)
    lease = vault.foreign_live_lease()
    if lease and not take_over:
        raise LeaseError(
            f"{lease.get('host')} (pid {lease.get('pid')}) is writing this vault. Stop it first, or pass "
            "--take-over once it is stopped."
        )
    db = open_index(settings, vault)
    started_at = time.time()
    ingest = Ingest(db, vault, settings, read_only=lambda: read_only_reason(db))
    token = settings.omi_notes_token.encode()

    serving = api_lock(vault)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        # One server per vault on this host (docs/vault.md, "Writer ownership"): it writes chunks,
        # events and speaker changes, so a second one must not start, whatever its INDEX_DIR.
        if not serving.acquire():
            raise VaultBusy(f"another backend (pid {serving.owner()}) is already serving this vault ({vault.root})")
        stop = threading.Event()
        thread = None
        try:
            if start_worker:
                w = worker or Worker(settings, db)
                w.take_over = take_over
                if not w.lock.acquire():
                    raise VaultBusy(f"a separate `omi-notes worker` (pid {w.lock.owner()}) is processing this vault; "
                                    "run `omi-notes serve --no-worker` next to it")  # fmt: skip
                thread = threading.Thread(target=w.run_forever, args=(stop,), name="omi-notes-worker", daemon=True)
                thread.start()
            yield
        finally:
            stop.set()
            if thread is not None:
                thread.join(timeout=30)
            serving.release()

    app = FastAPI(title="omi-notes", version=__version__, lifespan=lifespan)
    app.state.db = db
    app.state.settings = settings
    app.state.vault = vault
    app.state.ingest = ingest
    pipeline = worker.pipeline if worker is not None else ConversationPipeline(settings, db, Providers(settings), "api", None)
    app.state.speakers = SpeakerService(pipeline)

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
            "server_started_at": iso_utc_epoch(started_at),
            # `ready` means configured, not proven: nothing here calls a provider
            "stt": {
                "provider": settings.stt_provider,
                "model": "fake-stt" if settings.stt_provider == "fake" else settings.stt_model,
                "diarization": settings.stt_diarization,
                "ready": settings.stt_provider == "fake"
                or (settings.stt_provider == "deepgram" and bool(settings.deepgram_api_key))
                or (settings.stt_provider == "openai" and bool(settings.stt_base_url)),
            },
            "llm": {
                "provider": settings.llm_provider,
                "model": None if settings.llm_provider == "none" else app.state.speakers.pipeline.providers.llm_model,
                "ready": settings.llm_provider in ("fake", "none")
                or (settings.llm_provider == "anthropic" and bool(settings.anthropic_api_key))
                or (settings.llm_provider == "openai" and bool(settings.llm_base_url)),
            },
            "queue": queue_counts(db),
            "worker": {"present": views.worker_present(vault)},
            "activity": views.activity(db, settings, time.time()),
            "last_note_at": views.last_note_at(db),
            "vault_dir": str(settings.vault_dir),
            "notes_dir": str(settings.vault_dir),
            "read_only": read_only_reason(db),
            # the phone only starts a voice enrollment when the server keeps the reading out of notes
            "features": ["voice_enrollment", "conversation_detail", "issues", "retry", "search"],
            "vault_id": vault.vault_id,
        }

    @app.put("/v1/captures/{capture_id}/chunks/{chunk_sequence}")
    async def upload_chunk(capture_id: str, chunk_sequence: int, request: Request) -> JSONResponse:
        body = await read_body(request, MAX_BODY_BYTES)
        status_code, payload = await run_in_threadpool(
            ingest.put_chunk, capture_id, chunk_sequence, body, request.headers.get("x-content-sha256")
        )
        return JSONResponse(payload, status_code=status_code)

    @app.put("/v1/captures/{capture_id}/seal")
    async def seal(capture_id: str, request: Request) -> JSONResponse:
        raw = await read_json(request)
        status_code, payload = await run_in_threadpool(ingest.put_seal, capture_id, raw)
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
        status_code, payload = await run_in_threadpool(ingest.put_event, event_id, raw)
        return JSONResponse(payload, status_code=status_code)

    @app.get("/v1/conversations/recent")
    def recent(limit: int = 20, before: str | None = None) -> dict:
        limit = max(1, min(limit, 200))
        where, params = views.LISTED, []
        if before is not None:
            cursor = views.parse_cursor(before)
            if cursor is None:
                raise ApiError(422, "invalid_cursor", "before must be a cursor returned by this endpoint")
            where += " AND (start < ? OR (start = ? AND id < ?))"
            params += [cursor[0], cursor[0], cursor[1]]
        rows = db.query(f"SELECT * FROM conversations WHERE {where} ORDER BY start DESC, id DESC LIMIT ?", (*params, limit + 1))
        page = rows[:limit]
        speakers_pipeline = app.state.speakers.pipeline
        return {
            "conversations": [views.summary_row(speakers_pipeline, r) for r in page],
            "next_cursor": views.make_cursor(page[-1]) if len(rows) > limit else None,
        }

    @app.get("/v1/conversations/search")
    def search_conversations(q: str = "", person_id: str | None = None, date_from: str | None = None,
                             date_to: str | None = None, before: str | None = None, limit: int = 20) -> dict:  # fmt: skip
        """Newest first; `date_from`/`date_to` are local calendar days (YYYY-MM-DD, `date_to` inclusive)."""
        limit = max(1, min(limit, 100))
        cursor = views.parse_cursor(before) if before is not None else None
        if before is not None and cursor is None:
            raise ApiError(422, "invalid_cursor", "before must be a cursor returned by this endpoint")
        if len(q) > 200:
            raise ApiError(422, "invalid_query", "q is limited to 200 characters")
        pipeline = app.state.speakers.pipeline
        return search.search(pipeline, q=q, person_id=person_id, start=_day(date_from, pipeline.tz),
                             end=_day(date_to, pipeline.tz, next_day=True), before=cursor, limit=limit)  # fmt: skip

    @app.get("/v1/conversations/{conv_id}")
    def conversation(conv_id: str, segments_from: int = 0) -> dict:
        """Read-only (capture-format-v1.md, "App views"). A row that changes while its files are read
        (a render or reprocess committing) is read again once, so one answer never mixes generations."""
        body = None
        for _ in range(2):
            row = db.one(f"SELECT * FROM conversations WHERE id=? AND {views.LISTED}", (conv_id,))
            if row is None:
                raise ApiError(404, "not_found", "unknown conversation")
            body = views.detail(app.state.speakers.pipeline, row, segments_from=segments_from)
            again = db.one("SELECT * FROM conversations WHERE id=?", (conv_id,))
            if again is not None and all(again[k] == row[k] for k in _GENERATION):
                return body
        # still changing: show nothing that could belong to another generation
        return body | {"summary": None, "summary_state": "updating", "transcript": None, "transcript_state": "updating",
                       "speakers": [], "speaker_names": [], "preview": None}  # fmt: skip

    @app.post("/v1/conversations/{conv_id}/retry")
    async def retry(conv_id: str, request: Request) -> JSONResponse:
        """Durable app retry of a failed conversation (docs/vault.md, "Operations")."""
        body = await read_json(request)
        if not isinstance(body, dict):
            raise ApiError(422, "invalid_body", "expected a JSON object")
        pipeline = app.state.speakers.pipeline
        status_code, op = await run_in_threadpool(
            operations.accept, pipeline, conv_id, body.get("request_id"), read_only=read_only_reason(db)
        )
        return JSONResponse({"operation": op}, status_code=status_code)

    @app.get("/v1/operations/{op_id}")
    def operation(op_id: str) -> dict:
        if not UUID_RE.match(op_id):
            raise ApiError(404, "not_found", "unknown operation")
        return {"operation": operations.view(app.state.speakers.pipeline, op_id)}

    @app.post("/v1/chunks/retry")
    def retry_chunks() -> dict:
        """Queue failed chunks again. Operational only (a rebuild replays surviving raw audio anyway)."""
        writable()
        queued = db.execute(
            "UPDATE chunks SET status='pending', attempts=0, next_attempt_at=NULL, error=NULL WHERE status='failed'"
        ).rowcount
        return {"chunks_queued": queued}

    @app.get("/v1/issues")
    def issues(limit: int = views.ISSUE_LIMIT) -> dict:
        limit = max(1, min(limit, 100))
        return {"issues": views.server_issues(db, read_only=read_only_reason(db), worker=views.worker_present(vault), limit=limit)}

    # -- people & voices (docs/speaker-learning.md, "API") --------------------------------------

    def writable() -> None:
        reason = read_only_reason(db)
        if reason:
            raise ApiError(503, "vault_read_only", reason)

    def speakers(request: Request) -> SpeakerService:
        return request.app.state.speakers

    @app.get("/v1/people")
    def list_people(request: Request) -> dict:
        return {"people": speakers(request).people()}

    @app.put("/v1/people/{person_id}")
    async def put_person(person_id: str, request: Request) -> JSONResponse:
        body = await read_json(request)
        if not isinstance(body, dict):
            raise ApiError(422, "invalid_body", "expected a JSON object")
        writable()
        status_code, person = await run_in_threadpool(speakers(request).put_person, person_id, body)
        return JSONResponse(person, status_code=status_code)

    @app.delete("/v1/people/{person_id}")
    def delete_person(person_id: str, request: Request, delete_note: bool = False) -> dict:
        writable()
        affected = speakers(request).forget(person_id, delete_note=delete_note)
        return {"person_id": person_id, "voice_forgotten": True, "note_deleted": delete_note,
                "relabeled_conversations": affected}  # fmt: skip

    @app.get("/v1/conversations/{conv_id}/speakers")
    def conversation_speakers(conv_id: str, request: Request) -> dict:
        return speakers(request).conversation_speakers(conv_id)

    @app.put("/v1/conversations/{conv_id}/speakers/{label}")
    async def put_speaker(conv_id: str, label: str, request: Request) -> dict:
        body = await read_json(request)
        if not isinstance(body, dict):
            raise ApiError(422, "invalid_body", "expected a JSON object")
        writable()
        outcome = await run_in_threadpool(speakers(request).assign, conv_id, label, body)
        return {"revision": outcome.revision, "labels": outcome.labels, "relabeled_conversations": outcome.relabeled,
                "sample": outcome.sample}  # fmt: skip

    @app.post("/v1/conversations/{conv_id}/resummarize")
    def resummarize(conv_id: str, request: Request) -> JSONResponse:
        writable()
        speakers(request).resummarize(conv_id)
        return JSONResponse({"conversation_id": conv_id, "queued": True}, status_code=202)

    @app.get("/v1/speakers/suggestions")
    def suggestions(request: Request, limit: int = 5) -> dict:
        return {"suggestions": speakers(request).suggestions(max(1, min(limit, 20)))}

    @app.post("/v1/speakers/suggestions/{suggestion_id}/dismiss")
    def dismiss(suggestion_id: str, request: Request) -> Response:
        writable()
        speakers(request).dismiss(suggestion_id)
        return Response(status_code=204)

    @app.post("/v1/speakers/suggestions/{suggestion_id}/assign")
    async def assign_suggestion(suggestion_id: str, request: Request) -> dict:
        body = await read_json(request)
        if not isinstance(body, dict):
            raise ApiError(422, "invalid_body", "expected a JSON object")
        writable()
        changed = await run_in_threadpool(speakers(request).assign_suggestion, suggestion_id, body)
        return {"relabeled_conversations": changed}

    @app.get("/v1/speakers/settings")
    def get_speaker_settings(request: Request) -> dict:
        return speakers(request).get_settings()

    @app.put("/v1/speakers/settings")
    async def put_speaker_settings(request: Request) -> dict:
        body = await read_json(request)
        if not isinstance(body, dict):
            raise ApiError(422, "invalid_body", "expected a JSON object")
        writable()
        return await run_in_threadpool(speakers(request).put_settings, body)

    @app.get("/v1/speakers/enrollments/{enrollment_id}")
    def enrollment_status(enrollment_id: str, request: Request) -> dict:
        result = speakers(request).enrollment_status(enrollment_id)
        if result is None:
            raise ApiError(404, "unknown_enrollment", "no voice enrollment with this id")
        return result

    @app.get("/v1/clips/{clip_id}")
    def clip(clip_id: str, request: Request) -> Response:
        return Response(speakers(request).clip_wav(clip_id), media_type="audio/wav")

    return app
