# Omi device BLE protocol (what we use)

Derived from BasedHardware/omi at `d4e5a35` (2026-09-25). Paths below are relative to that repo.
Firmware differs between releases, so everything optional is discovered at runtime, never assumed.

Targets: **Omi CV1** (`omi/firmware/omi`, nRF5340; DIS model `"Omi CV 1"`, fw 3.0.2x) is the production
target, with live capture and offline ring sync. **DevKit** (`omi/firmware/devkit`, codec 20) is
supported for live capture only.

## GATT

`O(xxxx)` = `19b1xxxx-e8f2-537e-4f6c-d104768a1214`. Short UUIDs are standard Bluetooth SIG UUIDs.
No characteristic requires pairing/bonding (Omi never bonds). Custom characteristics accept
**write with response only**.

| Purpose | Service | Characteristic | Required | Use |
|---|---|---|---|---|
| Audio stream | `O(0000)` | `O(0001)` | yes | notify — **subscribe first**, see routing below |
| Audio codec | `O(0000)` | `O(0002)` | yes | read, first byte = codec id |
| Battery | `180F` | `2A19` | no | read + notify, `value[0]` = percent |
| Device info | `180A` | `2A24` model, `2A26` firmware, `2A27` hardware, `2A29` manufacturer, `2A25` serial (absent on CV1) | no | read, UTF-8 |
| Features | `O(0020)` | `O(0021)` | no | read, u32 LE bitmask; bit 6 = offline storage (CV1 = `0x1EC`) |
| Time sync | `O(0030)` | `O(0031)` write / `O(0032)` read | no | write **exactly 4 bytes**, Unix seconds u32 LE, on every connect |
| Button | `23ba7924-0000-1000-7450-346eac492e92` | `23ba7925-0000-1000-7450-346eac492e92` | no | notify, 8 bytes: i32 LE event + 4 zero bytes |
| Charging | `O(0010)` | `O(0013)` | no | read + notify, u8 0/1 |
| LED brightness | `O(0010)` | `O(0011)` | no | read + write, u8 0–100 (see "Pendant settings") |
| Microphone gain | `O(0010)` | `O(0012)` | no | read + write, u8 level 0–8 |
| Vibration | `cab1ab95-2ea5-4f4d-bb56-874b72cfc984` | `cab1ab96-2ea5-4f4d-bb56-874b72cfc984` | no | write u8 1/2/3 |
| Firmware update (SMP) | `8d53dc1d-1db7-4cd3-868b-8a527460aa84` | `da2e7828-fbce-4e01-ae9e-261174997c48` | no | write without response + notify (see "Firmware update") |
| Storage | `30295780-4301-eabd-2904-2849adfeae43` | `30295781-…` control/data (write + notify), `30295782-…` status (read) | no | offline ring sync |

Sources: `app/lib/services/devices/models.dart`, `app/lib/services/devices/connectors/omi_connection.dart`,
`omi/firmware/omi/src/lib/core/{features.h,transport.c,button.c,storage.c}`, `omi/firmware/omi/omi.conf`.

Button events (CV1 emits only 1, 2, 5): `1` single tap → bookmark, `2` double tap → end conversation
now, `5` release → ignored. A ≥ 3 s long press powers the device off and sends nothing.

## Firmware behaviors the app must respect

- **Routing** (`transport.c` `pusher()`): connected + subscribed → audio goes to BLE; **no connection →
  audio goes to the SD ring, but only if storage works and the RTC is valid**; **connected but not
  subscribed, or MTU < 100 → audio is dropped**. So
  subscribe to `O(0001)` immediately after characteristic discovery, before anything else.
- **Mic silence sleep**: after ~10 s below an amplitude threshold the mic sleeps even while connected,
  and notifications stop until there is sound again (`mic.c`). A lull is silence, not a fault. The
  app's liveness watchdog only means "no notification at all within N s of subscribing".
- **One central at a time** (`CONFIG_BT_MAX_CONN=1`). The official Omi app must be disconnected.
- **Clock**: uptime-based RTC restored from the last sync. **SD recording is dropped entirely while the
  RTC is invalid** (`sd_card.c`). Write the time on every connect and read it back.
- **Slow connection setup**: the firmware requests connection params / PHY / data length / MTU inside its
  connect callback (~1.3 s); early GATT operations may lag.
- **Scanning**: advertises name `"Omi"` + service `O(0000)`. OmiGlass reuses `O(0000)` — exclude names
  containing `glass`. DevKit 2's advertising payload may not include the UUID, so the foreground pairing
  scan uses `withServices: nil` and matches on service UUID **or** name ∈ {`Omi`, `Omi DevKit 2`, `Friend`}.

## Pendant settings

From `omi/firmware/omi/src/lib/core/transport.c` (settings handlers, `features_read_handler`),
`src/settings.c`, `src/mic.c` (`mic_set_gain`), `src/led.c` and `src/haptic.c`; the reference tree's
`omi.conf` sets `CONFIG_BT_DIS_FW_REV_STR="3.0.21"`, the firmware of the production CV1.

- **Advertised in features:** bit 5 haptic (`CONFIG_OMI_ENABLE_HAPTIC=y` on CV1), bit 7 LED dimming and
  bit 8 mic gain (always set). The app offers a control only when its characteristic is discovered
  **and** its bit is set; unreadable features mean no controls.
- **LED brightness `O(0011)`:** one byte, capped at 100; the LED PWM duty is `period × ratio / 100`, so
  0 turns the LED off. Default 50.
- **Mic gain `O(0012)`:** one byte, capped at 8, applied immediately. Levels: 0 mute, 1 −20 dB,
  2 −10 dB, 3 0 dB, 4 +6 dB, 5 +10 dB, 6 +20 dB (default), 7 +30 dB, 8 +40 dB. Level 0 records silence.
- Both are saved with `settings_save_one` and loaded at boot, so they persist across reconnects and
  restarts. **A write succeeds even when the flash save fails** (the handler returns `len`), and a
  read returns the in-memory value; so a readback confirms the active value, not that it survives a
  reboot. Any other write length is rejected (`BT_ATT_ERR_INVALID_ATTRIBUTE_LEN`).
- **Vibration:** writing 1, 2 or 3 vibrates for 100, 300 or 500 ms; other values are ignored. The
  Omi app's Find Device plays level 3 three times, 750 ms apart
  (`app/lib/services/devices/connectors/device_connection.dart` `playFindDevicePattern`).
- The app reads these after the connection is ready (never ahead of offline sync) and confirms
  every write by reading it back.

## Pausing recording and collecting stored audio (phone choices)

- **Pause** (the Omi app's double-tap "mute"): the app turns `O(0001)` notifications off. Per the
  routing rule above the firmware then drops its audio while connected (nothing reaches BLE or the
  SD ring); if the link drops, it records to its ring as usual. The live capture is sealed
  `user_stopped`; anything still received is journaled. Kept across launches until resumed.
- **Manual collection**: offline sync is not started on connect; the 16-byte status is read (a read
  writes nothing) to show what is waiting. The ring overwrites its oldest batches when full
  (`src/sd_card.c`, `overwritten_end_seq` / `dropped_packets`), so audio left there can be lost.

## Firmware update (CV1)

Source facts (reference tree, firmware 3.0.21):
- MCUmgr SMP over BLE is enabled: `omi.conf` `CONFIG_NCS_SAMPLE_MCUMGR_BT_OTA_DFU=y`. MCUboot,
  overwrite-only, downgrade prevention, two updatable images (application core, network core):
  `sysbuild.conf` (`SB_CONFIG_MCUBOOT_MODE_OVERWRITE_ONLY`, `MCUBOOT_UPDATEABLE_IMAGES=2`,
  `MCUBOOT_NRF53_MULTI_IMAGE_UPDATE`), `sysbuild/mcuboot.conf` (`CONFIG_MCUBOOT_DOWNGRADE_PREVENTION`).
  Secondary slots 0xF0000 and 0x40000 in external flash (`boards/omi/pm_static.yml`). Signing key
  RSA-2048 (`SB_CONFIG_BOOT_SIGNATURE_KEY_FILE`).
- The SMP service/characteristic UUIDs (`8d53dc1d-1db7-4cd3-868b-8a527460aa84` /
  `da2e7828-fbce-4e01-ae9e-261174997c48`, write without response + notify) are Zephyr's standard
  ones (`smp_bt.c`); they are not written in the Omi repo.
- Release metadata: the Omi backend's `GET /v2/firmware/latest?device_model=…&firmware_revision=…`
  (404 when nothing newer) and `/v2/firmware/stable?device_model=…`, no account required
  (`backend/routers/firmware.py`); the Omi app calls them in `app/lib/backend/http/api/device.dart`.
  `is_legacy_secure_dfu: false` for CV1 (`.github/workflows/firmware_release.yml`). The Omi app
  requires ≥ 15 % battery unless charging (`firmware_mixin.dart` `kFirmwareUpdateMinBattery`).

Checked against the published artifacts (3.0.17–3.0.21, read 2026-10-10): the OTA zip holds
`manifest.json` with image 0 `omi.signed.bin` (board `omi`) and image 1 `ipc_radio.bin` (board
`omi/nrf5340/cpunet`); both are MCUboot images with a SHA-256 TLV and the same key hash
(`fc5701dc…cfa9994`); the MCUboot header version is `0.0.0+0`, so the DIS firmware string is the only
version. The backend answered 3.0.21 for 3.0.20, 404 for 3.0.21, and 3.0.21 as stable.

What the app does: only the official package for exactly the offered version
(`github.com/BasedHardware/omi/releases/download/Omi_CV1_v<version>/`), checked on the phone (zip
CRCs, manifest board/SoC/indexes, sizes against the slots, MCUboot SHA-256, CV1 key hash); audio off
for the update; upload both images in single-write SMP requests; read the image state and require
both hashes; confirm both; reset; finished only when the reconnected pendant reports the version.
**Not verified on a real pendant:** the SMP exchange, confirm/reset behaviour of the multi-image
update, and whether downgrade prevention (equal `0.0.0+0` versions) allows reinstalling a release.

## Codec ids (`O(0002)` first byte)

| Id | Codec | Frame | v1 |
|---|---|---|---|
| 20 (`0x14`) | Opus, DevKit | 160 samples = 10 ms | supported |
| 21 (`0x15`) | Opus FS320, Omi CV1 | 320 samples = 20 ms | supported |
| 0, 1 | PCM16 / PCM8 (legacy; sources disagree on PCM8's rate) | — | **unsupported** |

Opus: 16 kHz mono, CELT restricted-lowdelay, ~32 kbps VBR (≈ 80 B/frame, ≤ 160 B), no DTX, no FEC,
raw packets (no Ogg). An unreadable or unknown codec id is an **unsupported device** state: the app
refuses to record rather than producing garbage (the Flutter app silently falls back to PCM8).

## Live audio notification framing

`omi/firmware/omi/src/lib/core/transport.c` `push_to_gatt()`:

```
[seq:u16 LE][fragment_index:u8][payload bytes…]
```

- `seq` increments for **every notification** (including fragments), wraps at 65536, and is **never
  reset on reconnect**. A dropped notification shows up as a seq gap. Frames the device drops from its
  full TX queue are dropped *before* getting a seq, so that loss is invisible.
- One encoded frame is split into fragments of `MTU` bytes (the firmware uses ATT MTU, not MTU − 3 — an
  off-by-3 bug); `fragment_index` starts at 0 per frame. With ATT MTU ≥ 166 (normal on iOS) every CV1
  frame is one notification with index 0. Below that, fragments may be dropped: the app logs
  `maximumWriteValueLength` and warns below 163.
- No length/end-of-frame field. A frame is complete when the next `fragment_index == 0` arrives. At a
  session end the pending frame is *probably* complete (almost always a single fragment) but not
  provably so; the decoder treats a decode failure there as a lost frame.
- Reassembly is server-side (`backend/src/omi_notes/device/ble_frames.py`): start at fragment 0; append
  while `seq` is contiguous (mod 65536) and the index increments; a duplicate seq is dropped; on a gap
  emit the pending frame (almost always complete; a decode failure counts as a lost frame) and then
  lost-frame markers (decoded with Opus PLC) for gaps ≤ 25, or a discontinuity for larger gaps; reset
  at every `SESSION_START` record.

## Offline storage (ring protocol, firmware ≥ 3.0.20)

The firmware records to flash **only while no phone is connected**. After reconnecting, the app
downloads the backlog while live audio keeps streaming.

Reference implementation: `app/lib/services/devices/ring_protocol.dart`,
`app/lib/services/wals/ring_storage_sync.dart`, firmware `omi/firmware/omi/src/lib/core/storage.c`.

**Detection — read before writing anything.** Multi-file firmware (3.0.17–3.0.19) reuses opcodes
`0x10/0x11/0x12`, and there `0x12` means DELETE. So:
1. The storage service and both characteristics exist.
2. Firmware revision (`2A26`) parses as ≥ 3.0.20 **and** features bit 6 is set (when the features
   characteristic exists).
3. Reading `30295782` returns **exactly 16 bytes** (8 bytes = legacy protocol → unsupported).
4. Only then write INFO, and require the INFO response shape below with `record_size == 444`.
Anything else → "offline sync unsupported on this firmware"; live capture still works.

Status read (`30295782`, 16 bytes, u32 **LE** ×4): `[used_bytes][unread_records][free_bytes][rtc_valid]`.

Commands written to `30295781` (multi-byte fields **BE**):

| Cmd | Bytes |
|---|---|
| INFO | `[0x10]` |
| READ | `[0x11][start_seq:u64][count:u32]` (count 0 = all) |
| ADVANCE | `[0x12][new_read_seq:u64]` |
| CLEAR | `[0x13]` — **never sent by this app** |
| STOP | `[0x03]` |

Notifications on `30295781` (first byte = opcode, multi-byte fields BE):

| Opcode | Layout |
|---|---|
| `0x01` ACK | `[0x01][status:u8]` |
| `0x02` INFO | `[0x02][read_seq:u64][write_seq:u64][capacity:u32][dropped:u64][record_size:u16]` (31 bytes) |
| `0x03` DATA | `[0x03][bytes…]` — raw record bytes, **not aligned** to record boundaries (≤ ATT MTU − 4 per notification) |
| `0x04` DONE | `[0x04][status:u8][next_seq:u64]` |
| `0x05` READ_BEGIN | `[0x05][start_seq:u64][count:u32]` |

Status codes: 0 OK, 6 invalid, 9 not ready (e.g. SD timeout), 10 sequence out of range. A failing
INFO or READ is answered with `ACK(status)` instead of INFO / READ_BEGIN — treat it as a failed sync
attempt (`sync_interrupted`, retry later). READ accepts 9 bytes (no count) or 13 bytes; we send 13
with count 0. The firmware already persists its read pointer at DONE, so ADVANCE is effectively a
confirmation, but we still send it (as Omi does) only after DONE status 0 and fsync.

Record (444 bytes): `[unix_ts:u32 BE][440 bytes: repeated [len:u8][opus frame] with zero padding]`.
Parse rule (`RingProtocol.parseAudioPayload`): a `0` length byte is padding (skip 1); stop when
`offset + 1 + len >= 440` — at a record boundary the firmware may leave a dangling length byte while
writing that frame into the next record (the whole overflowing frame is written into the next record; frames never span
records) — discard the dangling length byte and the stale tail. Every record keeps its own timestamp (the Omi app
uses only the first record's timestamp and offsets the rest by frame count, which compresses gaps).

Generation: the phone remembers, per device, the last INFO `write_seq` and its last persisted record
sequence. If INFO shows `write_seq` lower than before (storage reset/reflash), it increments a
per-device `generation` counter, resets its cursor, and reports the generation in ring seals.

Sync flow: INFO → READ(read_seq, 0) → reassemble DATA into 444-byte records → drop records with
seq ≤ last persisted seq → append to the ring journal and **fsync at least once per second** →
on DONE with status 0 (and everything fsync'd) send ADVANCE(next_seq) → seal the ring capture
`sync_complete`. On disconnect or error mid-sync: keep what is persisted, seal `sync_interrupted`,
resume next connection.

**Known limitation — firmware auto-advance.** The firmware checkpoints its read pointer every ~2 s
based on link-layer delivery (`storage.c` `sync_checkpoint_advance()`), before the app confirms
durable receipt. Delivered bytes are effectively gone from the device, so the exposure is the time
between receipt and fsync; the mitigation is fsync ≥ 1×/s (batch size doesn't matter). Any sequence
discontinuity is reported as a capture gap.
