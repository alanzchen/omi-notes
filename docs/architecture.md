# omi-notes architecture (committee decisions)

Decided jointly by two design reviewers (Claude Opus 5.5 and GPT-6-Astra) plus the implementer,
after studying BasedHardware/omi at `d4e5a35`. Wire details: `capture-format-v1.md`,
`device-protocol.md`.

## Shape

```
Omi pendant ──BLE──▶ iPhone app (SwiftUI)  ──HTTPS (tailscale serve)──▶  backend (FastAPI, Python)
                     · raw notification journal                          · durable spool + SQLite ledger
                     · offline ring sync                                 · reassemble + Opus decode
                     · background URLSession outbox                      · Silero VAD
                                                                         · per-device segmentation
                                                                         · Deepgram nova-3 (batch)
                                                                         · Claude structured notes
                                                                         · Markdown folder  ◀── the product
```

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | Phone journals **raw BLE notifications** (with the 3-byte header, receive time, CRC). No Opus, no reassembly on the phone. | One parser (Python, heavily tested); raw evidence lets parser fixes recover old audio; minimal phone CPU/battery. Omi's production app also forwards raw Opus and decodes server-side (`ble_device_source.dart`, `receiver.py`). |
| 2 | **Write-first, then upload** immutable ~60 s chunks with `PUT` over a background `URLSession`. No WebSocket. | The product is markdown, not a live view. Omi's dual path (socket + WAL only when the socket is down) is where it loses audio (`capture_controller.dart`). Background sessions survive suspension. |
| 3 | Captures: **one per BLE connection**, one per offline ring sync. | Clean decoder resets and recovery; conversation continuity is handled server-side per device. |
| 4 | Time: one wall-clock anchor per capture + **monotonic** offsets. Ring audio uses each record's device-RTC second. | Wall-clock jumps can't reorder audio. Omi's app keeps only the first record's timestamp and compresses gaps; we keep all. |
| 5 | Server decodes Opus with a small ctypes binding to libopus, 1920-sample buffers, PLC for small seq gaps. | `opuslib` misses Homebrew's lib path and is unmaintained; Omi issue #10701 (buffer sizing). |
| 6 | VAD: Silero (ONNX, CPU), 512-sample windows, threshold 0.5, 300 ms pre-roll / 1 s tail padding, merge < 2 s. Errors never count as silence. | Omi `utils/stt/vad.py`, `vad_gate.py`. |
| 7 | **Per-device segmentation**: a gap ≥ 120 s without speech splits conversations (Omi's constant, `conversation_continuity.py`, `transcribe_decisions.py`). | |
| 8 | **Coverage-aware close**: conversation with last speech end E closes when `[E, E+120 s]` is resolved by *phone evidence* — processed live chunks (`chunk_start..chunk_end` is connected+subscribed time; the mic sleeps in silence so "no records" = silence), heartbeat coverage watermarks, a disconnect gap resolved by a processed `sync_complete` ring seal, or a device without offline storage (gap = known loss, recorded in the note). Otherwise **provisional** close at E+120 s+5 min while a live capture is unsealed, E+120 s+20 min otherwise (`provisional: true`). Symmetrically, a conversation also waits until the 120 s *before* its start is accounted for, so offline audio from just before a reconnect joins it instead of becoming a late note (the phone ring-syncs and seals on every connect; it reports `offline_storage: false` when it knows ring sync is unsupported). | Waits for SD audio after a walk-out-of-range; an open session alone can't distinguish silence from outbox backlog. |
| 9 | **No reopen/merge in v1.** Late speech in a finalized window becomes its own note, `late_audio: true`, with a `related:` link. Double-tap = split now; single-tap = bookmark. | Reopen/merge + deleting donor files is the riskiest code to write without hardware. |
| 10 | Long conversations: soft cap 3 h (split at the next ≥ 20 s gap), hard cap 3 h 10 min. | Continuous speech/TV can't postpone notes forever; parts would fragment meetings. |
| 11 | STT: **Deepgram nova-3 pre-recorded** by default, on VAD-trimmed speech blocks concatenated with 0.5 s spacers + a piecewise time map back to wall clock; `smart_format, punctuate, diarize, utterances`, `language` + keyterms configurable. FLAC upload. Cache raw responses. Also **any OpenAI-compatible `/audio/transcriptions` service** (`STT_PROVIDER=openai`), with request styles for OpenAI `diarized_json`, Mistral Voxtral `diarize`, Together, generic `verbose_json` (vLLM/mlx-audio MOSS-Transcribe-Diarize, LocalAI, whisper.cpp), and text-only `json` (`gpt-transcribe`), splitting at speech-block gaps when a service has a per-request limit. For text-only STT, local diarization runs first; each speaker window is transcribed separately (30 s limit by default), with cached partial responses (keyed on the exact samples and request settings sent, never on window position) and coarse window timing. A window shorter than the service minimum (0.1 s; diarizer edges produce 17–51 ms slivers) is sent as its own samples followed by silence up to 0.25 s, keeping its speaker and times. When local diarization runs but finds no turns, the audio is still transcribed as one window with speaker `unlabeled` (no voiceprints, a warning in the note; no words ⇒ discarded as empty); a diarizer error is retried. Recognition uses the original local turns, never request boundaries. **Speaker labels are required:** provider labels when available and the audio wasn't split, else local diarization (sherpa-onnx: pyannote-segmentation-3.0 + TitaNet, no torch, ~0.03× real time), else the conversation fails with instructions (`STT_DIARIZATION=off` opts out). | Batch is ~half the price of streaming with diarization included and gives consistent speaker labels per conversation (Omi `pre_recorded.py`). OpenAI-compatible + local diarization allows cheaper clouds (Voxtral $0.003/min) and fully self-hosted transcription. |
| 12 | Deterministic relevance rules before the LLM (empty/filler/mic-check discard; reminders and > 100 words keep), ported from Omi `relevance_rules.py`. Never discard solely for short duration. Discarded notes keep their transcript. | Cheap, no API cost for noise. |
| 13 | LLM: **one structured-output call per conversation**. Default Anthropic `claude-opus-5`, `LLM_EFFORT=medium` (omitted for Haiku), server-side refusal fallbacks on; or **any OpenAI-compatible chat completions API** (`LLM_PROVIDER=openai`: OpenAI, Ollama, llama.cpp, LM Studio, vLLM, OpenRouter) with a strict JSON schema, downgrading to JSON mode / prompt-only for servers without schema support. Prompt adapted from Omi's notes-v2 (`conversation_processing.py`): transcript is data not instructions; suggestion ≠ decision ≠ done; never invent names/dates/numbers; speaker names only on explicit evidence. `keep` field folded in. | Quality-first default; cost is the user's choice via config. |
| 14 | Markdown in the vault root (`VAULT_DIR`, local `TIMEZONE`): `Conversations/YYYY/YYYY-MM/YYYY-MM-DD HHmm <Title>.md` (filename frozen at first completion, short-id suffix on collision), `_in-progress/`, `_discarded/`, `Daily/YYYY-MM-DD.md` (deterministic index), `_status.md`. YAML frontmatter via a serializer; atomic temp+fsync+rename; write only when content changes; `My Notes` region preserved on rewrite; a note edited outside it is postponed and resolved explicitly (`note overwrite` keeps the edit in `_omi/displaced/`, or `note freeze`), see `docs/vault.md`. | Human/Obsidian friendly and sync-tool friendly. |
| 15 | Backend: Python 3.13, FastAPI + uvicorn, `uv`, **one vault folder is the only permanent state** (`docs/vault.md`): raw chunks, seals, events, per-conversation records and results, people/voiceprints as files; SQLite (WAL) is a **disposable index** outside the vault, rebuilt from it (rebuild makes zero provider calls). One writer per vault; restart-safe worker loop; PCM is re-decoded on demand. | Everything borrowed from Omi is Python-native; no Redis/Firestore/Cloud Tasks. |
| 16 | iOS: SwiftUI, **iOS 17+**, XcodeGen (`ios/project.yml`, generated project ignored), logic in local SwiftPM package `OmiKit` (testable with `swift test`), `bluetooth-central` background mode + state restoration, no third-party dependencies. | |
| 17 | Auth: one bearer token; server binds `127.0.0.1`, exposed via `tailscale serve` (valid `*.ts.net` HTTPS, no ATS exceptions). Pairing: `omi-notes pair` prints a QR for `omi-notes://configure?url=…&token=…` (custom URL scheme, confirmation sheet, token in Keychain). | |
| 18 | Retention: phone keeps unacknowledged files forever; acknowledged files move to `sent/` and are deleted once processed + 24 h (hard cap 7 days / 1 GB). Storage guard: < 200 MB free → stop journaling, deliberately disconnect and suppress auto-reconnect so the firmware buffers to its SD card. Server keeps raw originals until all dependent conversations finish, then `RAW_RETENTION_DAYS` (30); deletion writes `capture.json` evidence and `.gone` tombstones first so rebuilds and duplicate uploads still work. | |
| 19 | **Speaker learning** (`docs/speaker-learning.md`): WeSpeaker ResNet34 voiceprints via sherpa-onnx; people as `People/<Name>.md`, voiceprints in `_omi/people/`; conservative matching (distance < 0.50, margin ≥ 0.10, ≥ 5 s) with a per-person activation gate (≥ 3 confirmations on ≥ 2 days + leave-one-out; an enrolled wearer may instead confirm ≥ 3 distinct recordings on the same day); wearer enrollment through the pendant (window marked by events, never transcribed); opt-in recurring-voice suggestions; relabeling re-renders from cache. | Omi recognizes the wearer and people (`backend/utils/stt/speaker_match.py`); we keep it local, file-based and consent-gated (voiceprints are biometric data). |

## Not in v1

Live transcript/WebSocket; phone-side decoding or playback; phone-mic capture;
embeddings/search/chat; editing speaker names through note frontmatter; LLM daily summaries; calendar/notifications;
OTA/LED/mic-gain/haptics; OmiGlass; legacy storage protocols (DevKit SD, multi-file 3.0.17–3.0.19);
multi-user; Android; App Store distribution; reopen/merge of finalized conversations.

## Known limits

- Firmware auto-advances its ring read pointer on link-layer delivery, so a phone crash between
  receipt and fsync can lose ~1 s of offline audio. Mitigation: fsync ≥ 1×/s.
- Frames dropped from the device's full TX queue never get a sequence number, so that loss is invisible.
- Force-quitting the app stops BLE restoration until the user reopens it; the device then buffers to SD.
