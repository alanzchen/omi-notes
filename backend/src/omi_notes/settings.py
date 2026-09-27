"""Configuration from the environment and `backend/.env` (documented in `.env.example`)."""

from __future__ import annotations

import os
from functools import cached_property
from pathlib import Path
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_DIR = Path(__file__).resolve().parents[2]
DEFAULT_ENV_FILE = BACKEND_DIR / ".env"
MODELS_DIR = BACKEND_DIR / "models"


def system_timezone() -> str:
    """Best-effort IANA name of the machine's local timezone (falls back to UTC)."""
    if tz := os.environ.get("TZ"):
        return tz.lstrip(":")
    try:
        target = os.path.realpath("/etc/localtime")
    except OSError:
        return "UTC"
    marker = "zoneinfo/"
    if marker in target:
        return target.split(marker, 1)[1]
    return "UTC"


def env_file() -> Path:
    return Path(os.environ.get("OMI_NOTES_ENV_FILE", DEFAULT_ENV_FILE))


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, extra="ignore", case_sensitive=False)

    omi_notes_token: str = ""
    # The one data setting: notes and everything permanent (docs/vault.md).
    vault_dir: Path = Path("~/Documents/OmiNotes")
    # Where the disposable SQLite index lives (default: Application Support / XDG state).
    index_dir: Path | None = None
    # Host locks, one folder per vault path, whatever INDEX_DIR says (default: next to the index root).
    lock_dir: Path | None = None
    # Pre-vault settings: only read to refuse an unmigrated install (`omi-notes migrate-vault`).
    notes_dir: Path | None = None
    data_dir: Path | None = None
    host: str = "127.0.0.1"
    port: int = 8765
    timezone: str = Field(default_factory=system_timezone)
    owner_name: str = ""

    stt_provider: Literal["deepgram", "openai", "fake"] = "deepgram"
    deepgram_api_key: str = ""
    stt_model: str = "nova-3"
    stt_language: str = "en"
    stt_keyterms: str = ""
    # OpenAI-compatible transcriptions (STT_PROVIDER=openai): Mistral, OpenAI, Together, vLLM, LocalAI, ...
    stt_base_url: str = "https://api.openai.com/v1"
    stt_api_key: str = ""
    stt_request_style: Literal["auto", "openai_diarized", "mistral", "together", "verbose"] = "auto"
    # Longest audio per request; unset = the style's known limit, 0 = unlimited.
    stt_max_request_seconds: float | None = None
    # Where speaker labels come from; transcripts without them fail unless this is "off".
    stt_diarization: Literal["auto", "provider", "local", "off"] = "auto"
    diarization_num_speakers: int = 0  # 0 = decide from DIARIZATION_THRESHOLD
    diarization_threshold: float = 0.5
    diarization_segmentation_model: Path = MODELS_DIR / "pyannote-segmentation-3-0.onnx"
    diarization_embedding_model: Path = MODELS_DIR / "nemo_en_titanet_small.onnx"
    # Speaker recognition (docs/speaker-learning.md): inert until someone is enrolled or named.
    speaker_model: Path = MODELS_DIR / "wespeaker_en_voxceleb_resnet34_LM.onnx"
    speaker_auto_assign: bool = True
    # Operating points (Omi's priors; `omi-notes speakers bench` recommends calibrated values).
    speaker_match_threshold: float = 0.50
    speaker_match_margin: float = 0.10

    llm_provider: Literal["anthropic", "openai", "fake", "none"] = "anthropic"
    anthropic_api_key: str = ""
    llm_model: str = "claude-opus-5"
    # Anthropic effort; "none" omits it (Haiku models never get it: they reject the parameter).
    llm_effort: Literal["none", "low", "medium", "high", "xhigh", "max"] = "medium"
    # OpenAI-compatible chat completions (LLM_PROVIDER=openai): OpenAI, Ollama, llama.cpp, vLLM, ...
    llm_base_url: str = "https://api.openai.com/v1"
    llm_api_key: str = ""
    llm_json_mode: Literal["auto", "json_schema", "json_object", "prompt"] = "auto"
    llm_reasoning_effort: str = ""

    conversation_gap_seconds: float = 120.0
    provisional_wait_open_seconds: float = 300.0
    provisional_wait_seconds: float = 1200.0
    soft_max_conversation_seconds: float = 10800.0
    hard_max_conversation_seconds: float = 11400.0
    raw_retention_days: float = 30.0

    vad_backend: Literal["silero", "energy"] = "silero"
    vad_threshold: float = 0.5
    vad_model_path: Path = MODELS_DIR / "silero_vad.onnx"
    worker_tick_seconds: float = 5.0

    @field_validator(
        "vault_dir", "index_dir", "lock_dir", "notes_dir", "data_dir", "vad_model_path", "diarization_segmentation_model",
        "diarization_embedding_model", "speaker_model", mode="after",
    )
    @classmethod
    def _expand(cls, value: Path | None) -> Path | None:
        return value.expanduser() if value is not None else None

    @field_validator("timezone", mode="after")
    @classmethod
    def _valid_tz(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ValueError(f"unknown TIMEZONE {value!r}") from exc
        return value

    @cached_property
    def tz(self) -> ZoneInfo:
        return ZoneInfo(self.timezone)

    @property
    def keyterms(self) -> list[str]:
        # Deepgram accepts at most 100 keyterms per request.
        return [t.strip() for t in self.stt_keyterms.split(",") if t.strip()][:100]

    @property
    def raw_dir(self) -> Path:
        return self.vault_dir / "_omi" / "raw"

    @property
    def db_path(self) -> Path:
        """The index database of the vault at VAULT_DIR (reads `_omi/VAULT.json`)."""
        from .vault import Vault, index_dir

        return index_dir(self, Vault.open(self, create=False)) / "index.sqlite3"

    @property
    def logs_dir(self) -> Path:
        from .vault import default_index_root

        return (self.index_dir or default_index_root()).parent / "logs"


def load_settings(**overrides: object) -> Settings:
    """Settings from env + `.env` file; keyword overrides win (used by tests and the CLI)."""
    path = env_file()
    return Settings(_env_file=path if path.exists() else None, **overrides)  # type: ignore[call-arg]
