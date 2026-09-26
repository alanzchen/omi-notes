# omi-notes backend

Receives audio chunks from the Omi Notes iPhone app, decodes the pendant's Opus audio, finds
speech, splits it into conversations, transcribes them with Deepgram, summarizes them with
Claude, and writes Markdown notes into a folder. **The folder is the product.**

Design: [`../docs/architecture.md`](../docs/architecture.md). Wire contract:
[`../docs/capture-format-v1.md`](../docs/capture-format-v1.md). Device protocol:
[`../docs/device-protocol.md`](../docs/device-protocol.md).

## Setup (macOS)

```sh
brew install opus uv                 # libopus for decoding; uv manages Python 3.13 + deps
cd backend
uv sync
uv run omi-notes fetch-models        # Silero VAD model (~2 MB, checksum verified)
cp .env.example .env                 # then fill in DEEPGRAM_API_KEY, ANTHROPIC_API_KEY, NOTES_DIR…
uv run omi-notes pair                # creates OMI_NOTES_TOKEN if missing, prints the pairing QR
tailscale serve --bg --https=443 http://127.0.0.1:8765
uv run omi-notes doctor              # checks libopus, VAD, folders, keys, tailscale serve
```

Scan the QR code with the iPhone camera; it opens the app with
`omi-notes://configure?url=https://<mac>.<tailnet>.ts.net&token=…`. The server only listens on
`127.0.0.1`; `tailscale serve` gives it a valid `*.ts.net` HTTPS address on your tailnet (no port
forwarding, no public exposure).

Linux works too: install `libopus0` and `libsndfile1` (or set `OMI_NOTES_LIBOPUS` to the library path).

## Running

```sh
uv run omi-notes serve               # API + worker in one process
./scripts/install-launchd.sh         # …or start it at login (logs in DATA_DIR/logs)
```

`omi-notes serve --no-worker` plus `omi-notes worker` splits upload handling and processing into
two processes. Only one process runs the pipeline at a time (it holds `DATA_DIR/worker.lock`; a
second `serve`/`worker` just accepts uploads). The worker is restart-safe: every stage is idempotent
and cached, so killing the server at any point loses nothing.

`rebuild`, `reprocess` and `retry-failed` run inline when no worker is running; while one is, they
only queue the work for it (so two processes never transcribe or write the same note).

| Command | What it does |
|---|---|
| `serve [--no-worker]` | HTTP API on HOST:PORT (and the processing worker) |
| `worker` | processing worker only |
| `pair [--url URL]` | print the pairing QR (generates a token into `.env` if needed) |
| `doctor` | environment checks |
| `fetch-models` | download + verify the Silero VAD model |
| `rebuild` | re-render every note, daily index and `_status.md` from caches (no API calls) |
| `reprocess <id> \| --since YYYY-MM-DD [--restt] [--force-llm]` | redo STT/summary (caches reused unless forced; queued if a worker runs) |
| `retry-failed` | re-queue failed conversations/chunks after fixing a key or billing problem |
| `synth-wav [out.wav]` | two-voice test recording with macOS `say` and a 150 s pause |
| `replay-wav <file> [--as ble\|pcm] [--speed N] [--drop-rate p]` | push any audio file through the real HTTP contract |

### Trying it without a pendant or API keys

```sh
export STT_PROVIDER=fake LLM_PROVIDER=fake OMI_NOTES_TOKEN=dev NOTES_DIR=/tmp/omi/notes DATA_DIR=/tmp/omi/data
uv run omi-notes serve --port 8799 &
uv run omi-notes synth-wav /tmp/omi/synth.wav
uv run omi-notes replay-wav /tmp/omi/synth.wav --as ble --server http://127.0.0.1:8799 --speed 50
ls /tmp/omi/notes/Conversations/*/*/
```

`replay-wav --as ble` encodes the audio with firmware-like Opus settings into real
`[seq][idx][opus]` BLE notifications (including the mic's silence sleep), uploads ~60 s chunks,
sends coverage heartbeats and seals the capture, i.e. the same path live pendant audio takes.
By default the capture is back-dated so conversations close as soon as they are processed.

## Configuration

All settings come from the environment or `backend/.env`; see [`.env.example`](.env.example).

| Variable | Default | Meaning |
|---|---|---|
| `OMI_NOTES_TOKEN` | — | bearer token shared with the phone (required) |
| `NOTES_DIR` | `~/Documents/OmiNotes` | where notes are written |
| `DATA_DIR` | `~/.local/share/omi-notes` | ledger, raw chunks, caches, logs |
| `HOST` / `PORT` | `127.0.0.1` / `8765` | bind address |
| `TIMEZONE` | this Mac's zone | times and filenames in notes |
| `OWNER_NAME` | — | shown for action items you own |
| `STT_PROVIDER` | `deepgram` | `deepgram` or `fake` |
| `DEEPGRAM_API_KEY` | — | Deepgram key |
| `STT_MODEL` / `STT_LANGUAGE` | `nova-3` / `en` | Deepgram model and language (`multi` = detect) |
| `STT_KEYTERMS` | — | comma-separated terms to boost |
| `LLM_PROVIDER` | `anthropic` | `anthropic`, `fake`, or `none` (transcript-only notes) |
| `ANTHROPIC_API_KEY` | — | Anthropic key |
| `LLM_MODEL` / `LLM_EFFORT` | `claude-opus-5` / `medium` | summary model and effort |
| `CONVERSATION_GAP_SECONDS` | `120` | silence that ends a conversation |
| `PROVISIONAL_WAIT_OPEN_SECONDS` | `300` | extra wait before a provisional close while the phone is connected |
| `PROVISIONAL_WAIT_SECONDS` | `1200` | …and otherwise (e.g. waiting for an offline sync) |
| `SOFT_MAX_CONVERSATION_SECONDS` | `10800` | split long conversations at the next 20 s pause |
| `HARD_MAX_CONVERSATION_SECONDS` | `11400` | hard split |
| `RAW_RETENTION_DAYS` | `30` | keep raw uploads this long after their conversations finish |
| `VAD_BACKEND` / `VAD_THRESHOLD` | `silero` / `0.5` | speech detector |
| `WORKER_TICK_SECONDS` | `5` | worker polling interval |

## The notes folder

```
NOTES_DIR/
  Conversations/2026/2026-09/2026-09-26 1403 Team Finalizes Q2 Budget.md
  Daily/2026-09-26.md                    deterministic index of the day (no LLM)
  _in-progress/2026-09-26 1715 (recording) c7f3a2.md
  _discarded/2026-09-26 1240 c91e0b.md   judged not worth keeping; transcript kept
  _status.md                             devices, queue, errors
```

Each conversation note has YAML frontmatter (`id`, `status`, `provisional`, `late_audio`,
`related`, times in `TIMEZONE`, `speakers`, `audio_gaps`, `revision`, `processed_at`, …), a
summary, key points, Obsidian-Tasks-style action items (`- [ ] … 📅 YYYY-MM-DD`), decisions, open
questions, events, people, bookmarks (single taps on the pendant), a **My Notes** section and the
timestamped transcript.

- Write anything between `<!-- my-notes:start -->` and `<!-- my-notes:end -->`: it survives every
  regeneration. Everything else in a note is regenerated.
- Filenames are fixed when a note is first written; later title changes only change the heading
  and frontmatter, so links keep working. Files are only rewritten when their content changes.
  If the markers are ambiguous (e.g. a second `<!-- my-notes:start -->`), the note is left
  untouched and `_status.md` says so until you fix it.
- Known audio loss (dropped Bluetooth packets, offline records the pendant overwrote or never
  delivered) is listed in `audio_gaps` / `audio_lost_s` with a warning in the note.
- A conversation ends after 120 s without speech (or a double tap on the pendant). If the audio
  needed to prove it ended hasn't arrived (e.g. the pendant was out of range and its offline
  recording hasn't synced), the note is written after a wait with `provisional: true`. Audio that
  arrives after a note was written becomes its own note with `late_audio: true` and a `related`
  link; finished notes are never merged.

## Privacy

Audio stays on your Mac except for what the providers need: **speech segments are sent to
Deepgram** for transcription and **transcripts are sent to Anthropic** for summaries (both only
when those providers are configured). Raw uploads are kept in `DATA_DIR/raw` for
`RAW_RETENTION_DAYS` after their conversations are finished; transcripts and provider responses
are cached in `DATA_DIR/derived`. The server is reachable only on your tailnet, with a bearer token.

## Troubleshooting

- **`libopus not found`**: `brew install opus`, or point `OMI_NOTES_LIBOPUS` at `libopus.0.dylib`.
- **`_status.md` says the VAD model is missing**: `uv run omi-notes fetch-models`. Until then a
  crude energy detector is used.
- **Notes stay in `_in-progress/`**: open `_status.md`. "waiting for end/start window" means the
  server has not yet received the audio proving the conversation ended (phone outbox backlog, or an
  offline sync after the pendant was out of range). It closes provisionally after
  `PROVISIONAL_WAIT_*`.
- **A provider rejected the key or billing (401/402/403)**: fix `.env`, restart, then
  `uv run omi-notes retry-failed`. With a failing LLM the transcript-only note is written anyway.
- **Phone can't connect**: `uv run omi-notes doctor` (is `tailscale serve` proxying to the right
  port?), and check the token with `omi-notes pair`.
- **Changed the prompt or model**: `omi-notes reprocess --since 2026-09-01 --force-llm`.

## Development

```sh
uv run pytest                        # hermetic: fake providers, synthetic audio, no network
uv run python scripts/make_contract_fixtures.py   # regenerate contracts/fixtures/python
```

Layout: `envelope.py` (wire format), `ingest.py` + `api.py` (HTTP), `spool.py` (durable writes),
`db.py` (SQLite ledger), `device/` (BLE framing, ring records), `audio/` (Opus, timeline, VAD),
`pipeline/` (segmenter, worker, conversation stages, transcript/time map, relevance rules,
prompt), `providers/` (Deepgram, Anthropic, fakes), `notes/` (schema, render, writer, daily,
status), `devtools.py` (fixture/replay synthesis), `cli.py`.
