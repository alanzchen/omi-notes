# omi-asr: local transcription sidecar

A loopback-only service that transcribes with diarization on this Mac (MLX). It implements the
`align+v` design from the 2026-11-08 ASR bench (`omi-asr-bench`, `omi-notes-reviews/asr-bench-20261108/`):

- **Speaker lines:** MOSS-Transcribe-Diarize runs per window, giving `(start, end, speaker)` lines.
  - Windows are 10–15 min, cut at the longest pause, and never longer than 20 min.
  - `max_tokens` is computed from the duration: at least 16k, within the 40,960-token context.
  - A window is re-split at its middle pause when the token cap is hit or the last line ends more
    than 20 s before the last speech.
  - MOSS never gets a prompt: one would replace its instruction.
- **Text:** Qwen3-ASR-1.7B transcribes chunks of up to 3 min, cut at MOSS pauses.
  - The request's `context` terms go in as hotwords.
  - Output is capped at `12·s + 32` tokens. A chunk that hits the cap is treated as a repetition
    loop and keeps MOSS's text.
- **Alignment:** the Qwen3 forced aligner times each unit, and each unit goes to the MOSS line
  containing its midpoint (or the nearest line). Lines that get no unit keep MOSS's text.

## API

- `POST /v1/audio/transcriptions` takes multipart fields: `file` (any format soundfile reads),
  optional `context` (comma- or newline-separated terms; `prompt` is accepted as an alias), plus
  `model`, `language`, `response_format` and `max_tokens`. Those last four are accepted and ignored.
  - It answers `{text, language, duration, segments: [{start, end, speaker_id, text}], omi_asr: {…stats}}`,
    the shape Omi's `openai_diarized` style reads, plus `windows: [{start, end, label_prefix}]`: where MOSS ran
    (labels restart in each; the backend links them by voice).
  - Speaker ids are per request.
- `GET /health` answers `{ok, version, models_loaded}`.
  - Models load on the first request (about 10 s) and are released after
    `OMI_ASR_IDLE_UNLOAD` seconds idle (default 900).

## Running it

```sh
cd sidecar/asr && uv sync                 # own venv; mlx-audio 0.6.3 as in the bench
scripts/launchagent.sh install            # com.omi-notes.asr, KeepAlive, 127.0.0.1:18793
scripts/launchagent.sh status
scripts/launchagent.sh uninstall
```

- Models come from the existing Hugging Face cache with `HF_HUB_OFFLINE=1`, so nothing is downloaded:
  - `OpenMOSS-Team/MOSS-Transcribe-Diarize`
  - `mlx-community/Qwen3-ASR-1.7B-bf16`
  - `mlx-community/Qwen3-ForcedAligner-0.6B-bf16`
- `OMI_ASR_MOSS`, `OMI_ASR_QWEN` and `OMI_ASR_ALIGNER` override the model paths.
- The log is `~/Library/Logs/omi-notes-asr.log`.

## Tests

- Unit tests: `uv run pytest`. They are hermetic; the server tests use a fake engine.
- End-to-end on a bench window:
  `.venv/bin/python scripts/e2e_window.py http://127.0.0.1:18793 WAV REFERENCE.json [OUT.json]`.
  It prints only counts and distances, never transcript text.

Measured on a 607 s bench window (A10) through the installed agent, against the bench's `align+v`:
- **Output:** 170/170 lines, the same 3 speakers, token edit distance 0.002.
- **Speed and memory:** RTF 0.090, MLX peak 9.96 GB, process RSS 8.5 GB, models loaded in 10 s.

## Omi backend

The backend uses the sidecar only when `STT_LOCAL_URL` is set (for example `http://127.0.0.1:18793/v1`).
- **Requests:** at most `STT_LOCAL_MAX_REQUEST_SECONDS` long (default 900), split at speech-block gaps.
- **Speakers:** the sidecar's labels are used as-is, not local diarization, and are linked across
  pieces by WeSpeaker voiceprints (`pipeline/speaker_links.py`).
- **Fallback:** while `/health` fails, the configured `STT_*` provider transcribes as before.
  Remove the setting to go back.
