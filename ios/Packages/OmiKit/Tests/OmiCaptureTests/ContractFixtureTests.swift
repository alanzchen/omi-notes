import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

/// Writes deterministic contract fixtures to `contracts/fixtures/swift/` through the real capture
/// code paths (journal → rotation → envelope; ring writer → envelope + seal). The backend parses
/// them in its own test suite. Re-running produces byte-identical files.
@Suite(.serialized) struct ContractFixtureTests {
    static let fixturesDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // OmiCaptureTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // OmiKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("contracts/fixtures/swift", isDirectory: true)

    static let deviceId = "8d3b5f2e-1a4c-4e6f-9b7d-2c1e0f3a4b5c"
    static let liveCaptureId = "3f2c9a61-7b4e-4d8a-9c1f-5e6d7a8b9c0d"
    static let enrollmentId = "6a0e4c2d-9f1b-4e3a-8c7d-5b2f1e0a9d8c"
    static let ringCaptureId = "a7e41c3b-2d5f-4a69-8b0e-1f2c3d4e5f60"
    static let startWall = Date(timeIntervalSince1970: 1_790_451_125.123)  // 2026-09-26T19:32:05.123Z

    struct LiveNotification: Encodable {
        let t_offset_us: UInt32
        let flags: UInt8
        let seq: UInt16
        let fragment_index: UInt8
        let length: Int
        let payload_length: Int
        let payload_sha256: String
    }

    struct RingRecordExpectation: Encodable {
        let sequence: UInt64
        let unix_ts: UInt32
        let frame_lengths: [Int]
        let note: String
    }

    func env(_ id: String, root: URL) -> TestEnv {
        let fixed = UUID(uuidString: id)!
        return TestEnv(
            clock: FakeClock(wall: Self.startWall, mono: 9_000_000_000_000), root: root, appVersion: "0.1.0 (1)",
            timezone: "America/Chicago", idGenerator: { fixed })
    }

    @Test func writeLiveAndRingFixtures() throws {
        let packets = loadOpusPackets()
        try #require(packets.count >= 64, "opus_packets.bin resource missing")
        try FileManager.default.createDirectory(at: Self.fixturesDir, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("omikit-fixtures-\(UUID().uuidString)")

        // MARK: live_ble_sample.omnc
        let live = env(Self.liveCaptureId, root: scratch.appendingPathComponent("live"))
        let recorder = LiveCaptureRecorder(env: live.env)
        try recorder.begin(meta: CaptureDeviceMeta(
            deviceId: Self.deviceId, deviceName: "Omi", modelNumber: "Omi CV 1", firmwareRevision: "3.0.21",
            hardwareRevision: "5.0", codec: .opus20ms, offlineStorage: true))
        var seq: UInt16 = 65_520
        var nowUs: Int64 = 0
        var sent: [(t: Int64, bytes: Data)] = []
        let jitter: [Int64] = [0, 3_000, 1_000, 4_000, 2_000]
        for f in 0..<40 {
            let pkt = packets[f]
            if [10, 11, 12].contains(f) { seq &+= 1; continue }  // lost over the air: seq gap of 3
            let target = Int64(f) * 20_000 + jitter[f % 5] + 150_000
            var pieces: [(UInt8, Data)] = [(0, pkt)]
            if f == 20 {  // one frame fragmented (low-MTU case): idx 0 then idx 1, consecutive seqs
                let half = pkt.count / 2
                pieces = [(0, pkt.prefix(half)), (1, pkt.suffix(from: pkt.startIndex + half))]
            }
            for (k, piece) in pieces.enumerated() {
                let t = target + Int64(k) * 500
                live.clock.advance(Double(t - nowUs) / 1_000_000)
                nowUs = t
                var n = Data([UInt8(seq & 0xFF), UInt8(seq >> 8), piece.0])
                n.append(piece.1)
                #expect(recorder.append(n))
                sent.append((t, n))
                seq &+= 1
            }
        }
        live.clock.advance(0.5)
        let liveSeal = try #require(recorder.finish(reason: .bleDisconnected))
        let liveChunks = live.pendingChunks()
        try #require(liveChunks.count == 1)
        let liveBody = try Data(contentsOf: liveChunks[0].0.url)
        let parsed = try Envelope.parse(liveBody)
        let records = BLERecord.scan(parsed.payload).records
        #expect(records.count == sent.count)
        #expect(records.map(\.bytes) == sent.map(\.bytes))
        #expect(records.first?.isSessionStart == true)
        #expect(records.dropFirst().allSatisfy { !$0.isSessionStart })

        // MARK: ring_sample.omnc
        let ring = env(Self.ringCaptureId, root: scratch.appendingPathComponent("ring"))
        ring.clock.advance(12)
        let (ringRecords, expectations) = Self.buildRingRecords(packets: Array(packets[40...]))
        let writer = RingCaptureWriter(env: ring.env)
        let info = RingProtocol.Info(readSeq: 1200, writeSeq: 1203, capacity: 60_000, dropped: 0, recordSize: 444)
        try writer.begin(.init(
            meta: CaptureDeviceMeta(deviceId: Self.deviceId, deviceName: "Omi", modelNumber: "Omi CV 1", firmwareRevision: "3.0.21", hardwareRevision: "5.0"),
            codecId: 21, info: info, generation: 1, rtcValid: true, coversUntil: Self.startWall))
        for (i, r) in ringRecords.enumerated() {
            ring.clock.advance(0.04)
            try writer.append(seq: 1200 + UInt64(i), record: r)
        }
        ring.clock.advance(0.2)
        let ringSeal = try #require(try writer.finish(reason: .syncComplete, doneNextSeq: 1203))
        let ringBody = try Data(contentsOf: try #require(ring.pendingChunks().first).0.url)
        let ringParsed = try Envelope.parse(ringBody)
        #expect(ringParsed.header.recordCount == 3)
        for (i, e) in expectations.enumerated() {
            let rec = ringParsed.payload.subdata(in: (i * 444)..<((i + 1) * 444))
            #expect(RingProtocol.recordTimestamp(rec) == e.unix_ts)
            #expect(RingProtocol.parseAudioPayload(rec.dropFirst(4)).map(\.count) == e.frame_lengths)
        }

        // MARK: write files
        let out = Self.fixturesDir
        try liveBody.write(to: out.appendingPathComponent("live_ble_sample.omnc"))
        try ringBody.write(to: out.appendingPathComponent("ring_sample.omnc"))
        try Self.prettyJSON(liveSeal).write(to: out.appendingPathComponent("live_ble_sample.seal.json"))
        try Self.prettyJSON(ringSeal).write(to: out.appendingPathComponent("ring_sample.seal.json"))

        let liveExpected = records.map { r -> LiveNotification in
            let h = AudioPacketHeader(r.bytes)!
            return LiveNotification(
                t_offset_us: r.tOffsetUs, flags: r.flags, seq: h.sequence, fragment_index: h.fragmentIndex,
                length: r.bytes.count, payload_length: h.payloadLength, payload_sha256: Uploader.sha256Hex(r.bytes.dropFirst(3)))
        }
        try Self.prettyJSON(Expected(
            file: "live_ble_sample.omnc", sha256: Uploader.sha256Hex(liveBody), header: parsed.header,
            notifications: liveExpected, ring_records: nil)).write(to: out.appendingPathComponent("live_ble_sample.expected.json"))
        try Self.prettyJSON(Expected(
            file: "ring_sample.omnc", sha256: Uploader.sha256Hex(ringBody), header: ringParsed.header,
            notifications: nil, ring_records: expectations)).write(to: out.appendingPathComponent("ring_sample.expected.json"))

        // Button + heartbeat event examples.
        let button = EventBody(deviceId: Self.deviceId, at: "2026-09-26T19:32:06.000Z", payload: .button(ButtonData(code: 2)), captureId: Self.liveCaptureId, offsetUs: 877_000)
        try Self.prettyJSON(button).write(to: out.appendingPathComponent("event_button.json"))
        let hb = EventBody(deviceId: Self.deviceId, at: "2026-09-26T19:32:06.000Z", payload: .heartbeat(HeartbeatData(
            battery: 83, charging: false, firmwareRevision: "3.0.21", modelNumber: "Omi CV 1", rtcValid: true, offlineUnread: 0,
            outboxChunks: 1, outboxBytes: Int64(liveBody.count), appState: "background",
            coverage: CoverageWatermark(captureId: Self.liveCaptureId, throughOffsetUs: parsed.header.chunkEndOffsetUs, throughChunkSequence: 0))))
        try Self.prettyJSON(hb).write(to: out.appendingPathComponent("event_heartbeat.json"))

        // A voice enrollment window over the live sample (docs/speaker-learning.md, "Enrollment").
        let enrollStart = EventBody(deviceId: Self.deviceId, at: "2026-09-26T19:32:05.200Z",
            payload: .voiceEnrollmentStart(VoiceEnrollmentStartData(enrollmentId: Self.enrollmentId)),
            captureId: Self.liveCaptureId, offsetUs: 100_000)
        try Self.prettyJSON(enrollStart).write(to: out.appendingPathComponent("event_voice_enrollment_start.json"))
        let enrollEnd = EventBody(deviceId: Self.deviceId, at: "2026-09-26T19:32:06.000Z",
            payload: .voiceEnrollmentEnd(VoiceEnrollmentEndData(enrollmentId: Self.enrollmentId,
                                                                endOffsetUs: parsed.header.chunkEndOffsetUs, outcome: .completed)),
            captureId: Self.liveCaptureId, offsetUs: parsed.header.chunkEndOffsetUs)
        try Self.prettyJSON(enrollEnd).write(to: out.appendingPathComponent("event_voice_enrollment_end.json"))

        try Self.readme(live: parsed.header, liveRecords: records, liveSeal: liveSeal, ring: ringParsed.header, ringExpect: expectations, ringSeal: ringSeal)
            .write(to: out.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: scratch)
    }

    struct Expected: Encodable {
        let file: String
        let sha256: String
        let header: EnvelopeHeader
        let notifications: [LiveNotification]?
        let ring_records: [RingRecordExpectation]?
    }

    /// Three firmware-shaped records: normal packing with zero padding; the dangling-length-byte
    /// quirk with a stale tail; the overflowed frame continuing in the next record.
    static func buildRingRecords(packets: [Data]) -> ([Data], [RingRecordExpectation]) {
        let ts0: UInt32 = 1_790_450_400  // 2026-09-26T19:20:00Z (device RTC, recorded while disconnected)
        var records: [Data] = []
        var expect: [RingRecordExpectation] = []
        var p = 0

        // Record 0: three frames, then zero padding.
        var payload = Data()
        var lens: [Int] = []
        while lens.count < 3, payload.count + 1 + packets[p].count < 440 {
            payload.append(UInt8(packets[p].count)); payload.append(packets[p]); lens.append(packets[p].count); p += 1
        }
        records.append(RingProtocol.be(ts0) + payload + Data(count: 440 - payload.count))
        expect.append(.init(sequence: 1200, unix_ts: ts0, frame_lengths: lens, note: "frames then zero padding"))

        // Record 1: fill until the next frame does not fit, write its length byte anyway (dangling),
        // leave stale bytes after it.
        payload = Data()
        lens = []
        while payload.count + 1 + packets[p].count < 440 {
            payload.append(UInt8(packets[p].count)); payload.append(packets[p]); lens.append(packets[p].count); p += 1
        }
        payload.append(UInt8(packets[p].count))  // dangling: this frame goes to the next record
        payload.append(Data(repeating: 0xEE, count: 440 - payload.count))
        records.append(RingProtocol.be(ts0 + 1) + payload)
        expect.append(.init(sequence: 1201, unix_ts: ts0 + 1, frame_lengths: lens, note: "dangling length byte for a \(packets[p].count)-byte frame, stale 0xEE tail"))

        // Record 2: the overflowed frame and up to two more, zero padding. Same RTC second as record 1.
        payload = Data()
        lens = []
        while lens.count < 3, payload.count + 1 + packets[p].count < 440 {
            payload.append(UInt8(packets[p].count)); payload.append(packets[p]); lens.append(packets[p].count); p += 1
        }
        records.append(RingProtocol.be(ts0 + 1) + payload + Data(count: 440 - payload.count))
        expect.append(.init(sequence: 1202, unix_ts: ts0 + 1, frame_lengths: lens, note: "starts with the frame that overflowed record 1201"))
        return (records, expect)
    }

    static func prettyJSON<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var d = try e.encode(v)
        d.append(0x0A)
        return d
    }

    static func readme(live: EnvelopeHeader, liveRecords: [BLERecord], liveSeal: SealBody, ring: EnvelopeHeader, ringExpect: [RingRecordExpectation], ringSeal: SealBody) -> String {
        let seqs = liveRecords.map { AudioPacketHeader($0.bytes)!.sequence }
        return """
        # Swift contract fixtures

        Generated by `ios/Packages/OmiKit/Tests/OmiCaptureTests/ContractFixtureTests.swift`
        (`cd ios/Packages/OmiKit && swift test`), through the app's real capture code paths
        (journal → rotation → envelope, ring writer → envelope + seal). Output is deterministic:
        re-running the tests rewrites byte-identical files. Do not edit by hand.

        Opus payloads are **real** Opus packets (CELT-only, wideband, 20 ms, TOC config 23 — the
        CV1 encoder's mode) produced from macOS `say` speech with ffmpeg/libopus
        (`-application lowdelay -b:a 32k -vbr on -frame_duration 20 -ar 16000 -ac 1`). They decode
        with a 16 kHz mono libopus decoder.

        ## `live_ble_sample.omnc` (`source: live_ble`, `payload_format: ble_notifications_v1`)

        - `capture_id` `\(live.captureId)`, `chunk_sequence` \(live.chunkSequence), `device_id` `\(live.deviceId)`,
          `codec_id` \(live.codecId), `capture_started_at` `\(live.captureStartedAt)`.
        - Chunk covers `\(live.chunkStartOffsetUs)`…`\(live.chunkEndOffsetUs)` µs; `record_count` \(live.recordCount),
          `payload_bytes` \(live.payloadBytes).
        - \(liveRecords.count) notifications `[seq u16 LE][fragment_index][opus]`, seq \(seqs.first!)…\(seqs.last!):
          - record 0 has `flags = 1` (SESSION_START); all others 0;
          - seq **wraps** 65535 → 0;
          - seq **gap**: 65530, 65531, 65532 are missing (3 notifications lost over the air);
          - one frame is **fragmented** into two notifications (seq 4 `fragment_index` 0, seq 5
            `fragment_index` 1) — reassemble to one Opus packet; every other notification is one
            complete frame (`fragment_index` 0);
          - `t_offset_us` is phone receive time relative to the chunk start (first record at 150 000 µs,
            ~20 ms apart with jitter; the fragment pair is 500 µs apart).
        - `live_ble_sample.expected.json`: header plus per-record `t_offset_us`, `flags`, `seq`,
          `fragment_index`, `length`, and SHA-256 of the Opus bytes (after the 3-byte header).
        - `live_ble_sample.seal.json`: the matching seal (`\(liveSeal.reason.rawValue)`, `last_chunk_sequence`
          \(liveSeal.lastChunkSequence), `end_offset_us` \(liveSeal.endOffsetUs)).

        ## `ring_sample.omnc` (`source: device_ring`, `payload_format: ring_records_v1`)

        - `capture_id` `\(ring.captureId)`, `clock_quality` `\(ring.clockQuality.rawValue)`, `ring.first_sequence`
          \(ring.ring!.firstSequence), `read_seq` \(ring.ring!.readSeq), `write_seq` \(ring.ring!.writeSeq), 3 records × 444 bytes.
        \(ringExpect.map { "- seq \($0.sequence), `unix_ts` \($0.unix_ts): frames \($0.frame_lengths) — \($0.note)" }.joined(separator: "\n"))
        - The parse rule `offset + 1 + len >= 440 → stop` yields exactly the frame lengths above; the
          dangling length byte and the stale `0xEE` tail in record 1201 must be ignored.
        - `ring_sample.expected.json`: header plus per-record timestamps and frame lengths.
        - `ring_sample.seal.json`: `sync_complete` with ring evidence (`generation` \(ringSeal.ring!.generation),
          `done_next_seq` \(ringSeal.ring!.doneNextSeq!), `covers_until` `\(ringSeal.ring!.coversUntil)`).

        ## Events

        - `event_button.json` — double tap (`code` 2) with `capture_id` + `offset_us`.
        - `event_heartbeat.json` — heartbeat with a coverage watermark through the end of the (rotated)
          chunk 0 of the live sample.
        - `event_voice_enrollment_start.json` / `event_voice_enrollment_end.json` — one enrollment window
          (`enrollment_id` \(Self.enrollmentId)) over the live sample, ending `completed`.

        """
    }
}
