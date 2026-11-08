"""Time chunk uploads against a throwaway server: per-PUT latency and throughput at several
concurrencies, plus how long each upload holds the ingest lock.

    uv run python scripts/bench_ingest.py [--chunks 48] [--concurrency 1,4,8,16] [--size watch|pendant]

Everything lives in a temporary directory (vault, index, locks) with fake providers and no worker;
nothing touches a deployment or the network beyond loopback.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import socket
import statistics
import sys
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path

import httpx
import numpy as np

os.environ["OMI_NOTES_ENV_FILE"] = os.devnull  # never read a real configuration

from omi_notes import ingest  # noqa: E402
from omi_notes.api import create_app  # noqa: E402
from omi_notes.devtools import pcm_envelopes  # noqa: E402
from omi_notes.settings import load_settings  # noqa: E402

TOKEN = "b" * 64
# A phone-relayed Watch part is one minute of PCM (1.92 MB); a pendant part is ~225 KB of Opus.
SECONDS = {"watch": 60.0, "pendant": 7.0}


class TimedLock:
    """The ingest lock, recording how long each holder kept it."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.held: list[float] = []
        self._t = 0.0

    def __enter__(self):
        self._lock.acquire()
        self._t = time.perf_counter()
        return self

    def __exit__(self, *exc):
        self.held.append(time.perf_counter() - self._t)
        self._lock.release()
        return False


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def envelopes(kind: str, count: int, seed: int) -> list[tuple[str, int, bytes]]:
    rng = np.random.default_rng(seed)
    seconds = SECONDS[kind]
    pcm = (rng.standard_normal(int(seconds * 16000 * count)) * 3000).astype(np.int16)
    capture = str(uuid.uuid4())
    started = datetime(2026, 11, 7, 12, tzinfo=UTC)
    bodies = pcm_envelopes(pcm, capture_id=capture, device_id="bench-device", started_at=started, chunk_seconds=seconds)
    return [(capture, i, b) for i, b in enumerate(bodies[:count])]


def run(base: str, items: list[tuple[str, int, bytes]], concurrency: int) -> tuple[list[float], float]:
    local = threading.local()

    def put(item: tuple[str, int, bytes]) -> float:
        client = getattr(local, "client", None)
        if client is None:
            client = local.client = httpx.Client(base_url=base, headers={"Authorization": f"Bearer {TOKEN}"}, timeout=60)
        capture, seq, body = item
        t = time.perf_counter()
        r = client.put(f"/v1/captures/{capture}/chunks/{seq}", content=body,
                       headers={"X-Content-SHA256": hashlib.sha256(body).hexdigest()})  # fmt: skip
        if r.status_code != 201:
            sys.exit(f"unexpected {r.status_code}: {r.text[:200]}")
        return time.perf_counter() - t

    start = time.perf_counter()
    with ThreadPoolExecutor(concurrency) as pool:
        latencies = list(pool.map(put, items))
    return latencies, time.perf_counter() - start


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--chunks", type=int, default=48)
    parser.add_argument("--concurrency", default="1,4,8,16")
    parser.add_argument("--size", choices=sorted(SECONDS), default="watch")
    args = parser.parse_args()

    import uvicorn

    with tempfile.TemporaryDirectory(prefix="omi-bench-") as tmp:
        root = Path(tmp)
        settings = load_settings(
            omi_notes_token=TOKEN, vault_dir=root / "vault", index_dir=root / "index", lock_dir=root / "locks",
            stt_provider="fake", llm_provider="fake",
        )  # fmt: skip
        lock = TimedLock()
        ingest._lock = lock
        port = free_port()
        server = uvicorn.Server(uvicorn.Config(create_app(settings, start_worker=False), host="127.0.0.1", port=port,
                                               log_level="warning"))  # fmt: skip
        thread = threading.Thread(target=server.run, daemon=True)
        thread.start()
        while not server.started:
            time.sleep(0.05)
        base = f"http://127.0.0.1:{port}"
        print(f"{args.size} parts, {args.chunks} per run")
        print("conc  PUT/s    MB/s   p50 ms  p90 ms  max ms  lock p50 ms  lock p90 ms")
        for n, c in enumerate(int(x) for x in args.concurrency.split(",")):
            items = envelopes(args.size, args.chunks, seed=n)
            size = sum(len(b) for _, _, b in items)
            lock.held.clear()
            lat, wall = run(base, items, c)
            lat.sort()
            held = sorted(lock.held)
            print(f"{c:4d} {len(items) / wall:6.1f} {size / wall / 1e6:7.1f} {statistics.median(lat) * 1e3:8.1f}"
                  f" {lat[int(len(lat) * 0.9)] * 1e3:7.1f} {lat[-1] * 1e3:7.1f} {statistics.median(held) * 1e3:12.1f}"
                  f" {held[int(len(held) * 0.9)] * 1e3:12.1f}")  # fmt: skip
        server.should_exit = True
        thread.join(5)


if __name__ == "__main__":
    main()
