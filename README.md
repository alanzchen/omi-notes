# omi-notes

Your own pipeline for the [Omi](https://omi.me) wearable: an iPhone app that pairs with the pendant
and ships its audio to a server you run, which transcribes it and writes **Markdown notes**
(summary, key points, decisions, action items, full transcript) into a folder. The folder can
live inside an Obsidian vault.

```
Omi pendant ──BLE──▶ iPhone app ──HTTPS (Tailscale)──▶ backend on your Mac ──▶ ~/Documents/OmiNotes/
                     journal + upload                  decode · VAD · Deepgram · Claude
```

| Directory | What it is |
|---|---|
| [`ios/`](ios/README.md) | SwiftUI app (iOS 17+). Pairs with the pendant, journals raw BLE audio durably, syncs the pendant's offline storage, uploads chunks in the background. |
| [`backend/`](backend/README.md) | Python/FastAPI server. Reassembles and decodes Opus, detects speech, splits conversations, transcribes with speaker labels (Deepgram or any OpenAI-compatible service, plus optional local diarization), summarizes (Claude or any OpenAI-compatible LLM), writes the notes. |
| [`docs/`](docs/) | [Architecture decisions](docs/architecture.md), [phone ↔ server contract](docs/capture-format-v1.md), [Omi BLE protocol notes](docs/device-protocol.md). |
| `contracts/fixtures/` | Envelopes produced by each side and checked by the other side's tests. |

## Quick start

On the Mac that will run the server:

```bash
make setup                       # brew opus/uv/xcodegen, uv sync, fetch the VAD model
cp backend/.env.example backend/.env
#   fill in DEEPGRAM_API_KEY and ANTHROPIC_API_KEY (VAULT_DIR/TIMEZONE optional)
make pair                        # generates the token, prints a QR code for the app
tailscale serve --bg --https=443 http://127.0.0.1:8765
make server                      # or backend/scripts/install-launchd.sh to start at login
```

On the iPhone (Tailscale connected):

1. `make ios`, pick your personal team (or set it in `ios/Config/Local.xcconfig`), and run on the phone.
2. Scan the `make pair` QR code with the Camera app and confirm the server shown.
3. Disconnect the official Omi app (the pendant accepts one phone at a time), then pick your pendant.

Notes appear in the vault folder (`VAULT_DIR`) about two minutes after a conversation ends:

```
OmiNotes/
  Conversations/2026/2026-09/2026-09-26 1403 Team Finalizes Q2 Budget.md
  Daily/2026-09-26.md          # the day's conversations and open action items
  _in-progress/                # stubs while a conversation is still open
  _discarded/                  # noise / mic checks, kept with their transcript
  _status.md                   # device, queue and error status
  People/                      # one note per person you've taught the server
  _omi/                        # machine data: audio, records, transcripts, voiceprints
```

Anything you write between the `My Notes` markers in a note is preserved when it is regenerated.

**The folder is the whole system state.** Copy it to another machine, point a backend at it, and
it rebuilds its (disposable) index from the files, with no transcription or LLM calls
([docs/vault.md](docs/vault.md)). In the app's **People** tab you can teach it your voice and
name people, so notes say who spoke ([docs/speaker-learning.md](docs/speaker-learning.md)).

## Try it without a pendant or API keys

```bash
cd backend
STT_PROVIDER=fake LLM_PROVIDER=fake uv run omi-notes serve &
uv run omi-notes synth-wav /tmp/talk.wav           # two voices, a long pause
uv run omi-notes replay-wav /tmp/talk.wav --as ble # encodes like the firmware, uploads like the phone
```

The iOS app also has a simulated pendant (Server › Developer tools, debug builds) that replays real CV1-format Opus in the Simulator.

## How it works (short version)

- The phone never decodes audio. It journals every BLE notification (with a CRC) before doing
  anything else, then uploads ~60 s immutable chunks. A chunk is deleted from the phone only after
  the server has fsync'd it and answered 2xx.
- While the phone is away, the pendant records to its own storage; on reconnect the app downloads
  that backlog (firmware ≥ 3.0.20) while live audio keeps streaming.
- The server segments per device across live and offline audio. A conversation ends after 120 s
  without speech, Omi's own rule, but only once the phone has proven that stretch was silence
  rather than missing audio (otherwise the note is written after a short wait and marked provisional).
- Only detected speech is transcribed: Deepgram by default (batch pricing, speaker labels
  included), or any OpenAI-compatible transcription service (Mistral Voxtral, OpenAI, Together,
  or a self-hosted server). Every transcript gets speaker labels, from the service or from local
  diarization (sherpa-onnx, `uv sync --extra diarization && uv run omi-notes fetch-models
  --diarization`). Noise is filtered by deterministic rules before any LLM call. Each
  conversation is one structured call to Claude (`claude-opus-5` by default) or to any
  OpenAI-compatible chat API (OpenAI, Ollama, llama.cpp, LM Studio, vLLM).

The design was worked out by a two-model committee (Claude Opus 5.5 and GPT-6-Astra) after
studying [BasedHardware/omi](https://github.com/BasedHardware/omi). The code was reviewed by
GPT-6-Astra. See [docs/architecture.md](docs/architecture.md) for each decision and the Omi code
it borrows from.

## Tests

```bash
make test        # backend pytest + OmiKit swift test
make ios-build   # simulator build of the app
```

## Privacy

Audio stays on your phone and your Mac, except that detected speech goes to your transcription
service and transcripts go to your LLM service (Deepgram and Anthropic by default). Point both at
self-hosted servers and nothing leaves your machines. The server listens on localhost only and is
reachable over your tailnet through `tailscale serve`, behind a bearer token.
