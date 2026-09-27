"""Where a transcript's speaker labels come from — and the rule that it must have them.

`STT_DIARIZATION`:
- `auto`: the provider's labels when it gave them for the whole audio in one request; otherwise
  local diarization when installed; otherwise the provider's per-piece labels, marked
  inconsistent (the same person may appear under different labels in different pieces).
- `provider`: only the provider's labels. `local`: only local diarization.
- `off`: whatever there is; a transcript without labels is accepted as a single speaker.
Without any speaker information the stage fails terminally with instructions.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass

from ..audio.diarize import INSTALL_HINT, Turn, assign_speakers
from ..providers import ProviderError

log = logging.getLogger(__name__)

DIARIZING_MODELS = (
    "Mistral voxtral-mini-latest, OpenAI gpt-4o-transcribe-diarize, Together openai/whisper-large-v3, "
    "OpenMOSS-Team/MOSS-Transcribe-Diarize on vLLM or mlx-audio, or Deepgram"
)

# Returns turns; None when local diarization is not installed; raises when it fails.
LocalTurns = Callable[[], list[Turn] | None]


@dataclass
class SpeakerResult:
    response: dict  # Deepgram-shaped, every utterance with an integer speaker
    source: str  # provider | local | none
    consistent: bool  # False: labels restart in each piece the audio was sent in


def has_speakers(response: dict) -> bool:
    utterances = (response.get("results") or {}).get("utterances") or []
    return any(u.get("speaker") is not None for u in utterances)


def pieces(response: dict) -> int:
    return int((response.get("omi_notes") or {}).get("pieces") or 1)


def _with(response: dict, utterances: list[dict]) -> dict:
    results = dict(response.get("results") or {}, utterances=utterances)
    return dict(response, results=results)


def _missing(detail: str) -> ProviderError:
    return ProviderError(
        f"The transcript has no speaker labels ({detail}), and notes need them. To fix: choose a diarizing "
        f"STT model ({DIARIZING_MODELS}) or install local diarization with {INSTALL_HINT}; then run "
        "`omi-notes retry-failed`. STT_DIARIZATION=off accepts single-speaker transcripts.",
        terminal=True,
        kind="diarization",
    )


def resolve_speakers(response: dict, mode: str, local: LocalTurns) -> SpeakerResult:
    utterances = (response.get("results") or {}).get("utterances") or []
    provider = has_speakers(response)
    split = pieces(response) > 1

    def run_local() -> tuple[list[Turn] | None, str]:
        try:
            turns = local()
        except Exception as exc:  # sherpa/onnx failures come in assorted types
            log.warning("local diarization failed: %s", exc)
            return None, f"local diarization failed: {exc}"
        return turns, "" if turns is not None else "local diarization is not installed"

    if mode == "off":
        if provider:
            return SpeakerResult(response, "provider", not split)
        return SpeakerResult(_with(response, [dict(u, speaker=0) for u in utterances]), "none", True)
    if mode == "provider":
        if not provider:
            raise _missing("STT_DIARIZATION=provider and the transcription server returned none")
        return SpeakerResult(response, "provider", not split)
    if mode == "local":
        turns, why = run_local()
        if turns is None:
            raise ProviderError(
                f"STT_DIARIZATION=local but {why}. Install it with {INSTALL_HINT}, or set STT_DIARIZATION=auto "
                f"to use the provider's labels; then run `omi-notes retry-failed`.",
                terminal=True,
                kind="diarization",
            )
        return SpeakerResult(_with(response, assign_speakers(utterances, turns)), "local", True)
    # auto
    if provider and not split:
        return SpeakerResult(response, "provider", True)
    turns, why = run_local()
    if turns is not None:
        return SpeakerResult(_with(response, assign_speakers(utterances, turns)), "local", True)
    if provider:
        return SpeakerResult(response, "provider", False)
    raise _missing(f"the transcription server returned none and {why}")
