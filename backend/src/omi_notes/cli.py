"""`omi-notes` command line."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path
from urllib.parse import quote

import typer

from .settings import MODELS_DIR, Settings, env_file, load_settings

app = typer.Typer(no_args_is_help=True, add_completion=False, help="Omi pendant audio → markdown notes.")

SILERO_URL = "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"
SILERO_SHA256 = "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"


def _setup_logging(settings: Settings | None = None, to_file: bool = False) -> None:
    handlers: list[logging.Handler] = [logging.StreamHandler()]
    if to_file and settings is not None:
        settings.logs_dir.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(settings.logs_dir / "omi-notes.log"))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s", handlers=handlers)


def _worker(settings: Settings):
    from .db import Database
    from .pipeline.worker import Worker

    return Worker(settings, Database(settings.db_path))


@app.command()
def serve(
    host: str = typer.Option(None, help="Bind address (default HOST, 127.0.0.1)"),
    port: int = typer.Option(None, help="Port (default PORT, 8765)"),
    no_worker: bool = typer.Option(False, "--no-worker", help="Only accept uploads; run `omi-notes worker` separately"),
) -> None:
    """Run the HTTP API (and the processing worker, unless --no-worker)."""
    import uvicorn

    from .api import create_app

    settings = load_settings()
    _setup_logging(settings, to_file=True)
    application = create_app(settings, start_worker=not no_worker)
    uvicorn.run(application, host=host or settings.host, port=port or settings.port, log_level="info")


@app.command()
def worker() -> None:
    """Run only the processing worker (pairs with `serve --no-worker`)."""
    settings = load_settings()
    _setup_logging(settings, to_file=True)
    stop = threading.Event()
    try:
        _worker(settings).run_forever(stop)
    except KeyboardInterrupt:
        stop.set()


# -- pairing ---------------------------------------------------------------------------------------


def _set_env_value(path: Path, key: str, value: str) -> None:
    lines = path.read_text().splitlines() if path.exists() else []
    out, found = [], False
    for line in lines:
        if line.split("=", 1)[0].strip() == key:
            out.append(f"{key}={value}")
            found = True
        else:
            out.append(line)
    if not found:
        out.append(f"{key}={value}")
    path.write_text("\n".join(out) + "\n")
    path.chmod(0o600)


def _tailscale_url() -> str | None:
    if not shutil.which("tailscale"):
        return None
    try:
        out = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5, check=True)
        dns = json.loads(out.stdout).get("Self", {}).get("DNSName", "").rstrip(".")
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
        return None
    return f"https://{dns}" if dns else None


@app.command()
def pair(url: str = typer.Option(None, help="Server URL the phone should use (default: this Mac's tailnet HTTPS name)")) -> None:
    """Print a QR code that configures the iPhone app (generates a token if needed)."""
    import qrcode

    settings = load_settings()
    token = settings.omi_notes_token
    if not token:
        token = secrets.token_hex(32)
        _set_env_value(env_file(), "OMI_NOTES_TOKEN", token)
        typer.echo(f"Generated a new token and saved it to {env_file()} (restart the server to use it).")
    url = url or _tailscale_url()
    if not url:
        url = f"http://{settings.host}:{settings.port}"
        typer.secho(
            "Could not find a tailnet name; the phone cannot reach 127.0.0.1. Pass --url https://<mac>.<tailnet>.ts.net",
            fg=typer.colors.YELLOW,
        )
    link = f"omi-notes://configure?url={quote(url, safe='')}&token={quote(token, safe='')}"
    qr = qrcode.QRCode(border=1)
    qr.add_data(link)
    qr.print_ascii(invert=True)
    typer.echo(f"\nServer URL: {url}")
    typer.echo("Scan with the iPhone camera, then confirm in the Omi Notes app.")
    typer.echo(f"Expose the server first: tailscale serve --bg --https=443 http://127.0.0.1:{settings.port}")


# -- doctor / models -------------------------------------------------------------------------------


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _writable(path: Path) -> bool:
    """Writable if it exists and accepts a file, or if it could be created (nothing is created)."""
    if path.exists():
        try:
            with tempfile.NamedTemporaryFile(dir=path):
                pass
            return True
        except OSError:
            return False
    parent = path.parent
    while not parent.exists() and parent != parent.parent:
        parent = parent.parent
    return os.access(parent, os.W_OK | os.X_OK)


@app.command()
def doctor() -> None:
    """Check libopus, the VAD model, folders, keys, transcription/diarization and tailscale serve."""
    settings = load_settings()
    problems = 0

    def check(ok: bool, label: str, hint: str = "", required: bool = True) -> None:
        nonlocal problems
        mark = typer.style("✓", fg=typer.colors.GREEN) if ok else typer.style("✗" if required else "!", fg=typer.colors.RED if required else typer.colors.YELLOW)
        typer.echo(f" {mark} {label}" + (f"  — {hint}" if hint and not ok else ""))
        problems += int(required and not ok)

    from .audio import opus

    try:
        check(True, f"libopus {opus.version()}")
    except opus.OpusError as exc:
        check(False, "libopus", f"{exc}")
    model = settings.vad_model_path
    if settings.vad_backend == "energy":
        check(True, "VAD: energy detector (VAD_BACKEND=energy)")
    elif not model.exists():
        check(False, f"Silero VAD model at {model}", "run `omi-notes fetch-models`")
    else:
        sha_ok = _sha256_file(model) == SILERO_SHA256
        check(sha_ok, "Silero VAD model checksum", "run `omi-notes fetch-models` to re-download", required=False)
        try:
            from .audio.vad import SileroVad

            SileroVad(model)
            check(True, "Silero VAD loads in onnxruntime")
        except Exception as exc:  # noqa: BLE001 - report anything
            check(False, "Silero VAD loads in onnxruntime", str(exc))
    check(_writable(settings.notes_dir), f"Notes folder writable: {settings.notes_dir}", "check NOTES_DIR")
    check(_writable(settings.data_dir), f"Data folder writable: {settings.data_dir}", "check DATA_DIR")
    check(bool(settings.omi_notes_token), "OMI_NOTES_TOKEN set", "run `omi-notes pair`")
    check(True, f"Timezone {settings.timezone}")
    style = None
    if settings.stt_provider == "deepgram":
        check(bool(settings.deepgram_api_key), "DEEPGRAM_API_KEY set", "needed for transcription")
    elif settings.stt_provider == "openai":
        from .providers.openai_stt import default_max_seconds, resolve_style

        base, model = settings.stt_base_url, settings.stt_model
        style = resolve_style(base, model, settings.stt_request_style)
        check(base.startswith(("http://", "https://")), f"STT server {base}", "set STT_BASE_URL, e.g. https://api.mistral.ai/v1")
        check(not model.startswith("nova-"), f"STT model {model} (request style {style})",
              "set STT_MODEL to a model your server serves (nova-* is Deepgram's)")  # fmt: skip
        if any(host in base for host in ("api.openai.com", "api.mistral.ai", "api.together.xyz")):
            check(bool(settings.stt_api_key), "STT_API_KEY set", f"needed for {base}")
        limit = settings.stt_max_request_seconds
        limit = default_max_seconds(style, base) if limit is None else limit
        check(True, f"STT request limit: {f'{limit:.0f} s (longer audio is split)' if limit else 'none'}")
    else:
        check(True, "STT provider: fake (no transcription)")
    from .audio.diarize import EMBEDDING, SEGMENTATION, local_diarization_status

    segmentation, embedding = settings.diarization_segmentation_model, settings.diarization_embedding_model
    problem = local_diarization_status(segmentation, embedding)
    mode = settings.stt_diarization
    if mode == "off":
        check(True, "Diarization off: single-speaker transcripts are accepted (STT_DIARIZATION=off)")
    elif mode == "local":
        check(problem is None, "Local diarization (sherpa-onnx + models)", problem or "")
    elif mode == "auto" and style == "verbose":
        check(problem is None, "Local diarization (this server may not label speakers)", problem or "", required=False)
    else:
        check(problem is None, "Local diarization (optional: consistent speakers when long audio is split)",
              problem or "", required=False)  # fmt: skip
    if problem is None:
        pinned = _sha256_file(segmentation) == SEGMENTATION.member_sha256 and _sha256_file(embedding) == EMBEDDING.sha256
        check(pinned, "Diarization model checksums", "run `omi-notes fetch-models --diarization`", required=False)
    if settings.llm_provider == "anthropic":
        check(bool(settings.anthropic_api_key) or bool(os.environ.get("ANTHROPIC_AUTH_TOKEN")),
              f"ANTHROPIC_API_KEY set (model {settings.llm_model}, effort {settings.llm_effort})",
              "needed for summaries (or an `ant auth login` profile)", required=False)  # fmt: skip
    elif settings.llm_provider == "openai":
        check(not settings.llm_model.startswith("claude-"), f"LLM model {settings.llm_model} at {settings.llm_base_url}",
              "set LLM_MODEL to a model your OpenAI-compatible server serves")  # fmt: skip
        if "api.openai.com" in settings.llm_base_url:
            check(bool(settings.llm_api_key), "LLM_API_KEY set", "needed for api.openai.com")
    else:
        check(True, f"LLM provider: {settings.llm_provider}")
    url = _tailscale_url()
    check(url is not None, f"Tailscale: {url or 'not running'}", "install/login to Tailscale for phone access", required=False)
    if url:
        try:
            out = subprocess.run(["tailscale", "serve", "status", "--json"], capture_output=True, text=True, timeout=5)
            serving = f"127.0.0.1:{settings.port}" in out.stdout or f"localhost:{settings.port}" in out.stdout
        except (subprocess.SubprocessError, OSError):
            serving = False
        check(serving, "tailscale serve proxies to this server",
              f"tailscale serve --bg --https=443 http://127.0.0.1:{settings.port}", required=False)  # fmt: skip
    check(shutil.which("ffmpeg") is not None, "ffmpeg (optional, for replay-wav resampling)", required=False)
    raise typer.Exit(1 if problems else 0)


def _fetch_verified(url: str, sha256: str, target: Path, member: str | None = None, member_sha256: str | None = None) -> None:
    """Download `url` (checksum-pinned), optionally extract one archive member, and write `target`."""
    import io
    import tarfile

    import httpx

    expected = member_sha256 if member else sha256
    if target.exists() and _sha256_file(target) == expected:
        typer.echo(f"{target} is already present and verified.")
        return
    typer.echo(f"Downloading {url}")
    response = httpx.get(url, follow_redirects=True, timeout=300)
    response.raise_for_status()
    data = response.content
    digest = hashlib.sha256(data).hexdigest()
    if digest != sha256:
        typer.secho(f"Checksum mismatch for {url}: got {digest}, expected {sha256}", fg=typer.colors.RED)
        raise typer.Exit(1)
    if member:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
            extracted = archive.extractfile(member)
            if extracted is None:
                typer.secho(f"{member} not found in {url}", fg=typer.colors.RED)
                raise typer.Exit(1)
            data = extracted.read()
        if hashlib.sha256(data).hexdigest() != member_sha256:
            typer.secho(f"Checksum mismatch for {member}", fg=typer.colors.RED)
            raise typer.Exit(1)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".tmp")
    tmp.write_bytes(data)
    tmp.replace(target)
    typer.echo(f"Saved {target} ({len(data)} bytes, sha256 verified).")


@app.command("fetch-models")
def fetch_models(
    diarization: bool = typer.Option(False, "--diarization", help="Also fetch the local speaker diarization models"),
) -> None:
    """Download the Silero VAD model (and, with --diarization, the sherpa-onnx diarization models)."""
    _fetch_verified(SILERO_URL, SILERO_SHA256, MODELS_DIR / "silero_vad.onnx")
    if diarization:
        from .audio.diarize import EMBEDDING, SEGMENTATION

        settings = load_settings()
        for spec, target in ((SEGMENTATION, settings.diarization_segmentation_model),
                             (EMBEDDING, settings.diarization_embedding_model)):  # fmt: skip
            _fetch_verified(spec.url, spec.sha256, target, spec.member, spec.member_sha256)
        try:
            import sherpa_onnx  # noqa: F401
        except ImportError:
            typer.secho("sherpa-onnx is not installed yet: run `uv sync --extra diarization`.", fg=typer.colors.YELLOW)


# -- dev tooling -----------------------------------------------------------------------------------


@app.command("replay-wav")
def replay_wav(
    wav: Path = typer.Argument(..., exists=True, dir_okay=False, help="Any audio file (resampled to 16 kHz mono)"),
    as_: str = typer.Option("ble", "--as", help="ble: firmware-like Opus notifications (live path); pcm: raw PCM"),
    server: str = typer.Option(None, help="Server base URL (default http://HOST:PORT)"),
    token: str = typer.Option(None, help="Bearer token (default OMI_NOTES_TOKEN)"),
    speed: float = typer.Option(0.0, help="Upload pacing as a multiple of real time (0 = as fast as possible)"),
    drop_rate: float = typer.Option(0.0, help="Fraction of BLE notifications to drop (exercises PLC)"),
    device_id: str = typer.Option("omi-notes-replay", help="Device id to upload as"),
    backdate: bool = typer.Option(True, help="Anchor the capture in the past so conversations close right away"),
) -> None:
    """Upload a WAV through the real HTTP contract, as a live BLE capture (default) or PCM."""
    import httpx

    from .devtools import SAMPLE_RATE, live_envelopes, load_wav_16k, pcm_envelopes
    from .envelope import iso_utc, parse_envelope

    settings = load_settings()
    server = (server or f"http://{settings.host}:{settings.port}").rstrip("/")
    token = token or settings.omi_notes_token
    pcm = load_wav_16k(wav)
    duration = len(pcm) / SAMPLE_RATE
    now = datetime.now(UTC)
    started = now - timedelta(seconds=duration + 180) if backdate else now
    capture_id = str(uuid.uuid4())
    if as_ == "ble":
        envelopes = live_envelopes(pcm, capture_id=capture_id, device_id=device_id, started_at=started, drop_rate=drop_rate)
    elif as_ == "pcm":
        envelopes = pcm_envelopes(pcm, capture_id=capture_id, device_id=device_id, started_at=started)
    else:
        raise typer.BadParameter("--as must be ble or pcm")
    source = "live_ble" if as_ == "ble" else "wav_replay"
    headers = {"Authorization": f"Bearer {token}"}
    typer.echo(f"Replaying {wav.name}: {duration:.1f} s as {source}, {len(envelopes)} chunks, capture {capture_id}")
    last_end_us = 0
    with httpx.Client(timeout=60) as client:
        for seq, body in enumerate(envelopes):
            header = parse_envelope(body).header
            last_end_us = header.chunk_end_offset_us
            if speed > 0 and seq:
                time.sleep((header.chunk_end_offset_us - header.chunk_start_offset_us) / 1e6 / speed)
            r = client.put(
                f"{server}/v1/captures/{capture_id}/chunks/{seq}",
                content=body,
                headers=headers | {"Content-Type": "application/octet-stream",
                                   "X-Content-SHA256": hashlib.sha256(body).hexdigest()},
            )  # fmt: skip
            typer.echo(f"  chunk {seq}: HTTP {r.status_code} ({header.record_count} records, {len(body)} bytes)")
            if r.status_code >= 300:
                typer.echo(r.text)
                raise typer.Exit(1)
            beat = {"device_id": device_id, "type": "heartbeat", "at": iso_utc(datetime.now(UTC)),
                    "data": {"app_state": "replay", "coverage": {"capture_id": capture_id,
                             "through_offset_us": header.chunk_end_offset_us, "through_chunk_sequence": seq}}}  # fmt: skip
            client.put(f"{server}/v1/events/{uuid.uuid4()}", json=beat, headers=headers)
        seal = {
            "last_chunk_sequence": len(envelopes) - 1,
            "reason": "replay_complete",
            "ended_at": iso_utc(started + timedelta(microseconds=last_end_us)),
            "end_offset_us": last_end_us,
            "device_id": device_id,
            "source": source,
        }
        r = client.put(f"{server}/v1/captures/{capture_id}/seal", json=seal, headers=headers)
        typer.echo(f"  seal: HTTP {r.status_code} {r.text}")


SYNTH_SCRIPT = [
    ("Samantha", "Hi Daniel, thanks for making time. I wanted to go over the launch plan for the new notes app."),
    ("Daniel", "Sure. I finished the pairing screen yesterday, but the offline sync still needs testing on a real phone."),
    ("Samantha", "Okay. Let's aim to test offline sync on Thursday. Can you also send me the battery numbers by Friday?"),
    ("Daniel", "Yes, I'll send the battery report by Friday afternoon."),
    None,  # long pause: a new conversation starts after it
    ("Daniel", "Quick reminder for myself: remind me to order a replacement charging cable for the pendant."),
    ("Samantha", "And don't forget the dentist appointment on Monday at nine thirty."),
]


@app.command("synth-wav")
def synth_wav(
    out: Path = typer.Argument(Path("synth-conversations.wav")),
    pause: float = typer.Option(150.0, help="Silence between the two conversations, seconds (> 120 splits them)"),
) -> None:
    """Make a two-voice test WAV with macOS `say` (skips gracefully without `say`)."""
    import numpy as np
    import soundfile as sf

    if not shutil.which("say"):
        typer.echo("`say` is not available (macOS only); skipping.")
        return
    parts = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, line in enumerate(SYNTH_SCRIPT):
            if line is None:
                parts.append(np.zeros(int(pause * 16000), dtype=np.int16))
                continue
            voice, text = line
            path = Path(tmp) / f"{i}.wav"
            result = subprocess.run(["say", "-v", voice, "-o", str(path), "--file-format=WAVE", "--data-format=LEI16@16000", text])
            if result.returncode != 0:
                subprocess.run(["say", "-o", str(path), "--file-format=WAVE", "--data-format=LEI16@16000", text], check=True)
            pcm, _ = sf.read(path, dtype="int16")
            parts += [np.zeros(8000, dtype=np.int16), np.asarray(pcm, dtype=np.int16)]
    parts.append(np.zeros(16000, dtype=np.int16))
    audio = np.concatenate(parts)
    sf.write(out, audio, 16000, subtype="PCM_16")
    typer.echo(f"Wrote {out} ({len(audio) / 16000:.1f} s, pause {pause:.0f} s)")


# -- maintenance -----------------------------------------------------------------------------------


def _all_days(settings: Settings, db) -> set:
    return {datetime.fromtimestamp(r["start"], settings.tz).date() for r in db.query("SELECT start FROM conversations")}


@app.command()
def rebuild() -> None:
    """Re-render every note, daily index and _status.md from caches (zero API calls).

    Runs inline when no worker is running; otherwise queues the work for the worker."""
    from . import __version__
    from .lock import WorkerLock
    from .pipeline.conversations import CacheMiss

    settings = load_settings()
    _setup_logging()
    w = _worker(settings)
    lock = WorkerLock(settings.data_dir)
    if not lock.acquire():
        n = w.db.execute(
            "UPDATE conversations SET needs_render=1, next_attempt_at=NULL WHERE status IN ('done','discarded','failed') AND note_path IS NOT NULL"
        ).rowcount
        w.pipeline.reconcile_days()
        typer.echo(f"A worker is running: queued {n} notes and all daily indexes for re-rendering.")
        return
    try:
        w.pipeline.release_all_claims()  # holding the lock: nobody else is working
        now = time.time()
        rendered = skipped = 0
        for row in w.db.query("SELECT * FROM conversations WHERE status IN ('done','discarded','failed') ORDER BY start"):
            error = (row["error"] or "summary failed") if row["status"] == "failed" else None
            try:
                w.pipeline.summarize_and_render(row["id"], now, cache_only=True, summary_error=error)
                rendered += 1
            except CacheMiss as exc:
                skipped += 1
                typer.echo(f"  skipped {row['id']}: {exc}")
        days = _all_days(settings, w.db)
        w.pipeline.render_stubs()
        w.pipeline.render_dailies(days)
        w.pipeline.render_status(__version__)
    finally:
        lock.release()
    typer.echo(f"Rendered {rendered} notes and {len(days)} daily indexes; skipped {skipped}.")


@app.command()
def reprocess(
    conversation: str = typer.Argument(None, help="Conversation id (or unique prefix)"),
    since: str = typer.Option(None, help="All conversations starting on/after this date (YYYY-MM-DD, local)"),
    restt: bool = typer.Option(False, help="Discard the cached transcription (calls STT again)"),
    force_llm: bool = typer.Option(False, help="Discard the cached summary (calls the LLM again)"),
) -> None:
    """Re-run STT/summary for conversations, reusing caches unless told otherwise.

    Runs inline when no worker is running; otherwise queues the work for the worker."""
    from .lock import WorkerLock

    settings = load_settings()
    _setup_logging()
    w = _worker(settings)
    if conversation:
        rows = w.db.query("SELECT * FROM conversations WHERE id LIKE ? AND status<>'open'", (conversation + "%",))
    elif since:
        start = datetime.fromisoformat(since).replace(tzinfo=settings.tz).timestamp()
        rows = w.db.query("SELECT * FROM conversations WHERE start >= ? AND status<>'open'", (start,))
    else:
        raise typer.BadParameter("give a conversation id or --since")
    for row in rows:
        # A request is recorded apart from the execution status, so a stage running right now
        # cannot overwrite it; the pipeline consumes it atomically.
        w.db.execute(
            """UPDATE conversations SET reprocess_request = reprocess_request + 1,
                   force_restt = MAX(force_restt, ?), force_llm = MAX(force_llm, ?) WHERE id=?""",
            (int(restt), int(force_llm), row["id"]),
        )
    lock = WorkerLock(settings.data_dir)
    if not lock.acquire():
        typer.echo(f"A worker is running: {len(rows)} conversation(s) queued for it.")
        return
    try:
        w.pipeline.release_all_claims()  # holding the lock: nobody else is working
        for row in rows:
            w.pipeline.advance(row["id"], time.time())
            fresh = w.db.one("SELECT status, note_path, revision FROM conversations WHERE id=?", (row["id"],))
            typer.echo(f"  {row['id']}: {fresh['status']} rev {fresh['revision']} {fresh['note_path'] or ''}")
        w.pipeline.render_dailies()
    finally:
        lock.release()
    typer.echo(f"{len(rows)} conversation(s) reprocessed.")


@app.command("retry-failed")
def retry_failed() -> None:
    """Queue failed conversations and chunks again (after fixing keys/billing/etc.); processes
    them right away when no worker is running."""
    from .lock import WorkerLock

    settings = load_settings()
    _setup_logging()
    w = _worker(settings)
    convs = w.db.execute(
        """UPDATE conversations SET status=CASE failed_stage WHEN 'summarizing' THEN 'summarizing' ELSE 'closed' END,
               attempts=0, next_attempt_at=NULL, error=NULL, error_kind=NULL, failed_stage=NULL
           WHERE status='failed'"""
    ).rowcount
    chunks = w.db.execute(
        "UPDATE chunks SET status='pending', attempts=0, next_attempt_at=NULL, error=NULL WHERE status='failed'"
    ).rowcount
    typer.echo(f"Queued {convs} conversation(s) and {chunks} chunk(s).")
    lock = WorkerLock(settings.data_dir)
    if not lock.acquire():
        typer.echo("A worker is running; it picks them up on its next tick.")
        return
    try:
        w.pipeline.release_all_claims()  # holding the lock: nobody else is working
        result = w.tick()
    finally:
        lock.release()
    typer.echo(f"Processed inline: {result['chunks']} chunk(s), {result['conversations']} conversation step(s).")


if __name__ == "__main__":
    app()
