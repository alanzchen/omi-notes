# omi-notes agent guide

Omi pendant → iPhone app (`ios/`) → your server (`backend/`) → Markdown notes. Read
[`docs/architecture.md`](docs/architecture.md) before changing behavior; every decision there has a reason.

## Map

| Area | Where | Verify with |
|---|---|---|
| Phone ↔ server wire contract | `docs/capture-format-v1.md`, `contracts/fixtures/` | both test suites |
| Omi BLE facts (firmware-coupled) | `docs/device-protocol.md` | — |
| Backend (Python 3.13, FastAPI, SQLite) | `backend/src/omi_notes/` | `cd backend && uv run pytest` |
| iOS logic (Swift 6, no dependencies) | `ios/Packages/OmiKit/` (`OmiProtocol`, `OmiCapture`, `OmiBLE`) | `cd ios/Packages/OmiKit && swift test` |
| iOS app shell (SwiftUI, iOS 17+) | `ios/OmiNotes/`, `ios/project.yml` | `make ios-build` |
| Omi reference code (read-only) | `/Users/alan/Developer/_ref/omi` (BasedHardware/omi `d4e5a35`) | — |

`make test` runs both suites. `make testflight` uploads a Release build (see `ios/README.md`).

## Rules

- **Contract changes are three-part:** update `docs/capture-format-v1.md`, the backend, and the phone
  together, and regenerate fixtures (`swift test` writes `contracts/fixtures/swift/`;
  `backend/scripts/make_contract_fixtures.py` writes `contracts/fixtures/python/`). Coverage is one
  way: the backend tests parse and decode the Swift fixtures (and post their seals and events through
  the API), and Swift golden tests pin the bytes the phone writes. The phone never parses
  server-built envelopes, so nothing on the Swift side reads the Python fixtures.
- **Durability invariants (never weaken):**
  - The phone journals every notification before anything else and never deletes audio the server
    hasn't acknowledged. Unreadable or unexplained state is quarantined or retried, never deleted.
  - The server answers 2xx only after fsync (file, and parents of new directories) and a committed
    ledger row. A decode, VAD, or provider error is never treated as silence.
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
  (`omi-notes fetch-models`), `data/`, `build/`.
- **Debug-only hooks stay debug-only.** Simulator automation arguments (`-OmiNotesDebug…`) and plain
  `http` for local hosts live behind `#if DEBUG`; Release builds are HTTPS-only.
- **Claude API code:** default model `claude-opus-5` (configurable via `LLM_MODEL`); structured output
  plus server-side refusal fallbacks. Check current SDK docs before changing
  `backend/src/omi_notes/providers/anthropic_llm.py`.

## Conventions

- Match the surrounding code's style, naming and comment density. Swift 6 language mode; the BLE
  delegate runs on a serial queue and UI state is published on the MainActor.
- Keep the simulator build warning-free and both suites green before committing.
- Commit messages: imperative subject, a body explaining why.
