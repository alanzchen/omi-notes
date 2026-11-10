# omi-notes agent guide

Omi pendant → iPhone app (`ios/`) → your server (`backend/`) → Markdown notes. Read
[`docs/architecture.md`](docs/architecture.md) before changing behavior; every decision there has a reason.

## Map

| Area | Where | Verify with |
|---|---|---|
| Phone ↔ server wire contract | `docs/capture-format-v1.md`, `contracts/fixtures/` | both test suites |
| Portable storage (vault) | `docs/vault.md` | `backend/tests/test_vault*.py` |
| Speaker learning | `docs/speaker-learning.md` | `backend/tests/test_speaker*.py`, `test_enrollment.py` |
| Omi BLE facts (firmware-coupled) | `docs/device-protocol.md` | — |
| Backend (Python 3.13, FastAPI, SQLite) | `backend/src/omi_notes/` | `cd backend && uv run pytest` |
| Local ASR sidecar (opt-in, `STT_LOCAL_URL`) | `sidecar/asr/` (own uv venv, MLX, loopback) | `cd sidecar/asr && uv run pytest` |
| iOS logic (Swift 6, no dependencies) | `ios/Packages/OmiKit/` (`OmiProtocol`, `OmiCapture`, `OmiBLE`) | `cd ios/Packages/OmiKit && swift test` |
| iOS app shell (SwiftUI, iOS 17+) | `ios/OmiNotes/`, `ios/project.yml` | `make ios-build` |
| Omi reference code (read-only) | `/Users/alan/Developer/_ref/omi` (BasedHardware/omi `d4e5a35`) | — |

`make test` runs both suites. For this Mac's TestFlight releases, use the **local signing workflow
below** (`ios/Tools/testflight.sh`, also `make testflight`).

## Rules

- **Contract changes are three-part:** update `docs/capture-format-v1.md`, the backend, and the phone
  together, and regenerate fixtures (`swift test` writes `contracts/fixtures/swift/`;
  `backend/scripts/make_contract_fixtures.py` writes `contracts/fixtures/python/`). Coverage is one
  way: the backend tests parse and decode the Swift fixtures (and post their seals and events through
  the API), and Swift golden tests pin the bytes the phone writes. The phone never parses
  server-built envelopes, so nothing on the Swift side reads the Python fixtures.
- **Raw audio is never deleted** (Alan, 2026-11-08): no retention, cleanup or migration may remove raw chunk files.
- **Durability invariants (never weaken):**
  - The phone journals every notification before anything else and never deletes audio the server
    hasn't acknowledged. Unreadable or unexplained state is quarantined or retried, never deleted.
  - The vault folder is the only permanent state; SQLite is a disposable index rebuilt from it.
    Every permanent fact is written to its vault file (atomically) before the index; never store
    something only in SQLite. The server answers 2xx only after the vault file (and parents of new
    directories) is fsync'd and the index row committed. A decode, VAD, or provider error is never
    treated as silence.
  - Offline storage: read the 16-byte status before writing any command; never send CLEAR; send
    ADVANCE only after DONE status 0 and everything is fsync'd. On 3.0.17–3.0.19 firmware `0x12`
    means DELETE.
- **Firmware facts are cited, not guessed.** Anything in `device-protocol.md` comes from the Omi repo;
  cite the file when you add or change one.
- **Tests are hermetic.** No network, no real providers (`STT_PROVIDER=fake`, `LLM_PROVIDER=fake`), no
  real Bluetooth (use `SimulatedDevice` / fake transports). Fix a bug by writing the failing
  regression test first.
- **One bad row must not stall the backend worker.** Per-row steps catch, record, back off, continue.
- **Generated files stay out of git:** `ios/OmiNotes.xcodeproj` (run `xcodegen generate`),
  `ios/Config/Local.xcconfig` (personal team/bundle id), `backend/.env`, `backend/models/*.onnx`
  (`omi-notes fetch-models`), vaults and indexes, `build/`.
- **Debug-only hooks stay debug-only.** Simulator automation arguments (`-OmiNotesDebug…`) and plain
  `http` for local hosts live behind `#if DEBUG`; Release builds are HTTPS-only.
- **Providers:** STT is Deepgram or any OpenAI-compatible transcription API (`providers/openai_stt.py`);
  LLM is Anthropic or any OpenAI-compatible chat API (`providers/openai_llm.py`). Transcripts must
  have speaker labels (provider or local sherpa-onnx diarization, `pipeline/speakers.py`); never
  silently degrade to one speaker. Provider API shapes change: verify against current docs and keep
  mocked-transport tests for each request/response shape. Claude defaults: `claude-opus-5`,
  structured output, server-side refusal fallbacks (check current SDK docs before changing
  `anthropic_llm.py`).

## Conventions

- Match the surrounding code's style, naming and comment density. Swift 6 language mode; the BLE
  delegate runs on a serial queue and UI state is published on the MainActor.
- Keep the simulator build warning-free and both suites green before committing.
- Commit messages: imperative subject, a body explaining why.

## Development and release checks

- Keep development servers on a separate port with a temporary `VAULT_DIR`, `INDEX_DIR` and
  `LOCK_DIR`, fake providers and simulated Bluetooth. Never point a development worker at the
  running deployment's vault, or load its provider credentials into tests.
- For behavior fixes, reproduce the failure in a regression test first. Run the relevant tests,
  then `make test` and `make ios-build` for a phone/server release. For contract changes, also run
  `cd backend && uv run python scripts/make_contract_fixtures.py`; inspect fixture diffs.
  Documentation-only changes need a diff/link check, not a new app build or deployment.
- Capture release logs, source hashes, build-setting overrides and verification results under
  `build/testflight-ready/<version-and-build>/` or `build/deployment/` (gitignored). Test counts and
  build numbers in old reports are historical evidence; check the current results.
- Verify the exported IPA's version, bundle ID, team, profile, signature, Release settings and
  privacy manifest. Keep debug arguments and local HTTP exceptions out of Release. Record Xcode's
  existing “Metadata extraction skipped, no AppIntents.framework dependency found” tooling warning
  separately from compiler warnings or build failures.

## TestFlight on this Mac

The following setup was verified on **2026-11-07** (build 40); inspect current Apple state before
each release. Reuse the existing app, signing assets, API key and tester group while they remain valid.

| Item | Existing setup |
|---|---|
| App / bundle | Omi Notes / `dev.omi-notes.app` (Watch app `….watchkitapp`, complication `….watchkitapp.widgets`, Live Activity `….liveactivity`) |
| App Store Connect app ID | `6816608105` |
| Developer team | `N9YEGD9WDP` |
| Local signing identity | `Apple Distribution` (check its SHA-1 with `security find-identity -v -p codesigning`) |
| App Store profiles | `Omi Notes App Store`, `Omi Notes Watch App Store`, `Omi Notes Watch Complication App Store`, `Omi Notes Live Activity App Store` (all valid to 2027-09-27) |
| Upload configuration | `~/.appstoreconnect/omi-notes-upload.json` (`key_id`, `issuer_id`, `key_path`, `app_id`) |
| Private API key | `~/.appstoreconnect/private_keys/AuthKey_<key_id>.p8`, file mode `0600`; role is **Developer** |
| Internal Testing group | `b442156a-468f-491b-923c-489bd9548859` |
| Last verified release | `0.1.0 (43)` (2026-11-08, from branch `release/43` `4618a6a` = `main` `db9abfa` with the unapproved Transfers redesign reverted; Live Activity since 40), `VALID`, `IN_BETA_TESTING`; query Apple for the next build number |

**Use `ios/Tools/testflight.sh` (manual local signing, one profile per target).** It archives a
clean `git archive` copy of HEAD (no `Local.xcconfig`, no uncommitted changes), passes
`OMI_APP_BUNDLE_ID` and `OMI_IOS_PROFILE`/`OMI_WATCH_PROFILE`/`OMI_COMPLICATION_PROFILE`/
`OMI_LIVE_ACTIVITY_PROFILE` (never a global `PRODUCT_BUNDLE_IDENTIFIER` or
`PROVISIONING_PROFILE_SPECIFIER`), exports with a four-entry profile map, and checks the IPA. It
creates nothing on Apple's side and needs no Admin key. The Live Activity ships from build 40
(App ID `dev.omi-notes.app.liveactivity`); the app still uses it only when `NSSupportsLiveActivities`
is declared and the extension is embedded (`SyncActivityAvailability`).

1. Query App Store Connect for existing builds (`build/testflight-ready/asc.py GET
   "/v1/builds?filter[app]=6816608105&sort=-uploadedDate&limit=5"`) and choose an unused, increasing
   build number. Commit first: the script refuses a dirty tree. From the repository root:

   ```sh
   TEAM_ID=N9YEGD9WDP OMI_BUILD_NUMBER=<n> \
   OMI_IOS_PROFILE='Omi Notes App Store' OMI_WATCH_PROFILE='Omi Notes Watch App Store' \
   OMI_COMPLICATION_PROFILE='Omi Notes Watch Complication App Store' \
   OMI_LIVE_ACTIVITY_PROFILE='Omi Notes Live Activity App Store' \
   ios/Tools/testflight.sh
   ```

   Output goes to `build/testflight-ready/OmiNotes-<version>-<n>/` (source copy, archive and export
   logs, `ExportOptions.plist`, `ipa-check/`, `ipa-sha256.txt`).

2. Inspect the IPA yourself before uploading: in `ipa-check/Payload/OmiNotes.app`, the app, the
   Watch app, the complication and `PlugIns/OmiNotesLiveActivity.appex` each carry their own bundle
   id, App Store profile and Apple Distribution signature; the Watch app and complication have the
   `N9YEGD9WDP.dev.omi-notes.shared` keychain group; the app declares `NSSupportsLiveActivities`;
   `get-task-allow` is false. Record Xcode's existing
   "Metadata extraction skipped, no AppIntents.framework dependency found" note separately from
   compiler warnings.

3. Upload: read `ASC_KEY_ID` and `ASC_ISSUER_ID` from the private upload configuration (identifiers,
   not the private key), then run the script again with `--upload` on a new build, or upload the
   inspected IPA directly:

   ```sh
   xcrun altool --upload-package "<release dir>/export/OmiNotes.ipa" \
     --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --wait
   ```

4. Wait for Apple processing to report `VALID`. **An upload alone does not publish to testers.**
   Automatic distribution is disabled for the existing group. Add the build to Internal Testing
   through App Store Connect or `POST /v1/betaGroups/{group_id}/relationships/builds` with
   `{"data":[{"type":"builds","id":"<Apple build UUID>"}]}`. Confirm group membership and
   `buildBetaDetail.internalBuildState=IN_BETA_TESTING`; save the evidence and delivery UUID.
   Tell the user the exact version/build to install from TestFlight.

If signing fails because the login keychain is locked or a password/GUI prompt appears, stop and
report it. Use the existing authenticated Chrome session if a portal-only step is needed. Apple
login, two-factor verification and macOS Keychain prompts are completed by the user in the native
UI; never request passwords/codes in chat or print private keys/JWTs. If Chrome blocks a local
upload, its ChatGPT extension needs “Allow access to file URLs”; this was enabled during initial setup.

## Mac Studio backend deployment

This is the existing user deployment, verified on **2026-09-27**. Inspect the service and selected
settings before changing it; repository defaults are not the deployed configuration.

| Item | Location / value |
|---|---|
| Private HTTPS | `https://alan-mac-studio.tailcd4f.ts.net:9443` via Tailscale Serve |
| Loopback API | `http://127.0.0.1:18765` |
| Private configuration | `/Users/alan/.config/omi-notes/server.env` (mode `0600`) |
| Vault | `/Users/alan/OmiNotes` |
| Index base | `/Users/alan/Library/Application Support/omi-notes/index/production` |
| Locks | `/Users/alan/Library/Application Support/omi-notes/locks` |
| Release root | `/Users/alan/.local/share/omi-notes/releases/` |
| Current backend | release `20261108-144916-cbc7c50` (Homebrew Python 3.13.18; index schema 8; prompt v3), live since 2026-11-08 14:50 CST. **Transcribes only with the local ASR sidecar** (`STT_LOCAL_URL=http://127.0.0.1:18793/v1` in `server.env` since 13:36; backup `server.env.before-local-asr-20261108T193600Z`). There is no fallback: while the sidecar is down, conversations wait (`error_kind=stt_unavailable`, attempts untouched, checked every minute); after 10 min down it is a Server-page issue, a log error and `~/Library/Application Support/omi-notes/index/logs/alerts/local-transcription.json`. A stored transcription of either engine is read without a live service. Previous releases: `20261108-143753-bd11f05`, `20261108-140011-c72bde9`; `20261108-033249-0816035` is the last without the sidecar. **Raw audio is kept permanently** (Alan's rule, 2026-11-08): the server has no raw-audio deletion path; `RAW_RETENTION_DAYS` (still `36500` in `server.env`) is ignored. Plan disk for its growth. The vault is format 3. The first phone keep raises the vault to format 3 (releases at or after `a8c74d2` start), the first "keep unknown" of a voice to format 4 (only releases at or after `843248c` start), and the first voice-sample state, flag or voices-file F0 (the Voices hub backend, from `4573e20`; the first voices stage after deploy) to format 6 (only releases at or after `4573e20` start; format 5 is unused), and the first deferred short session or transcription request (recording classes, build 50 merge `classes-50`) to format 7 (only releases at or after that merge start; a format-6 vault from the Voices release has no deferral state and the merge reads it as is); roll back only to a release that reads the vault's current format. The `current` symlink may name an older release; the service plist's absolute path is what runs |
| Service | User LaunchAgent `com.omi-notes.server` in `gui/504` (Alan's decision; switched 2026-10-03 11:29). The system daemon is retired: booted out, disabled, plist moved to `~/.config/omi-notes/system-daemon-retired/`. Check with `~/.config/omi-notes/user-service.sh status` |
| Rotating log | `/Users/alan/Library/Application Support/omi-notes/index/logs/omi-notes.log` |

- **Old transcription path (retired 2026-11-08, Alan: "旧系统不用了"):** Omi no longer calls the proxy below; with `STT_LOCAL_URL` set it only reads that path's stored results. The proxy service itself is not Omi's to stop (other clients may use it). Its code and settings are removed in a separate commit once the backfill is done. As it was: `STT_PROVIDER=openai`, `STT_BASE_URL=https://codex-transcription.zenan.ch/v1`,
  `STT_MODEL=gpt-transcribe`, `STT_REQUEST_STYLE=json`, `STT_DIARIZATION=local`,
  `STT_MAX_REQUEST_SECONDS=30`. This proxy returns text without word timings or speaker labels.
  `pipeline/turn_transcription.py` partitions audio using local diarization before STT and caches
  each request; never feed a whole text-only transcript to post-hoc speaker assignment.
  Timestamps are coarse window boundaries. Recognition uses the original local turns, excluding
  overlap/loss. Local models are Silero VAD, pyannote segmentation + TitaNet for diarization, and
  WeSpeaker for recognition. Enrollment audio and embeddings never go to providers.
- **Local ASR sidecar (live, the only engine):** LaunchAgent `com.omi-notes.asr` (`sidecar/asr/scripts/launchagent.sh status`), 127.0.0.1:18793, log `~/Library/Logs/omi-notes-asr.log`. It runs **from this checkout's `sidecar/asr/`** (its own `.venv`), so a commit there goes live at the next sidecar restart (`launchctl kickstart -k gui/504/com.omi-notes.asr`); keep that tree committed and tested. At startup it loads the models and self-tests (Qwen on 1 s of audio); `/health` answers 503 if that failed or a request runs past 300 s + its audio length, and a watchdog then exits so KeepAlive restarts it. Models unload after 15 min idle (~8.5 GB RSS loaded). Speaker labels are linked across 15-min pieces by WeSpeaker voiceprints (`pipeline/speaker_links.py`).
- **ASR backfill (OMI-ASR-BACKFILL-20261108):** LaunchAgent `com.omi-notes.asr-backfill` runs `build/deployment/asr-backfill-20261108/backfill.py` (forced reprocess, one at a time, only when no live conversation is queued). State, versions of every conversation before its re-transcription, conflicts for Alan and the log are in `~/.local/share/omi-notes/backfill-20261108/`; `touch .../STOP` stops it after the current job.
- **Summaries:** `LLM_PROVIDER=openai`, `LLM_BASE_URL=https://cliproxyapi.cool.zenan.ch/v1`,
  `LLM_MODEL=gpt-6-luna`, `LLM_JSON_MODE=auto`, as requested by the user. Ordinary speech goes to
  the transcription proxy; transcripts go to the summary provider. Credentials stay in
  `server.env`. Read only selected non-secret fields when diagnosing; never dump the whole file.
- **Previous local speech service:** `com.local.mlx-audio` remains an existing login LaunchAgent
  (Whisper large-v3-turbo); it is no longer a backend dependency. Do not remove it as part of a
  backend update. Local VAD/diarization/recognition run in the backend process. FileVault still
  requires an unlock after a cold boot; verify actual boot behavior before claiming unattended use.
- **Wearer calibration:** an accepted enrollment plus explicit confirmations from ≥ 3 distinct
  recordings can activate same-day naming, with the existing leave-one-out and match checks.
  Other people still require confirmations across ≥ 2 days. Enrollment alone is insufficient.
  A calibrated wearer can also match a long single turn with ≥ 10 s, two disjoint ≥ 3 s clips,
  and distance < 0.25; margin and mixed-voice checks still apply (`docs/speaker-learning.md`).
  Alan confirmed the six existing real recordings were all him; their labels were corrected via
  the speaker API. Each assignment needs a globally unique `request_id` for sample deduplication.
- **Storage preference:** the user chose Obsidian Sync and no separate backup. Do not set up Time
  Machine or another backup workflow. Do not assume Sync is configured: verify the remote vault
  connection and inclusion of `_omi/`/other file types when that work is requested. Keep the SQLite
  index outside sync and run only one backend writer against the vault.

### Updating or restarting the backend

**User LaunchAgent (target, from 2026-10-03).** Alan chose a user-level service: no sudo for updates.
- One-time switch-over (done 2026-10-03; recorded here for rollback reference):
  `sudo ~/.config/omi-notes/retire-system-daemon.sh && ~/.config/omi-notes/user-service.sh start`.
  The retire script stops, disables and moves the system plist into `~/.config/omi-notes/system-daemon-retired/`; it deletes nothing and starts nothing.
- After that, deploy a release by making its plist with that release's
  `python -m omi_notes.launchd --write-plist ~/.config/omi-notes/user-agent/com.omi-notes.server.<name>.plist`
  (no `UserName`; credentials stay in the env file), then running `user-service.sh deploy <plist>`. It stops the old server, confirms it is gone (job, pid, port, vault locks), starts the new one, checks readiness, and restores the previous plist on failure. `user-service.sh rollback` goes back one step.
- Never run the system installer (`install-release.sh`) or bootstrap the system daemon while the agent exists. A LaunchAgent runs only while Alan is logged in (it stops at logout, and after a reboot it waits for login).

The steps below describe the retired system daemon. They no longer apply, except for rolling back to it (see the header of `retire-system-daemon.sh`).

1. Prepare a tested release under `releases/` with its own `.venv` (`uv sync --frozen --extra
   diarization`), required models and a `release.json` source-hash manifest. Keep credentials and
   the vault outside the release. Run its `omi-notes doctor` with
   `OMI_NOTES_ENV_FILE=/Users/alan/.config/omi-notes/server.env`.
2. Inspect `launchctl print system/com.omi-notes.server` and the installed plist. **The daemon uses
   an absolute release path, not the `current` symlink. Changing that symlink alone does not deploy.**
   Generate a staged system plist from the new release's `.venv/bin/python -m omi_notes.launchd
   --write-plist /Users/alan/.config/omi-notes/com.omi-notes.server.plist --user alan` with the same
   external environment file. Stop the old writer before starting the new one; switch `current`
   and install/bootstrap the reviewed plist. Keep the old release for rollback.
3. The prepared installer is `/Users/alan/.config/omi-notes/enable-boot-start.sh`; it installs a
   root-owned plist but runs the service as `alan`. Inspect/regenerate its staged plist first.
   System installation needs administrator authentication. Prepare all artifacts before requesting
   that authentication, and show any command the user must run in a normal, copyable chat message.
   Do not reinstall the disabled login service alongside the system daemon. The installer waits for
   the old service to disappear after `bootout`; bootstrapping too early fails with
   `Bootstrap failed: 5: Input/output error` and leaves no server running. If that happens, run
   `sudo launchctl bootstrap system /Library/LaunchDaemons/com.omi-notes.server.plist` once the
   old service is gone (`launchctl print system/com.omi-notes.server` fails).
4. For a restart without changing the plist, gracefully `SIGTERM` the verified `alan`-owned service
   PID; launchd's KeepAlive restarts it. Confirm the new PID and readiness. Alternatively use
   `sudo launchctl kickstart -k system/com.omi-notes.server` when administrator access is available.
5. A small source hotfix to the active release must be explicit and reversible: verify the old
   hash, retain prior source/manifest under `hotfixes/<timestamp>/`, replace files atomically,
   update `release.json`, restart gracefully and verify. Apply the same change to the repository
   **and commit it**: a later release is built from commits, and an uncommitted hotfix would be
   silently removed. Never leave an unrecorded difference between deployed code and its source
   manifest.
6. Build a release only from committed source. Other agents may share this checkout: check
   `git status` and stage explicit files, never `git add -A` over someone else's work.
7. **Vault format:** the first app retry (`POST /v1/conversations/{id}/retry`) raises `VAULT.json`
   to format 2, and a backend older than `bb838fb` then refuses the vault. Roll back only to a
   release that reads format 2; never lower the marker by hand.

For runtime maintenance, use the release's `.venv/bin/omi-notes` with the external environment
file, not an unconfigured checkout command. `retry-failed` and `reprocess` queue work when the
worker is running. Use read-only SQLite access for inspection and derive the actual database path
from `load_settings().db_path`; the index base is not itself the database file.

### Pairing and end-to-end verification

- Preserve the existing Tailscale Serve routes and private HTTPS endpoint; do not enable Funnel.
  The phone must be connected to Tailscale. Pairing QR/deep links contain the bearer token, so do
  not put them in git or logs. The local pairing page is `~/.config/omi-notes/pairing.html`.
  The temporary tailnet pairing page used port `9444` → loopback `18766`, an unguessable route and
  an expiry. Inspect `pairing-web.json` / `serve-pairing.py` in the private config directory before
  reusing it; do not assume the old link still works or serve the whole configuration directory.
- `/healthz` checks HTTP only; `/v1/status` provider readiness is not proof of inference. Verify
  authenticated HTTPS, new uploads and seals, processed chunk counts, queue/errors and actual
  transcript + Markdown output. Use an existing phone recording or a clearly labeled synthetic
  replay; distinguish synthetic deployment captures from real phone traffic in reports.
- Voice enrollment must be accepted without transcription and stay out of recent conversations.
  Speaker review is offered only when `speakers_ready` is true; verify the completed conversation's
  speakers endpoint too. Never fabricate an empty success response for an unfinished transcript.
- `waiting_for` start/end coverage and a later `provisional` close can be normal. Respect the
  documented 120-second gap and coverage fallback; do not force-close conversations, delete audio
  or change segmentation just to empty the queue. Report provider failures separately from waiting.
- After a deployment, verify restart, private HTTPS and queue progress; for ingestion changes,
  also verify a duplicate upload is acknowledged without duplicate processing. Retain sanitized
  evidence under `build/deployment/`, and distinguish server changes already live from phone
  changes that require installing the new TestFlight build.
