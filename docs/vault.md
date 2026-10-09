# Vault: the backend's only permanent state

Committee decision (Claude Opus 5.5 + GPT-6-Astra, converged 2026-09-27). The backend is a worker
pointed at one folder. Everything permanent is plain files in that folder; SQLite is a disposable
operational index. Copy the folder anywhere, point a backend at it, and it rebuilds.

## Guarantees

- **Portable:** `VAULT_DIR` is the only data setting. The vault root is also the notes root
  (Obsidian paths don't move). Secrets (`.env`) and model binaries stay outside.
- **Rebuildable:** a missing/mismatched index is rebuilt from the vault. Rebuilding makes **zero
  provider calls**; resuming unfinished work afterwards may (and a crash between a provider response
  and its file write can repeat one call).
- **Ack semantics unchanged for the phone:** 2xx = the bytes are durable in the vault (file + new
  parent dirs fsync'd) **and** the index row is committed. Not "processed", not "synced".

## Layout

```
<vault>/
  Conversations/ Daily/ People/ _discarded/ _in-progress/ _status.md   Markdown
  _omi/                                   machine data (visible so Obsidian Sync copies it; exclude it from Obsidian search)
    VAULT.json                            {vault_id, format, timezone, created_at, ...render-affecting non-secret settings}
    writer.json                           advisory lease {writer_id, host, pid, started_at, renewed_at}
    raw/<device>/<capture>/<seq>.omnc     phone envelopes — immutable
    raw/<device>/<capture>/<seq>.gone     retention tombstone {sha256, size, header, deleted_at} — immutable
    raw/<device>/<capture>/seal.json      canonical seal body + received_at — immutable
    raw/<device>/<capture>/capture.json   capture metadata written before any raw deletion: ring (seq, record sha, owner chunk),
                                          coverage/loss intervals, continuation checkpoint for a deleted prefix — rewritten (server only)
    raw/<device>/<capture>/receipts.jsonl {seq, sha256, received_at} per accepted chunk — append-only
    events/YYYY-MM-DD.jsonl               {event_id, received_at, body} — append-only (torn tail repaired before appending)
    conversations/YYYY-MM/<id>/conversation.json   decision + render + failure blocks — rewritten atomically (server only)
    conversations/YYYY-MM/<id>/{stt,diarization,llm,voices}-*.json, transcript.json   write-once
    people/<person_id>/samples/<sample_id>.json    voiceprint {model, model_sha, dim, vector_b64, source, seconds, created_at}
    people/<person_id>/enrollment/<id>.omiaudio    wearer's own consented enrollment audio (FLAC bytes; non-attachment extension)
    people/<person_id>/enrollments/<id>.json       enrollment result
    speakers/settings.json                         recognition acknowledgment, unknown-voice opt-in, dismissed suggestions
    displaced/<sha>.md                             user-edited note versions set aside by an explicit "overwrite"
    operations/<request_id>.json                   app retries: accepted → done | failed | superseded (see "Operations")
```

`VAULT.json` `format` is 1 until the first app retry raises it to 2 (records may then carry retry
state), the first keep from the phone raises it to 3 (records may carry `resolution`), and the
first "keep unknown" of a voice raises it to 4 (`speakers.json` label states may be
`source: "unknown"`); an older backend refuses a newer vault instead of rewriting records without
that state.

No lock files, temp files, logs, or caches that aren't referenced results live in the vault.

## Index (operational only)

`~/Library/Application Support/omi-notes/index/<vault_id>-<sha(realpath)[:8]>/index.sqlite3`
(override `INDEX_DIR`). Holds the job queue, retries/backoff, claims, dirty days, and a cache of
file facts. No index migrations: schema version, vault id, or path mismatch ⇒ rebuild.
The host lock (`flock`) lives in the index directory, **not** in the synced vault.

The `search_index` table and the provider telemetry in `meta` are operational: the worker refills
search entries after a rebuild, and telemetry starts over.

Every SQLite column has a declared mapping (vault file, or "operational — rebuilt from X");
a schema-introspection test fails when a column lacks one.

## Write rules

1. Publish dependencies before references (provider result file before `conversation.json` points at it).
2. Each permanent decision is written atomically (temp in same dir → fsync → rename → fsync dir)
   **before** the index transaction; the index commit comes before any 2xx.
3. Orphan file without an index row (crash window): a retry with identical bytes reconstructs and
   commits the row, then returns 200; different bytes → 409. Never overwrite. A startup sweep
   indexes orphans.
4. Receipt timestamps are persisted (`receipts.jsonl`, `received_at` fields), never taken from mtimes.
5. Finalized conversation decisions are persisted (`decision` block incl. `known_through`), never
   recomputed: they depend on wall clock (provisional), arrival order (late audio), processing
   order (double-tap splits) and evidence that retention deletes. Open conversations are not
   persisted; they are recomputed.
6. `speech_watermark` (non-reproducible autoincrement ids) is replaced by
   `known_through: {capture_id: seq}` recorded at finalize; the seal flush counts as virtual chunk
   `last + 1`. Speech from `(capture, seq)` is known to a finalized conversation iff
   `seq <= known_through[capture]`.
7. Render-affecting settings are snapshotted per completed conversation (so config changes don't
   silently rewrite history).

## Notes (architecture #14 amended)

Server-rendered notes stay as they are (standalone Markdown, preserved My Notes region). Each
render records `written_sha`; before a rewrite the server re-reads the file (best-effort guard, not
race-free). If the note was edited outside My Notes: postpone and list it in `_status.md` with two
explicit resolutions — **overwrite** (the user's version is saved to `_omi/displaced/<sha>.md`) or
**freeze** (the server stops re-rendering that note). Conflict copies (same frontmatter `id`,
another path) are reported and never deleted. `_status.md` and stubs rewrite at most once a minute.

## Writer ownership

One writer per vault. Host `flock`s prevent two backends on one host. They live outside the
synced vault in one folder per vault *path* under `LOCK_DIR` (default: next to the index root), so
every process using that vault finds them whatever its `INDEX_DIR`: `api.lock` (one HTTP server —
a second `serve` refuses before it writes anything, not even the index sweep), `worker.lock` (one
pipeline; maintenance commands queue work when they can't take it; `rebuild-index` holds both
throughout), and `speakers.lock` (label read-modify-writes, between the API and a worker thread
or process). The
`_omi/writer.json` lease is **advisory** across hosts: startup refuses a live foreign lease
(renewed < 15 min ago) unless `--take-over`, which is only for after the other writer was stopped.
Divergence — sync conflict-copy filenames or duplicate record ids under `_omi/` — stops writes and
is reported; never auto-merged. Supported setup: the writer's vault is on local disk and sync tools
replicate outward. `doctor` warns for iCloud Drive (`~/Library/Mobile Documents`), and that
Obsidian Sync needs "Sync all other types" and enough storage (30 days of raw ≈ 3–4 GB).

## Operations

A retry requested by the phone (`POST /v1/conversations/{id}/retry`) is durable before it is
acknowledged:

1. Under `operations.lock` and the conversation's work claim, and only for a `failed`, unfrozen,
   unconflicted conversation with no other retry pending: write
   `operations/<request_id>.json` `{id, kind: "retry", conversation_id, stage, failure_kind,
   failure_id, record_sha, requested_at, state: "accepted"}` (`failure_id` names the failed
   attempt; every permanent failure records one in `failure.id`).
2. Commit `retry: {op, stage}` into `conversation.json` (then the index), then bump the reprocess
   counter to wake the worker. `202`.
3. The worker redoes the failed stage (transcribing even when an older transcript exists),
   reusing cached results. The outcome is committed with `retry_outcome: {op, status,
   failure_kind, finished_at}` in the same record write as the success or failure; the operation
   file is then closed (`done` / `failed`, or `stopped` when the note was frozen meanwhile) and
   never changes again.

A record with `retry` but no `failure` (consumed, unfinished) rebuilds as queued at the retried
stage, never as `done` from an older note. Reconciliation (every worker tick, bounded; and a
repeated POST) closes operations whose outcome is recorded, wakes accepted ones a rebuild reset,
and re-queues an operation whose record never got `retry` only while the record is still the failed
attempt it was accepted for (`failure_id`); otherwise it is `superseded`. The sweep resumes where it
stopped, so stuck operations can't starve later ones. A malformed operation file is reported and
never overwritten; a missing one whose outcome is recorded is written again from the outcome. A repeated request id
returns the same operation once its queueing is committed (`409 busy` until then); a request id
reused for another conversation is `409`. Reprocess, resummarize and `retry-failed` leave a
conversation with a pending retry alone (checked in the same statement that queues them), and a
retry isn't accepted while other processing of the conversation is queued. A provider call repeats
only if the process dies between its response and the cache write.

A keep (`POST /v1/conversations/{id}/keep`, `kind: "keep"`, only for a `speakers_unknown` failure)
is the same operation; step 2 also commits `resolution: {kind: "kept_speaker_unknown", op,
resolved_at, failure: {stage, kind, id}}`, which stays in the record for good. With it, the worker
writes the cached unseparated text as a transcript with speaker `unknown` (no labels or voiceprints)
and renders a transcript-only note without a summary; a rebuild reproduces the same note.

## Retention

Deleting `<seq>.omnc` first writes `capture.json` evidence (ring hashes/owners, coverage and loss
intervals, continuation checkpoint if the capture still has later unprocessed chunks) and then
`<seq>.gone`. Re-uploading a deleted chunk returns 200 (same sha) / 409 (different). Rebuild never
needs raw for finalized conversations; `refresh_losses` skips windows with tombstones.
Unknown-voice embeddings are pruned with raw retention.

## Rebuild

1. Take the host lock and the lease; read `VAULT.json` (refuse a newer format).
2. Build `index.tmp`; set `meta.complete = 1` last (a crash just restarts the build).
3. Scan raw: captures, chunks (`pending`; tombstoned → `processed, raw_deleted`), seals, receipts,
   `capture.json` evidence (ring_seen, coverage, losses for deleted prefixes).
4. Load events (dedupe by id; first wins; conflicting body flagged), heartbeat coverage, devices.
5. Load conversation records (status derived: no render → closed; render.kind → done/discarded;
   failure → failed) and people / speaker assignments.
6. Validate: a record referencing a chunk/result/llm_ref that is neither present nor tombstoned ⇒
   the vault opens **read-only** and reports the gap ("incomplete sync is not an empty vault").
7. `replay_pending`: the normal `process_chunks` re-derives speech/coverage/losses/ring_seen for all
   surviving raw (full replay; a whole-capture skip may come later behind the equivalence test).
   `segment_all`, `reconcile_dropped`, `refresh_losses` are gated until replay finishes;
   cache-only renders may run meanwhile.
8. Render every rendered record from its `llm_ref` + `transcript.json` (write-if-changed), then
   dailies, then stubs. Orphan notes are reported, never deleted.

Proofs (tests): golden delete-index rebuild with exploding providers and a pinned clock ⇒
byte-identical vault; copy mid-queue ⇒ same final vault as an uninterrupted run; fault injection
between file write and index commit for chunk/seal/event/finalize/render; retention then rebuild;
seeded randomized arrival/tick interleavings with a rebuild at a random point ⇒ equivalent to the
uninterrupted run; mismatch ⇒ auto rebuild; lease refusal; legacy → `migrate-vault` ⇒ same notes.

## Migration

`omi-notes migrate-vault --notes-dir … --data-dir … --vault-dir …` (worker stopped): copy and
verify raw; tombstones for already-deleted chunks; `seal_json` → `seal.json` byte-for-byte; events →
JSONL; rows → records (`known_through[cap]` = max chunk seq of speech rows with
`id <= speech_watermark`); move `derived/conversations/*` into conversation dirs; write `VAULT.json`
last; dry-run rebuild compare. On any mismatch keep the legacy data and report. Legacy
`NOTES_DIR`/`DATA_DIR` installs refuse to start and print the command. Rebuild/migration
equivalence gates enabling retention under the new model.
