"""STT and LLM providers behind small interfaces, plus deterministic fakes for tests."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


class ProviderError(RuntimeError):
    """`terminal=True`: retrying will not help until the user fixes something (auth, billing,
    bad request); the conversation is marked failed until `omi-notes retry-failed`. `waiting=True`: the
    service itself is down (the local sidecar); the conversation waits for it without using up attempts."""

    def __init__(self, message: str, *, terminal: bool = False, kind: str = "error", waiting: bool = False) -> None:
        super().__init__(message)
        self.terminal = terminal
        self.kind = kind
        self.waiting = waiting


@dataclass
class SttRequest:
    flac: bytes
    duration: float
    blocks: list[tuple[float, float]]  # speech blocks in submitted-audio seconds
    language: str
    keyterms: list[str]


class SttProvider(Protocol):
    name: str
    model: str

    def transcribe(self, request: SttRequest) -> dict:
        """Deepgram-shaped JSON (`results.utterances[]`)."""
        ...


@dataclass
class LlmRequest:
    system: str
    user: str
    schema: dict
    segments: list[dict] = field(default_factory=list)


@dataclass
class LlmResult:
    data: dict
    model: str
    usage: dict = field(default_factory=dict)
    fallback_used: bool = False


class LlmProvider(Protocol):
    name: str
    model: str

    def summarize(self, request: LlmRequest) -> LlmResult: ...
