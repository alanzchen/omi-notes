# Omi Notes — iPhone app

The phone is an **audio courier**. It pairs with an Omi pendant over Bluetooth LE, journals every
audio notification to disk first, pulls the pendant's offline backlog (ring storage), and uploads
immutable chunk files to your own omi-notes server. The server does the decoding, transcription
and note writing. The phone never decodes Opus or reassembles frames.

Contract: [`docs/capture-format-v1.md`](../docs/capture-format-v1.md). Device facts:
[`docs/device-protocol.md`](../docs/device-protocol.md). Design decisions:
[`docs/architecture.md`](../docs/architecture.md).

## Layout

```
ios/
  project.yml                  XcodeGen spec (OmiNotes.xcodeproj is generated and gitignored)
  Config/Base.xcconfig         shared settings; includes the optional Local.xcconfig
  Config/Local.xcconfig.example
  OmiNotes/                    thin SwiftUI app: App/ (entry, AppDelegate), Features/, Resources/
  Packages/OmiKit/             all logic, testable with `swift test` on the Mac
    Sources/OmiProtocol/       GATT ids, ring protocol, button/codec/firmware parsing, CRC32, OMINOTE1 envelope
    Sources/OmiCapture/        journal, chunk rotation, outbox, uploader, ring sync, recovery, retention, storage guard
    Sources/OmiBLE/            CoreBluetooth central, per-connection sequence, simulated device, engine, app model
  Tools/make_sim_trace.py      regenerates the simulated-device trace and the test Opus packets
```

## Build and test

Requires Xcode 27 or later (iOS 27 SDK), and XcodeGen (`brew install xcodegen`). The deployment
target is iOS 17. There are no third-party dependencies.

```sh
cd ios/Packages/OmiKit && swift test          # all unit + integration tests (macOS host)
cd ios && xcodegen generate                   # creates OmiNotes.xcodeproj
xcodebuild -project OmiNotes.xcodeproj -scheme OmiNotes \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

`swift test` also rewrites the deterministic contract fixtures in
[`contracts/fixtures/swift/`](../contracts/fixtures/swift/README.md). The backend's test suite
parses them.

## Install on your iPhone

1. **Signing.** Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (it is
   gitignored). Set:
   - `DEVELOPMENT_TEAM`: your team id. A free Apple ID "Personal Team" works; add it in
     Xcode › Settings › Accounts. The id appears in the team list, or at developer.apple.com ›
     Membership for paid accounts.
   - `PRODUCT_BUNDLE_IDENTIFIER`: something unique to you, e.g. `com.yourname.omi-notes`.
2. `cd ios && xcodegen generate && open OmiNotes.xcodeproj`
3. Connect the iPhone with a cable (or pair it for Wi‑Fi debugging). Choose it as the run
   destination and press Run.
4. First time only, on the phone:
   - Settings › Privacy & Security › **Developer Mode** → on, then restart.
   - With a free Personal Team, if iOS says the developer is untrusted: Settings › General ›
     **VPN & Device Management** › your Apple ID › Trust.
5. With a free Personal Team the provisioning profile expires after 7 days. Run from Xcode again
   to renew it. Your recordings are kept; the app just won't launch until you re-sign it.

## Pairing

1. **Server.** Set up Tailscale on the Mac and the iPhone so both are on the same tailnet. On the
   Mac, start the server and run `omi-notes pair`. Scan the QR code with the iPhone **Camera**
   app. The `omi-notes://configure?url=…&token=…` link opens the app, which shows a
   confirmation sheet with the destination host and a masked token. Tap **Save**. The token goes
   into the Keychain (readable after first unlock, so background uploads work). You can also
   enter the URL and token by hand in Settings, and **Test connection** calls `GET /v1/status`.
   - Use the `https://<mac>.<tailnet>.ts.net` URL that `tailscale serve` provides. Release builds
     accept only `https`. Debug builds (the default when you run from Xcode) also accept plain
     `http` for local-network hosts (`localhost`, `*.local`, private and Tailscale IPs) with a
     warning.
2. **Bluetooth.** Allow Bluetooth when asked. The app keeps a Bluetooth connection in the
   background (`bluetooth-central`).
3. **Device.** Onboarding, or Settings › Pair a device, lists nearby Omi pendants. Tap yours. The
   app remembers it and reconnects on its own from then on.
   - **Only one phone app can connect to the pendant at a time.** Disconnect or quit the official
     Omi app first, or the pendant won't show up.

Pendant button: **single tap** = bookmark (shown in the note); **double tap** = end the current
conversation now. A 3 s long press powers the pendant off.

## What happens while it runs

- Each BLE connection is one *live capture*. Audio notifications are appended to a CRC-protected
  journal (fsync at least once per second). About every 60 s, after 5 s without audio, on
  disconnect, on a double tap, or when the app goes to the background, the journal becomes an
  immutable `OMINOTE1` chunk in the outbox.
- On every connect to firmware ≥ 3.0.20, the app downloads the pendant's offline backlog. This is
  what the pendant recorded while the phone was away. The app then seals the sync so the server
  knows the gap is covered.
- Uploads go through a background `URLSession` (`PUT`, with a SHA-256 header), so they keep
  going while the app is suspended and resume after relaunch. Files the server rejects for good
  (409/413/422, or 400 five times) are **kept**, not deleted. They show under "Needs attention".
- Acknowledged files stay in `sent/` until the server has processed them plus 24 h (hard cap:
  7 days / 1 GB). Unacknowledged audio is never deleted.
- **Storage guard:** below 200 MB free, the app stops recording and deliberately disconnects so
  the pendant buffers to its own storage. It reconnects once 300 MB are free again.
- Data lives in `Application Support/OmiNotes/` (excluded from backups):
  `journal/{live,ring}/`, `outbox/{pending,sent,quarantine}/`, `state/`.

## Background behavior and limits

- iOS wakes the app for Bluetooth events and relaunches it through state restoration if the
  system terminated it. While the pendant streams, the app stays scheduled. When the pendant's
  mic sleeps in silence (after ~10 s of quiet) the app is suspended; the next sound wakes it.
  None of this loses audio.
- **Force-quitting the app** (swiping it away in the app switcher) stops restoration and
  reconnection until you open it again. The pendant records to its own storage meanwhile, and
  that audio is synced on the next connection. Don't force-quit it.
- After a phone restart, open the app once. Nothing can run before the first unlock anyway, since
  files and the token are protected until then.
- Out of range or Bluetooth off: the app keeps a pending connection, which costs nothing. The
  pendant buffers to its storage (only if its clock is valid: the app sets it on every connect).
- Firmware limitation: the pendant frees offline audio once it has *sent* it, so a phone crash
  in the ~1 s between receiving and fsyncing can lose that second.
- Low Power Mode and poor reception can delay uploads. They are never dropped.

## Simulator

BLE doesn't work in the Simulator. Turn on **Debug › Simulated device**. It replays a real
Opus trace (CELT 20 ms, the CV1's format) in real time, with a silence gap each loop so idle
rotation happens. It also serves a fake offline backlog through the ring protocol. The Debug tab
can simulate taps, walking out of range for 15 s, forced rotation, heartbeats, retries, and
shows the (token-redacted) log.

- Background uploads and the Keychain need a **signed** build. Running from Xcode signs it
  automatically ("Sign to Run Locally"). A `CODE_SIGNING_ALLOWED=NO` build runs, but it can
  neither save the token nor start background uploads.
- Debug builds accept automation launch arguments:
  `-OmiNotesDebugServerURL http://localhost:8765 -OmiNotesDebugToken <token>` to configure the
  server, and `-OmiNotesDebugOpenURL 'omi-notes://configure?…'` to open the pairing sheet.
  `xcrun simctl spawn booted defaults write <bundle-id> omi.simulatedDevice -bool YES` turns on
  the simulated device before launch.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Pendant not in the scan list | Disconnect or quit the official Omi app (one connection at a time); check the pendant is on and charged; check Bluetooth is allowed (Settings › Omi Notes). |
| "Unsupported device" | The pendant reported an audio codec other than Opus 20/21. The app refuses to record rather than produce garbage. Update the firmware. |
| "Pairing information removed" | iOS kept a stale bond. Settings › Bluetooth › (i) next to the Omi › Forget This Device, then tap **Reconnect** in the app. |
| "Token rejected (401)" | Uploads are paused. Re-scan the `omi-notes pair` QR code or fix the token in Settings. |
| Server unreachable | Is Tailscale connected on the iPhone? Is `tailscale serve` running on the Mac? Try **Test connection**. |
| Files under "Kept, not uploaded" | The server refused them permanently (409/413/422). They are kept on the phone. Check the server logs, then **Debug › Re-queue kept files**. |
| "Offline sync unsupported" | Firmware older than 3.0.20 (or no offline storage). Live capture still works, but audio while disconnected can't be recovered. |
| "Device clock invalid" | The pendant drops offline recording while its clock is invalid. The app sets it on every connect; reconnect once. |
| "MTU payload low" | CV1 frames need an ATT MTU ≥ 166. Frames may be fragmented or dropped; move closer or restart Bluetooth. |
| "No audio yet" | Normal in a quiet room: the pendant's mic sleeps until there is sound. |
| Phone storage low | Free space. Recording resumes automatically at 300 MB free; the pendant buffers meanwhile. |
