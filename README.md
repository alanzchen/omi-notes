# omi-notes

Your own note-taking pipeline for conversations: record with an [Omi](https://omi.me) pendant, an
Apple Watch, or both. An iPhone app collects the audio and ships it to a server you run, which
transcribes it and writes **Markdown notes** (summary, key points, decisions, action items, full
transcript) into a folder. The folder can live inside an Obsidian vault.

```
Omi pendant ───BLE───────────────┐
                                 ▼
                          iPhone app ──HTTPS (Tailscale)──▶ backend on your Mac ──▶ ~/Documents/OmiNotes/
                                 ▲   journal + upload         decode · VAD · transcription · LLM
Apple Watch ──WatchConnectivity──┘
```

The two sources are independent: use the pendant alone, the Watch alone (no pendant needed), or
both at once. There is no App Store or public TestFlight build; you build and sign the apps
yourself (see [`ios/README.md`](ios/README.md)).

| Directory | What it is |
|---|---|
| [`ios/`](ios/README.md) | SwiftUI iPhone app (iOS 17+) with an Apple Watch app (watchOS 10+) and a watch-face complication. The iPhone pairs with the pendant, journals raw BLE audio durably, syncs the pendant's offline storage, receives the Watch's recordings, and uploads everything in the background. |
| [`backend/`](backend/README.md) | Python/FastAPI server. Reassembles and decodes the pendant's Opus (and the Watch's AAC, with ffmpeg), detects speech, splits conversations, transcribes with speaker labels (Deepgram or any OpenAI-compatible service, plus optional local diarization), summarizes (Claude or any OpenAI-compatible LLM), writes the notes. |
| [`docs/`](docs/) | [Architecture decisions](docs/architecture.md), [phone ↔ server contract](docs/capture-format-v1.md), [Omi BLE protocol notes](docs/device-protocol.md). |
| `contracts/fixtures/` | Envelopes the phone writes (parsed by the backend's tests) and reference envelopes for the server's decoder. |

## Quick start

On the Mac that will run the server:

```bash
make setup                       # brew opus/ffmpeg/uv/xcodegen, uv sync, fetch the VAD model
cp backend/.env.example backend/.env
#   fill in DEEPGRAM_API_KEY and ANTHROPIC_API_KEY (VAULT_DIR/TIMEZONE optional)
make pair                        # generates the token, prints a QR code for the app
tailscale serve --bg --https=443 http://127.0.0.1:8765
make server                      # or backend/scripts/install-launchd.sh to start at login
```

On the iPhone (Tailscale connected):

1. Put your team and your own `OMI_APP_BUNDLE_ID` in `ios/Config/Local.xcconfig` (see
   [Install on your iPhone](ios/README.md#install-on-your-iphone)), then `make ios` and run on the phone.
2. Scan the `make pair` QR code with the Camera app and confirm the server shown.
3. **Pendant:** disconnect the official Omi app (the pendant accepts one phone at a time), then
   pick your pendant.
4. **Apple Watch:** in the iPhone's Watch app, install Omi Notes (under Available Apps), open it on
   the Watch and tap the red microphone (allow the microphone the first time). It records until you
   tap Stop, subject to interruptions and system limits (see
   [Apple Watch recording](ios/README.md#apple-watch-recording)).

A note is written once a conversation has ended (120 s without speech, or Stop on the Watch) and
its audio has reached the server. That is usually a few minutes after you stop talking. It takes
longer while audio is still waiting on the pendant, the Watch or the phone (out of range, offline,
server unreachable), and a Watch-only conversation that overlaps a pendant one waits for it (up to
30 min). Waiting audio is kept and queued for retry; when it gets through depends on connectivity,
storage and the OS. Notes go to the vault folder (`VAULT_DIR`):

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
To try the Watch app without a Watch, see "Simulator" in [`ios/README.md`](ios/README.md#simulator).

## How it works (short version)

- The phone doesn't decode the pendant's audio. It journals every BLE notification (with a CRC)
  before doing anything else, then uploads ~60 s immutable chunks. A chunk is deleted from the
  phone only after the server has fsync'd it and answered 2xx.
- While the phone is away, the pendant records to its own storage; on reconnect the app downloads
  that backlog (firmware ≥ 3.0.20) while live audio keeps streaming.
- The Watch records only after you tap Start, in the background (wrist down, screen off) in
  one-minute AAC parts until you tap Stop, unless an interruption or the system stops it. Each part
  stays on the Watch until the iPhone has stored it and confirmed its hash. The iPhone relays the
  Watch's AAC file unchanged when the server advertises that it can decode it (it needs ffmpeg);
  otherwise it converts the part to 16 kHz PCM first, and a recording that started as PCM stays
  PCM. "On iPhone" on the Watch means the iPhone has it, not that the server or your notes do.
- The server segments per device across live and offline audio. A conversation ends after 120 s
  without speech, Omi's own rule, but only once the phone has proven that stretch was silence
  rather than missing audio (otherwise the note is written after a short wait and marked provisional).
  A Watch recording also ends its conversation when you tap Stop. If the pendant heard the same
  conversation, the server compares the two recordings' loudness over time and, when they match,
  keeps the Watch audio as an alternate recording instead of writing a second note.
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
make ios-build   # simulator build of the iPhone app, with the Watch app and the extensions
```

## Privacy

Audio goes from the pendant (Bluetooth) or the Watch (WatchConnectivity) to your iPhone, and from
there only to your own server. The server sends detected speech to your transcription service and
transcripts to your LLM service (Deepgram and Anthropic by default); point both at self-hosted
servers (and use local diarization) and no audio or text leaves your machines. Voice enrollment and
voiceprints stay on your server. The server listens on localhost only and is reachable over your
tailnet through `tailscale serve`. Every `/v1/` API route requires the bearer token; `/healthz` and
FastAPI's generated API docs (`/docs`, `/openapi.json`) answer without it and contain no notes or
audio.

## Not released yet

The repository also contains a Live Activity that shows sync progress on the Lock Screen and in
the Dynamic Island. It builds, but it is not in a released build yet and hasn't been checked on a
real Lock Screen. Everything else described here, Apple Watch support included, is part of the
current app.
