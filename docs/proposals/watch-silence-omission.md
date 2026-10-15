# Proposal: conservative silence omission on the Apple Watch (draft, not implemented)

**Status:** contract draft plus an offline replay prototype (`backend/scripts/silence_replay.py`).
Nothing in the apps or server implements it yet. Full capture stays the default.

## Goal
The Watch keeps its microphone open (no wake-from-off) but stops encoding, storing and sending
audio during long stretches of near-digital silence, without ever losing speech or making a gap
look like silence.

## What the Watch would send
- **Detector:** per 20 ms frame, using the replay prototype's defaults.
  - A frame is silent only if it is within 3 dB of an adaptive noise floor **and** below −50 dBFS.
  - Only runs of at least 20 s are omitted, minus 2 s of pre-roll before and 2 s of tail after
    any non-silent frame (kept as audio).
  - A noisy room (floor above −50 dBFS) omits nothing. On anything uncertain (format change,
    interruption, conversion error), it keeps the audio.
- **A silent part** is a `WatchSegment` with `silence: true`, `bytes: 0`, no file, and exact
  monotonic `start_offset_us`/`end_offset_us` (frame-counted, like audio parts).
  - It takes the **next index** in the recording's sequence, so `WatchRecordingEnd.lastIndex` and
    the phone's "seal after every part" rule are unchanged.
  - It travels as user info (no file), with the same acknowledgement and resend rules. Its
    identity is `(recording_id, index)`, so it is idempotent.
- **Effect on segmentation:** a silent span splits the 60 s parts (kept audio, silent part, kept
  audio). `SegmentWriter` closes the open file at the span's start, as it does at an interruption.

## What the phone would upload
- **Server advertises `watch_silence`:** a `watch_mic` chunk with `payload_format: "silence_v1"`,
  the same `(capture_id, chunk_sequence)` as its index, `chunk_start/end_offset_us` from the part,
  `record_count` = the span's sample count, and an empty payload.
- **Older server:** the phone expands the span into a `pcm16le_v1` chunk of zeros. That is exactly
  what such a server receives today for a silent minute, so behavior is unchanged; only upload
  bytes are not saved.

## What the server would do (`watch_silence`)
- **Coverage:** a `silence_v1` chunk is processed coverage with no speech. The segmenter counts it
  toward `[E, E+120 s]`, so notes don't wait for the provisional close. VAD and STT are skipped
  for it.
- **Recording and playback:** the span plays as zeros in `recording.wav` and is marked
  `omitted_silence` in the timemap. It is **not** a `gap`, which stays reserved for missing
  chunks, interruptions and lost audio. Silence is never inferred from absence.
- **Duplicate detection** (`sources.py`): the span's envelope is the noise floor, not missing
  (`NaN`), so a pendant recording of the same quiet moment still correlates on the speech around
  it.
- **Retry/idempotence:** the same as audio chunks: same identity, same bytes, `200` on repeat.

## Rollback and gate
- **Rollback:** an internal Watch option, off by default. Turning it off restores full capture;
  servers keep accepting `silence_v1` from older Watch builds.
- **Gate before turning it on:**
  1. Room levels from real Watch audio show a meaningful share of frames below −50 dBFS. This is
     measured on the server from uploaded `watch_mic` chunks, with no extra Watch work. The Watch
     microphone's gain control may keep its floor higher, and then this would never omit
     anything.
  2. A local replay of real Watch recordings, never sent to a provider, shows zero speech in
     omitted spans.
  3. Battery summaries (`/v1/watch/performance`) compare like-for-like recordings.

## Replay prototype (synthetic, 2026-10-15)
| Scenario | Omitted | Speech in omitted spans |
|---|---|---|
| Quiet room (−63 dBFS): normal, quiet and far speech | 80.3 % | 0 s (ground truth and Silero) |
| Quiet room: 0.25 s words alone | 78.5 % | 0 s |
| Quiet room: whisper about 6 dB above the room | 94.6 % | 0 s |
| Noisy room (−38 dBFS) | 0 % | – (kept whole) |
| Quiet room, clicks only | 92.9 % | 0 s |

The speech is synthetic, not human. Real Watch noise floors are unknown, so these shares are an
upper bound for an unusually quiet room, not an estimate of savings.
