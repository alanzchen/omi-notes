# Python-built capture envelopes

Reference `OMINOTE1` chunk bodies produced by the backend's dev tooling
(`backend/src/omi_notes/devtools.py`), regenerated deterministically with:

```sh
cd backend && uv run python scripts/make_contract_fixtures.py
```

| File | What it exercises |
|---|---|
| `live_ble_opus21.omnc` | `live_ble` / `ble_notifications_v1`, codec 21. Firmware-like Opus (restricted-lowdelay, 32 kbps VBR, complexity 3) in 320-sample frames, raw `[seq u16 LE][idx][opus]` notifications, `SESSION_START` on the first record, sequence numbers wrapping 65535 → 0, ~2 % of notifications dropped (PLC), and a > 10 s quiet stretch where the mic sleeps (no notifications), so the server starts a second timeline run. |
| `device_ring.omnc` | `device_ring` / `ring_records_v1`: 444-byte records `[unix_ts u32 BE][440 bytes of [len][opus]…]` including the firmware's dangling-length-byte boundary quirk, `ring.first_sequence = 1200`, device timestamps one hour before `capture_started_at`. |
| `wav_replay_pcm.omnc` | `wav_replay` / `pcm16le_v1`: one second of raw PCM. |

`manifest.json` lists each file's SHA-256, record count and the pieces the server's timeline
decodes it into (start offset relative to `capture_started_at`, sample count). The backend test
`tests/test_contract_fixtures.py` checks these, and also parses and decodes every
`contracts/fixtures/swift/*.omnc` produced by the iOS package when that directory exists.
