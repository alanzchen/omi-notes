# Capture format v1 and phone ↔ server API

This is the contract between the iPhone app (`ios/`) and the backend (`backend/`).
Both sides must change together. Test fixtures live in `contracts/fixtures/`.

## Principles

- The phone is an **audio courier**. It does not decode Opus or reassemble frames. It journals
  the raw bytes it receives from the device and uploads them as immutable chunk files.
- The server does framing, decoding, VAD, segmentation, STT, and summarization.
- Chunks are a **transport unit**, not a conversation boundary. Conversations are segmented
  per device on the server across all captures (live and offline storage).
- A successful upload response means "durably stored in the server's vault (file and new parent
  directories fsync'd, see `docs/vault.md`) and indexed/queued". It does
  **not** mean transcribed.
- Everything is idempotent: re-uploading an identical chunk is a no-op success.
- Nothing that the server has not acknowledged is ever evicted from the phone.

## Identity

| Name | Meaning |
|---|---|
| `capture_id` | Lowercase UUID minted by the phone. **One live capture per BLE connection** (from subscribe to disconnect). **One ring capture per offline-storage sync session.** |
| `chunk_sequence` | 0, 1, 2, … within a capture. No holes; the server only processes contiguous prefixes. |
| `device_id` | The CoreBluetooth peripheral identifier (lowercase UUID string) of the Omi device. Stable per phone+device pair. |
| `event_id` | Lowercase UUID minted by the phone for a side event (button, heartbeat). |

## Clocks

- `capture_started_at` is the single wall-clock anchor for a capture: the phone's UTC wall time
  when the capture began (live: first subscribe; ring: sync start).
- Everything inside a capture is measured from a **monotonic** clock (`ContinuousClock` /
  `mach_continuous_time`) started at the same instant: `chunk_start_offset_us`,
  `chunk_end_offset_us`, and per-record `t_offset_us` (relative to the chunk start).
  Wall-clock changes (NTP, manual) during a capture therefore cannot reorder chunks.
- A chunk spans less than 4294 s (u32 microseconds). The phone rotates chunks every ~60 s.
- Chunks are **back to back**: chunk n's `chunk_end_offset_us` equals chunk n+1's
  `chunk_start_offset_us`. A hole is rendered as an audio gap in the note.
- A seal's `end_offset_us` equals the last chunk's `chunk_end_offset_us` (for an empty capture, the
  offset at which it ended).
- Ring records additionally carry the device's own RTC second (`[unix_ts:u32 BE]`), which the
  server uses as the time base for offline audio.

## Envelope

Every chunk body is one envelope:

```
offset  size          field
0       8             magic, ASCII "OMINOTE1"
8       4             header_len, u32 little-endian
12      header_len    header, UTF-8 JSON object (max 16 KiB)
12+H    payload_bytes payload (format given by header.payload_format)
```

The total body must be exactly `12 + header_len + payload_bytes` bytes. Max body 8 MiB.

### Header JSON

| Field | Type | Notes |
|---|---|---|
| `schema_version` | int | `1` |
| `capture_id` | string | must equal URL path value |
| `chunk_sequence` | int | must equal URL path value |
| `device_id` | string | |
| `device_name` | string \| null | advertised name, informational |
| `model_number` | string \| null | Device Information `2A24` |
| `firmware_revision` | string \| null | `2A26` |
| `hardware_revision` | string \| null | `2A27` |
| `source` | string | `live_ble` \| `device_ring` \| `wav_replay` |
| `payload_format` | string | `ble_notifications_v1` \| `ring_records_v1` \| `pcm16le_v1` |
| `codec_id` | int | `20` Opus 10 ms (DevKit), `21` Opus 20 ms FS320 (CV1). `pcm16le_v1` uses `0`. PCM ids 0/1 over BLE are **not supported** in v1 (no current firmware emits them). |
| `sample_rate` | int | `16000` |
| `channels` | int | `1` |
| `capture_started_at` | string | ISO-8601 UTC with milliseconds, e.g. `2026-09-26T19:32:05.123Z` |
| `chunk_start_offset_us` | int | monotonic µs from capture start to this chunk's start |
| `chunk_end_offset_us` | int | monotonic µs from capture start to this chunk's end. For `live_ble` the interval `[start, end]` is **coverage**: the phone was connected and subscribed for all of it, so an absence of records inside it means the device mic was asleep (silence), not missing audio. |
| `clock_quality` | string | `phone_anchored` (live, replay), `device_seconds` (ring, RTC valid), `unknown` |
| `timezone` | string \| null | Phone IANA timezone, informational |
| `record_count` | int | see payload formats |
| `payload_bytes` | int | exact payload length |
| `offline_storage` | bool \| null | live only: `true` if the device supports ring sync (fw ≥ 3.0.20, features bit 6), `false` if definitely not, `null` if unknown. When `false`, BLE disconnect gaps can never be filled, so the server does not wait for them. |
| `ring` | object \| absent | required iff `payload_format == ring_records_v1`, see below |
| `app_version` | string \| null | informational |

`ring` object: `{"first_sequence": int, "record_size": 444, "read_seq": int, "write_seq": int, "dropped": int}`
where `read_seq`/`write_seq`/`dropped` are the values from the INFO notification at the start of the
sync (so the server can report records the device overwrote before we could read them).

Unknown extra header fields must be ignored by the server.

### Payload `ble_notifications_v1` (source `live_ble`)

`record_count` repeated records, each exactly as the phone received one BLE notification on the
audio characteristic `19b10001-…`:

```
size       field
4          t_offset_us   u32 LE, monotonic receive time relative to the chunk start, µs
2          length        u16 LE, number of notification bytes (includes the 3-byte Omi header)
1          flags         bit0 = SESSION_START: first notification after a (re)subscribe;
                                the server resets frame assembly and the Opus decoder
                         bits1-7 reserved, 0
length     bytes         raw notification value, unmodified
4          crc32         u32 LE, CRC-32 (IEEE 802.3, same as zlib.crc32) over the
                         preceding 7 + length bytes of this record
```

The notification bytes are firmware format `[seq:u16 LE][fragment_index:u8][payload…]`
(see `device-protocol.md`). The server does fragment reassembly, loss detection and PLC.
The phone's journal on disk uses this same record format, so torn-tail recovery after a crash
is exact (stop at the first record whose CRC fails).

### Payload `ring_records_v1` (source `device_ring`)

`record_count × ring.record_size` bytes: complete offline-storage records exactly as reassembled
from `NOTIFY_DATA` bytes. Record `i` has device ring sequence `ring.first_sequence + i`. Records in
one chunk are consecutive sequences. Record layout is firmware format (`device-protocol.md`):
`[unix_ts:u32 BE][440 bytes packed [len:u8][opus bytes]…, zero padded]`.

Dedupe happens on both sides: the phone drops records whose sequence is ≤ its last persisted
sequence for the device (the firmware can resend records past its last checkpoint), and the
server dedupes on `(device_id, ring_sequence)` (comparing bytes, so a firmware reflash that
restarts sequences is not mistaken for a duplicate).

### Payload `pcm16le_v1` (source `wav_replay`, developer tooling)

Raw signed 16-bit little-endian mono PCM at 16 kHz. `record_count` = number of samples,
`payload_bytes = 2 × record_count`. The audio starts at `chunk_start_offset_us`.

## HTTP API

All `/v1/*` endpoints require `Authorization: Bearer <token>`. JSON responses use
`Content-Type: application/json`. Errors are `{"error": "<code>", "detail": "<text>"}`.

### `GET /healthz`

No auth. `200 {"ok": true}`.

### `GET /v1/status`

```json
{
  "ok": true,
  "server_version": "0.1.0",
  "protocol_version": 1,
  "server_time": "2026-09-26T19:32:05.123Z",
  "server_started_at": "2026-09-26T08:00:00.000Z",
  "stt": {"provider": "openai", "model": "whisper-large-v3-turbo", "diarization": "local", "ready": true},
  "llm": {"provider": "anthropic", "model": "claude-opus-5", "ready": true},
  "queue": {"chunks_pending": 0, "conversations_open": 1, "conversations_pending": 0, "failed": 0,
            "conversations_failed": 0, "chunks_failed": 0, "conversations_retrying": 0, "notes_conflicted": 0},
  "worker": {"present": true},
  "last_note_at": "2026-09-26T19:20:41.002Z",
  "vault_dir": "/Users/alan/Notes/Omi",
  "notes_dir": "/Users/alan/Notes/Omi",
  "read_only": null,
  "features": ["voice_enrollment", "conversation_detail", "issues"]
}
```

`features` lists optional capabilities (absent on older servers). The phone starts a voice
enrollment only when it contains `voice_enrollment`: a server that doesn't know the enrollment
events would transcribe the reading as a conversation. `conversation_detail` and `issues` announce
the app views below.

The response is cheap and calls no provider: `ready` means *configured*, not that inference works.
`worker.present` means a process holds the vault's worker lock (the pipeline, or a maintenance
command); it is not proof of progress. `last_note_at` is when the newest kept note was first
written (discarded and enrollment rows excluded). `read_only` is the reason the vault stopped
accepting writes, or null. `failed` is the sum of `conversations_failed` and `chunks_failed`, kept
for older phones. Model labels are non-secret; base URLs and keys are never reported. Fields added
after v1's first release may be absent on older servers; the phone treats absence as unknown.

### `PUT /v1/captures/{capture_id}/chunks/{chunk_sequence}`

Body: one envelope. Headers:

- `Content-Type: application/octet-stream`
- `X-Content-SHA256: <lowercase hex sha256 of the whole body>` (required)

| Status | Meaning | Phone action |
|---|---|---|
| `201` | Stored for the first time (file fsync'd in the vault + index committed) | mark acknowledged (move to `sent/`) |
| `200` | Identical chunk already stored | mark acknowledged |
| `400` | `X-Content-SHA256` mismatch / HTTP body length mismatch | re-verify the local file's SHA-256; retry up to 5 times, then quarantine |
| `401` | Bad token | stop, show "needs attention" |
| `409` | Different content already stored under this identity | stop retrying this chunk, keep it, show "needs attention" |
| `413` | Too large | keep (quarantine), show "needs attention" |
| `422` | Envelope invalid (bad magic, header, header/payload length mismatch, record CRC, unsupported codec) | keep (quarantine), show "needs attention" |
| `5xx` | Transient (incl. `507` disk full) | retry with exponential backoff + jitter |

Success body: `{"capture_id": "…", "chunk_sequence": 12, "sha256": "…", "stored": true, "duplicate": false}`

### `PUT /v1/captures/{capture_id}/seal`

JSON body:

```json
{"last_chunk_sequence": 12, "reason": "ble_disconnected", "ended_at": "2026-09-26T19:42:00.000Z", "end_offset_us": 612000000, "device_id": "…", "source": "live_ble"}
```

| `reason` | Meaning |
|---|---|
| `ble_disconnected` | live: link lost |
| `user_stopped` | live: user disconnected / stopped |
| `device_forgotten` | live: user removed the device |
| `app_recovered` | live or ring: found unsealed on app launch; `end_offset_us` = last journaled record. For ring captures it carries no ring evidence and does **not** resolve coverage (like `sync_interrupted`). |
| `sync_complete` | ring: DONE received with status 0 and every record fsync'd. **Resolves coverage**: every BLE-disconnected interval of this device that ended before `ended_at` is now fully represented by uploaded ring captures. `ended_at` must be ≥ the reconnect time that started the sync. When the device reports 0 unread records the phone still creates and seals an empty ring capture (`last_chunk_sequence: -1`, `sync_complete`) so the gap resolves immediately. |
| `sync_interrupted` | ring: sync stopped early (disconnect, error). Does **not** resolve coverage. |
| `replay_complete` | dev tooling |

Ring seals (`sync_complete` / `sync_interrupted`) also carry the evidence the server needs to
activate coverage:

```json
{"last_chunk_sequence": 3, "reason": "sync_complete", "ended_at": "…", "end_offset_us": 41000000,
 "device_id": "…", "source": "device_ring",
 "ring": {"generation": 1, "info_read_seq": 1200, "info_write_seq": 1520, "done_next_seq": 1520,
          "dropped": 0, "rtc_valid": true, "covers_until": "2026-09-26T19:40:02.000Z"}}
```

`ring.covers_until` and `ring.info_read_seq` are **required** on `sync_complete` (422 otherwise).
Seals and events are type-strict: timestamps are ISO-8601 strings, all numbers are JSON integers.
`covers_until` is the reconnect time (the firmware stops writing to storage once a phone connects,
so the INFO snapshot contains everything recorded while disconnected); the server uses it, falling
back to `ended_at`. On **every** connect to a ring-capable device the phone runs a sync and seals it,
so the server can also resolve the 120 s before a conversation's start. `generation` is a phone-side
counter per device, incremented when INFO shows sequences going backwards (storage reset/reflash).
Coverage from a `sync_complete` seal activates only when (1) its chunks `0…last_chunk_sequence` are
all received **and processed**, (2) every earlier ring capture the server knows for that device and
generation is processed, and (3) ring sequences are contiguous: the server has processed that
device's ring records up to `info_read_seq − 1` within the generation (or this is the first ring data
for that device+generation). Because the server can't know about an earlier ring capture whose chunks
never arrived, the phone also holds back a `sync_complete` seal until every earlier ring capture for
the device is fully acknowledged (all chunks and its seal answered 2xx). A `sync_complete` requires
the transfer to have reached the INFO snapshot's `write_seq`; anything short of that is
`sync_interrupted`.

`last_chunk_sequence` may be `-1` for an empty capture. `device_id` and `source` are always required
(an empty capture has no chunk header to identify it). Seals are immutable: the same seal body twice
returns `200` (the first seal also returns `200`); a seal that differs from an earlier one returns `409`; a chunk with a sequence above a
sealed capture's `last_chunk_sequence` returns `409`. The server finalizes the capture only once chunks `0…last_chunk_sequence` are all present; a
seal never authorizes skipping missing chunks. Response: capture status (below).

### `PUT /v1/events/{event_id}`

Small JSON side events, uploaded through the same durable outbox:

```json
{"device_id": "…", "type": "button", "at": "2026-09-26T19:40:00.000Z", "data": {"code": 2}}
```

| `type` | `data` |
|---|---|
| `button` | `{"code": 1}` single tap = bookmark (rendered in the note); `{"code": 2}` double tap = end the current conversation now |
| `voice_enrollment_start` | `{"enrollment_id": "<uuid>"}` with top-level `capture_id` + `offset_us` (window start on the live capture). The phone holds that capture's chunks from here until this event is acknowledged. |
| `voice_enrollment_end` | `{"enrollment_id": "<uuid>", "end_offset_us": 55000000, "outcome": "completed" \| "cancelled" \| "interrupted"}` with top-level `capture_id` + `offset_us` (= the end). Held by the phone until the start is acknowledged. Speech inside the window is never transcribed; only `completed` windows are judged for enrollment (`docs/speaker-learning.md`). |
| `heartbeat` | `{"battery": 83, "charging": false, "firmware_revision": "3.0.21", "model_number": "Omi CV 1", "rtc_valid": true, "offline_unread": 0, "outbox_chunks": 3, "outbox_bytes": 812345, "app_state": "background", "coverage": {"capture_id": "…", "through_offset_us": 734000000, "through_chunk_sequence": 11}}` (all optional) |

`201` first receipt, `200` duplicate (same id and body), `409` same id with a different body (keep,
flag). Heartbeats feed `_status.md`.

`button` events also carry `"capture_id"` and `"offset_us"` (monotonic offset within that live
capture) so the server places them on the capture timeline; a split is applied only once the
capture's audio up to that offset has been processed. An event that lands inside an
already-finalized conversation is annotated, never used to reopen it.

**Coverage watermark.** `heartbeat.data.coverage` says: the phone was connected and subscribed for
live capture `capture_id` from its start through `through_offset_us`, and every notification
received before that offset is in chunks `≤ through_chunk_sequence`. The server treats the
interval as covered only after those chunks are processed. A heartbeat only references chunks that
have already been rotated into the outbox, never the open journal. Rotated chunks already carry their own coverage (`chunk_start..chunk_end`), so no separate event is
sent at rotation; the phone sends heartbeats on connect, periodically while awake, and when the app
wakes — they are how silent stretches with no rotated chunk yet become evidence.

### `GET /v1/captures/{capture_id}`

```json
{
  "capture_id": "…",
  "source": "live_ble",
  "sealed": true,
  "last_chunk_sequence": 12,
  "received_ranges": [[0, 12]],
  "processed_through": 12
}
```

`processed_through` = highest `chunk_sequence` such that all chunks `0…n` have been decoded and
run through VAD/segmentation (−1 if none). It does **not** mean transcribed; the server keeps its
own raw originals until every conversation using them is finished (and then for
`RAW_RETENTION_DAYS`), so the phone may delete its `sent/` copy of chunk `n` once
`n <= processed_through` and the copy is ≥ 24 h old. The phone's hard cap (sent files older than
7 days, or `sent/` above 1 GB, oldest first) wins over this rule: acknowledged chunks are already
durable on the server. Unacknowledged files are never deleted. `404` for unknown capture.

### `GET /v1/conversations/recent?limit=20&before=<cursor>`

Newest first (`start` descending, then id), for the app's home screen. Voice enrollment recordings
(including those still waiting for the enrollment to end) are excluded before applying the limit.
`next_cursor` is null on the last page; pass it back as `before` for the next one. Cursors are
opaque; a malformed one is `422 invalid_cursor`.

```json
{"conversations": [{"id": "…", "status": "done", "state": {"code": "ready", "message": "Note ready"}, "issues": [],
  "started_at": "…", "ended_at": "…", "duration_s": 312.4, "title": "Team Finalizes Q2 Budget", "emoji": "💰",
  "preview": "The team agreed on…", "speaker_names": ["Priya"],
  "note_path": "Conversations/2026/2026-09/2026-09-26 1403 Team Finalizes Q2 Budget.md",
  "late_audio": false, "provisional": false, "speakers_ready": true}],
 "next_cursor": "1790449380.25:01923f…"}
```

Conversation `status`: `open` → `closed` → `transcribing` → `summarizing` → `done` | `discarded`
(no meaningful content), or `failed` (retryable; see `_status.md`). `note_path` is relative to the
notes directory.

`state` is the display chip, chosen by precedence from the row; the raw `status` stays alongside.
Codes: `listening` (open; the message says what it is waiting for), `processing`, `retrying` (an
automatic retry is scheduled), `ready`, `transcript_only` (summary failed or summaries are turned
off: the message says which), `failed` (no note), `discarded`. Messages are chosen by the server from
the failure kind, never copied from a provider error. `issues` lists problems that coexist with
readable content: `reprocess_failed` (an earlier note is still shown), `note_conflict` (edited
outside My Notes; the server stopped updating it), `render_retrying`. `provisional`, `late_audio`
and lost audio are caveats, not issues. `preview` is the start of the summary's overview (null when
no current summary is readable); `speaker_names` are the people assigned to this transcript's
speakers.

`speakers_ready` is true once a closed conversation has a persisted transcript, even while
summarization is pending or has failed. The phone offers speaker details only when it is true;
the speakers endpoint remains unavailable before transcription. This additive field may be absent
on older servers; the phone then offers details only for `done` or `discarded` rows with a note path.
Every field after `title` except `note_path`, `late_audio` and `provisional` is additive: older
servers omit them and the phone falls back to `status`.

## App views

Read-only endpoints for the phone. They never call a provider, move speaker labels or repair the
index. The index row names the current transcript (`transcript_sha`) and summary (`llm_ref`); a
file that describes another generation (a reprocess in flight) is reported as `updating` rather
than mixed into the answer, and a row that changes while the files are read is read again once.

### `GET /v1/conversations/{id}?segments_from=0`

`404` for unknown ids and voice enrollment readings; `200` for every other conversation, open ones
included (with nothing to show yet). The body is the list entry plus:

```json
{"speech_s": 280.1, "lost_s": 0, "note_state": "matches", "note_frozen": false,
 "my_notes": "Call Priya back.", "my_notes_unreadable": false, "discard_reason": null,
 "transcript_sha": "…", "speakers_revision": 3, "revision": 2,
 "summary_state": "ready",
 "summary": {"overview": "…", "sections": [{"heading": "…", "bullets": ["…"]}],
             "action_items": [{"description": "Send the budget", "owner": "me", "owner_name": "Alan", "due_date": "2026-09-30"}],
             "decisions": ["…"], "open_questions": ["…"]},
 "transcript_state": "ready",
 "speakers": [{"label": "S1", "name": "Priya"}, {"label": "S2", "name": null}],
 "transcript": {"total": 812, "from": 0, "next_from": 500,
                "segments": [{"start": "…", "end": "…", "speaker": "S1", "name": "Priya", "text": "…"}]}}
```

- `summary_state`: `ready`, `pending`, `disabled` (summaries turned off), `failed` (then
  `summary_error` is a sanitized sentence), `not_applicable` (discarded before summarizing),
  `updating`, `unavailable` (the referenced file is missing or unreadable).
- `transcript_state`: `ready`, `pending`, `updating`, `unavailable`. Segments come 500 at a time;
  `next_from` is the `segments_from` of the next page (null on the last).
- Speaker names are shown only when the stored assignments were made for this transcript.
- `note_state`: `none` (no note yet), `matches` (the saved Markdown is what the server wrote, apart
  from My Notes), `differs` (edited elsewhere: the phone shows this generated view with a banner),
  `missing`. `my_notes` is the text of the note's My Notes block; `my_notes_unreadable` is true when
  its markers are ambiguous. Action items are read-only.

### `GET /v1/issues?limit=20`

What needs attention, most urgent first, bounded and sanitized:

```json
{"issues": [{"code": "conversation_failed", "severity": "action", "message": "The summary service rejected the server's credentials.",
             "next_step": "Fix the provider settings on the server, then run `omi-notes retry-failed` on the Mac.",
             "conversation_id": "…", "started_at": "…", "title": null}]}
```

Codes: `read_only` (with `detail`), `worker_stopped`, `chunks_failed` (with `count`),
`conversation_failed`, `note_conflict`, `conversation_retrying`. Severity is `action` (someone must
do something) or `delayed` (the server retries on its own).
