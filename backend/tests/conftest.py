from __future__ import annotations

import hashlib
import uuid
from collections.abc import Callable
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from omi_notes.api import create_app
from omi_notes.db import Database
from omi_notes.pipeline.worker import Worker
from omi_notes.settings import Settings

TOKEN = "test-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
DEVICE = "11111111-2222-4333-8444-555555555555"
FIXTURES = Path(__file__).parent / "fixtures"


def make_settings(tmp_path: Path, **overrides) -> Settings:
    values = dict(
        omi_notes_token=TOKEN,
        notes_dir=tmp_path / "notes",
        data_dir=tmp_path / "data",
        stt_provider="fake",
        llm_provider="fake",
        vad_backend="energy",
        timezone="America/Chicago",
        owner_name="",
    )
    values.update(overrides)
    return Settings(**values)


@pytest.fixture(autouse=True)
def hermetic_env(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """Ignore the developer's shell environment and backend/.env."""
    for name in Settings.model_fields:
        monkeypatch.delenv(name.upper(), raising=False)
    monkeypatch.setenv("OMI_NOTES_ENV_FILE", str(tmp_path / "no.env"))


def cli_env(settings: Settings) -> dict[str, str]:
    return {
        "OMI_NOTES_TOKEN": settings.omi_notes_token,
        "NOTES_DIR": str(settings.notes_dir),
        "DATA_DIR": str(settings.data_dir),
        "STT_PROVIDER": settings.stt_provider,
        "LLM_PROVIDER": settings.llm_provider,
        "VAD_BACKEND": settings.vad_backend,
        "TIMEZONE": settings.timezone,
    }


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return make_settings(tmp_path)


@pytest.fixture
def client(settings: Settings) -> TestClient:
    return TestClient(create_app(settings, start_worker=False))


@pytest.fixture
def worker(settings: Settings, client: TestClient) -> Worker:  # client first: creates the schema
    return Worker(settings, Database(settings.db_path))


def put_chunk(client: TestClient, capture_id: str, seq: int, body: bytes, *, sha: str | None = None):
    headers = AUTH | {"Content-Type": "application/octet-stream", "X-Content-SHA256": sha or hashlib.sha256(body).hexdigest()}
    return client.put(f"/v1/captures/{capture_id}/chunks/{seq}", content=body, headers=headers)


def upload_all(client: TestClient, capture_id: str, envelopes: list[bytes]) -> None:
    for seq, body in enumerate(envelopes):
        r = put_chunk(client, capture_id, seq, body)
        assert r.status_code == 201, r.text


@pytest.fixture
def new_id() -> Callable[[], str]:
    return lambda: str(uuid.uuid4())
