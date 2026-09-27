"""When the transcription and summary services last answered or failed (for the phone's Server tab).

Only real provider calls are counted: a cached result never reaches the provider, so reuse can't
look like a working service. A successful transcription-service request is not a finished
transcript (diarization and publishing follow), and the app labels it that way. Timestamps live in
the index `meta` table (operational: unknown again after a rebuild) under a fingerprint of the
provider configuration, so a replaced provider starts with a clean slate. A telemetry write never
turns a provider result into a processing failure.
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
from dataclasses import dataclass

from .pipeline.conversations import Providers
from .providers import ProviderError
from .settings import Settings

log = logging.getLogger(__name__)


def fingerprint(settings: Settings, kind: str) -> str:
    if kind == "stt":
        parts = [settings.stt_provider, settings.stt_model, settings.stt_base_url]
    else:
        parts = [settings.llm_provider, settings.llm_model, settings.llm_base_url]
    return hashlib.sha256(json.dumps([kind, *[str(p or "") for p in parts]]).encode()).hexdigest()[:16]


def meta_key(settings: Settings, kind: str) -> str:
    return f"provider:{kind}:{fingerprint(settings, kind)}"


def read(db, settings: Settings, kind: str) -> dict | None:
    raw = db.meta(meta_key(settings, kind))
    try:
        return json.loads(raw) if raw else None
    except json.JSONDecodeError:
        return None


class _Recording:
    """Forwards everything to the provider; `transcribe` / `summarize` also record the outcome."""

    def __init__(self, inner, record) -> None:
        self._inner = inner
        self._record = record

    def __getattr__(self, name):
        return getattr(self._inner, name)

    def transcribe(self, request):
        return self._call(self._inner.transcribe, request)

    def summarize(self, request):
        return self._call(self._inner.summarize, request)

    def _call(self, method, request):
        try:
            result = method(request)
        except ProviderError as exc:
            self._record(False, exc.kind)
            raise
        except Exception:
            self._record(False, "error")
            raise
        self._record(True, None)
        return result


@dataclass
class RecordingProviders(Providers):
    """`Providers` whose STT and LLM calls are timestamped in the index."""

    db: object = None

    @property
    def stt(self):
        inner = super().stt
        return inner if inner is None else _Recording(inner, lambda ok, kind: self._note("stt", ok, kind))

    @property
    def llm(self):
        inner = super().llm
        return inner if inner is None else _Recording(inner, lambda ok, kind: self._note("llm", ok, kind))

    def _note(self, kind: str, ok: bool, error_kind: str | None) -> None:
        if self.db is None:
            return
        try:
            key = meta_key(self.settings, kind)
            current = read(self.db, self.settings, kind) or {}
            if ok:
                current["last_ok_at"] = time.time()
            else:
                current.update(last_error_at=time.time(), last_error_kind=error_kind)
            self.db.set_meta(key, json.dumps(current, sort_keys=True))
        except Exception:
            log.exception("could not record the %s provider outcome", kind)
