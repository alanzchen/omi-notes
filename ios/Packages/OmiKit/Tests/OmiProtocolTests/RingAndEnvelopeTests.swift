import Foundation
import Testing
@testable import OmiProtocol

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func fromHex(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return d
}

/// A 444-byte record with the given timestamp and frames (zero padded).
func makeRecord(ts: UInt32, frames: [Data], tail: [UInt8] = []) -> Data {
    var d = RingProtocol.be(ts)
    for f in frames {
        d.append(UInt8(f.count))
        d.append(f)
    }
    d.append(contentsOf: tail)
    d.append(Data(count: 444 - d.count))
    return d
}

@Suite struct RingProtocolTests {
    @Test func statusSixteenBytesLittleEndian() {
        var d = Data()
        for v: UInt32 in [4440, 10, 123_456, 1] { d.append(withUnsafeBytes(of: v.littleEndian) { Data($0) }) }
        #expect(RingProtocol.parseStatus(d) == .ring(.init(usedBytes: 4440, unreadRecords: 10, freeBytes: 123_456, rtcValid: true)))
        #expect(RingProtocol.parseStatus(Data(count: 8)) == .legacy)
        #expect(RingProtocol.parseStatus(Data(count: 15)) == .invalid(length: 15))
        #expect(RingProtocol.parseStatus(Data(count: 20)) == .invalid(length: 20))
    }

    @Test func infoNotificationBigEndian() {
        var d = Data([0x02])
        d.append(RingProtocol.be(UInt64(1200)))
        d.append(RingProtocol.be(UInt64(1520)))
        d.append(RingProtocol.be(UInt32(60_000)))
        d.append(RingProtocol.be(UInt64(7)))
        d.append(RingProtocol.be(UInt16(444)))
        #expect(d.count == 31)
        let expected = RingProtocol.Info(readSeq: 1200, writeSeq: 1520, capacity: 60_000, dropped: 7, recordSize: 444)
        #expect(RingProtocol.parseNotification(d) == .info(expected))
        #expect(expected.unread == 320)
        #expect(RingProtocol.parseNotification(d.prefix(30)) == .malformed(opcode: 2, length: 30))
    }

    @Test func otherNotifications() {
        #expect(RingProtocol.parseNotification(Data([0x01, 0x0A])) == .ack(status: 10))
        var done = Data([0x04, 0x00])
        done.append(RingProtocol.be(UInt64(1520)))
        #expect(RingProtocol.parseNotification(done) == .done(.init(status: 0, nextSeq: 1520)))
        var rb = Data([0x05])
        rb.append(RingProtocol.be(UInt64(1200)))
        rb.append(RingProtocol.be(UInt32(320)))
        #expect(RingProtocol.parseNotification(rb) == .readBegin(.init(startSeq: 1200, count: 320)))
        #expect(RingProtocol.parseNotification(Data([0x03, 1, 2, 3])) == .data(Data([1, 2, 3])))
        #expect(RingProtocol.parseNotification(Data([0x7F])) == .malformed(opcode: 0x7F, length: 1))
        #expect(RingProtocol.parseNotification(Data()) == .malformed(opcode: nil, length: 0))
    }

    @Test func commandEncoding() {
        #expect(hex(RingProtocol.infoCommand()) == "10")
        #expect(hex(RingProtocol.readCommand(startSeq: 0x0102_0304_0506_0708, count: 0)) == "11" + "0102030405060708" + "00000000")
        #expect(RingProtocol.readCommand(startSeq: 1200).count == 13)
        #expect(hex(RingProtocol.advanceCommand(newReadSeq: 1520)) == "12" + "00000000000005f0")
        #expect(hex(RingProtocol.stopCommand()) == "03")
    }

    @Test func reassemblerHandlesUnalignedSplits() {
        let records = (0..<5).map { i in makeRecord(ts: 1_790_000_000 + UInt32(i), frames: [Data(repeating: UInt8(i + 1), count: 80)]) }
        let stream = records.reduce(Data(), +)
        // Several split patterns, including 1-byte and MTU-ish sizes that never align to 444.
        for sizes in [[1], [243], [240, 7, 100], [444], [443, 2], [1000]] {
            var r = RingRecordReassembler()
            var out: [Data] = []
            var off = 0, k = 0
            while off < stream.count {
                let n = min(sizes[k % sizes.count], stream.count - off)
                out += r.append(stream.subdata(in: off..<(off + n)))
                off += n
                k += 1
            }
            #expect(out == records, "split pattern \(sizes)")
            #expect(r.pendingBytes == 0)
        }
        var partial = RingRecordReassembler()
        #expect(partial.append(stream.prefix(500)).count == 1)
        #expect(partial.pendingBytes == 56)
    }

    @Test func audioPayloadParseWithPaddingAndDanglingLength() {
        let f1 = Data(repeating: 0xA1, count: 100), f2 = Data(repeating: 0xB2, count: 90)
        // Zero padding between frames is skipped.
        var payload = Data([UInt8(f1.count)]) + f1 + Data([0, 0]) + Data([UInt8(f2.count)]) + f2
        payload.append(Data(count: 440 - payload.count))
        #expect(RingProtocol.parseAudioPayload(payload) == [f1, f2])

        // Packing quirk: the firmware writes a length byte for a frame that does not fit, then the
        // frame goes to the next record; the bytes after the dangling length are stale.
        let big = Data(repeating: 0xC3, count: 150)
        var quirk = Data()
        for _ in 0..<2 { quirk.append(UInt8(big.count)); quirk.append(big) }  // 302 bytes
        let filler = Data(repeating: 0xD4, count: 130)
        quirk.append(UInt8(filler.count)); quirk.append(filler)  // 433 bytes
        quirk.append(160)  // dangling length byte at offset 433: 433 + 1 + 160 >= 440
        quirk.append(Data(repeating: 0xEE, count: 440 - quirk.count))  // stale tail
        #expect(RingProtocol.parseAudioPayload(quirk) == [big, big, filler])

        // `>=` boundary: a frame ending exactly at byte 439 is not taken (matches the firmware rule).
        var edge = Data([UInt8(200)]) + Data(repeating: 1, count: 200)
        edge.append(UInt8(238)); edge.append(Data(repeating: 2, count: 238))
        #expect(edge.count == 440)
        #expect(RingProtocol.parseAudioPayload(edge) == [Data(repeating: 1, count: 200)])
    }

    @Test func recordTimestamp() {
        let r = makeRecord(ts: 0x6A1B_2C3D, frames: [])
        #expect(RingProtocol.recordTimestamp(r) == 0x6A1B_2C3D)
    }
}

@Suite struct EnvelopeTests {
    @Test func goldenRecordBytes() {
        // Independently computed with Python: struct.pack('<IHB', 1000, 4, 1) + b'\x01\x00\x00\xaa' + crc32
        let r = BLERecord(tOffsetUs: 1000, flags: BLERecord.sessionStartFlag, bytes: Data([0x01, 0x00, 0x00, 0xAA]))
        #expect(hex(r.encoded()) == "e8030000040001010000aa3d68d65a")
    }

    @Test func scanStopsAtTornTailAndBadCRC() {
        let recs = (0..<4).map { BLERecord(tOffsetUs: UInt32($0 * 20_000), flags: $0 == 0 ? 1 : 0, bytes: Data(repeating: UInt8($0), count: 50)) }
        let all = recs.map { $0.encoded() }.reduce(Data(), +)
        #expect(BLERecord.scan(all).records == recs)
        let torn = all.prefix(all.count - 5)
        let s = BLERecord.scan(Data(torn))
        #expect(s.records.count == 3)
        #expect(s.validLength == 3 * (11 + 50))
        var corrupt = all
        corrupt[corrupt.startIndex + 61 + 20] ^= 0xFF  // flip a byte inside record 1
        #expect(BLERecord.scan(corrupt).records.count == 1)
    }

    func sampleHeader(payload: Data, count: Int) -> EnvelopeHeader {
        EnvelopeHeader(
            captureId: "0b8a1f5e-2c3d-4e5f-8a9b-0c1d2e3f4a5b", chunkSequence: 3, deviceId: "d1f0c2aa-0000-4000-8000-000000000001",
            deviceName: "Omi", modelNumber: "Omi CV 1", firmwareRevision: "3.0.21", hardwareRevision: nil, source: .liveBLE,
            payloadFormat: .bleNotificationsV1, codecId: 21, captureStartedAt: "2026-09-26T19:32:05.123Z",
            chunkStartOffsetUs: 180_000_000, chunkEndOffsetUs: 240_000_000, clockQuality: .phoneAnchored,
            timezone: "America/Chicago", recordCount: count, payloadBytes: payload.count, offlineStorage: true, ring: nil,
            appVersion: "0.1.0 (1)")
    }

    @Test func envelopeStructure() throws {
        let payload = [BLERecord(tOffsetUs: 0, flags: 1, bytes: Data([0, 0, 0, 1])), BLERecord(tOffsetUs: 20_000, flags: 0, bytes: Data([1, 0, 0, 2]))]
            .map { $0.encoded() }.reduce(Data(), +)
        let header = sampleHeader(payload: payload, count: 2)
        let body = try Envelope.build(header: header, payload: payload)
        #expect(body.prefix(8) == Data("OMINOTE1".utf8))
        let hlen = Int(body[8]) | Int(body[9]) << 8 | Int(body[10]) << 16 | Int(body[11]) << 24
        #expect(body.count == 12 + hlen + payload.count)
        #expect(body.suffix(payload.count) == payload)
        let json = String(decoding: body[12..<(12 + hlen)], as: UTF8.self)
        // Deterministic: sorted keys, nulls explicit, no `ring` for live chunks, no escaped slashes.
        #expect(json == #"{"app_version":"0.1.0 (1)","capture_id":"0b8a1f5e-2c3d-4e5f-8a9b-0c1d2e3f4a5b","capture_started_at":"2026-09-26T19:32:05.123Z","channels":1,"chunk_end_offset_us":240000000,"chunk_sequence":3,"chunk_start_offset_us":180000000,"clock_quality":"phone_anchored","codec_id":21,"device_id":"d1f0c2aa-0000-4000-8000-000000000001","device_name":"Omi","firmware_revision":"3.0.21","hardware_revision":null,"model_number":"Omi CV 1","offline_storage":true,"payload_bytes":30,"payload_format":"ble_notifications_v1","record_count":2,"sample_rate":16000,"schema_version":1,"source":"live_ble","timezone":"America/Chicago"}"#)
        let parsed = try Envelope.parse(body)
        #expect(parsed.header == header)
        #expect(parsed.payload == payload)
    }

    @Test func ringHeaderCarriesRingObject() throws {
        let payload = makeRecord(ts: 1, frames: []) + makeRecord(ts: 2, frames: [])
        var h = sampleHeader(payload: payload, count: 2)
        h.source = .deviceRing
        h.payloadFormat = .ringRecordsV1
        h.clockQuality = .deviceSeconds
        h.offlineStorage = nil
        h.ring = RingChunkInfo(firstSequence: 1200, readSeq: 1200, writeSeq: 1520, dropped: 0)
        let body = try Envelope.build(header: h, payload: payload)
        let hlen = Int(body[8]) | Int(body[9]) << 8
        let json = String(decoding: body[12..<(12 + hlen)], as: UTF8.self)
        #expect(json.contains(#""ring":{"dropped":0,"first_sequence":1200,"read_seq":1200,"record_size":444,"write_seq":1520}"#))
        #expect(json.contains(#""offline_storage":null"#))
        #expect(try Envelope.parse(body).header.ring?.firstSequence == 1200)
    }

    @Test func parseRejectsBadInput() throws {
        #expect(throws: EnvelopeError.badMagic) { try Envelope.parse(Data("NOTANENV0000".utf8)) }
        let payload = BLERecord(tOffsetUs: 0, flags: 1, bytes: Data([0, 0, 0])).encoded()
        let body = try Envelope.build(header: sampleHeader(payload: payload, count: 1), payload: payload)
        #expect(throws: EnvelopeError.self) { try Envelope.parse(body.dropLast()) }
        let wrongCount = try Envelope.build(header: sampleHeader(payload: payload, count: 2), payload: payload)
        #expect(throws: EnvelopeError.recordCountMismatch(expected: 2, actual: 1)) { try Envelope.parse(wrongCount) }
    }

    @Test func sealAndEventJSON() throws {
        let seal = SealBody(
            lastChunkSequence: -1, reason: .syncComplete, endedAt: "2026-09-26T19:42:00.000Z", endOffsetUs: 41_000_000,
            deviceId: "dev", source: .deviceRing,
            ring: RingSealEvidence(generation: 1, infoReadSeq: 1200, infoWriteSeq: 1200, doneNextSeq: nil, dropped: 0, rtcValid: true, coversUntil: "2026-09-26T19:40:02.000Z"))
        let json = String(decoding: try ContractJSON.encode(seal), as: UTF8.self)
        #expect(json == #"{"device_id":"dev","end_offset_us":41000000,"ended_at":"2026-09-26T19:42:00.000Z","last_chunk_sequence":-1,"reason":"sync_complete","ring":{"covers_until":"2026-09-26T19:40:02.000Z","done_next_seq":null,"dropped":0,"generation":1,"info_read_seq":1200,"info_write_seq":1200,"rtc_valid":true},"source":"device_ring"}"#)

        let button = EventBody(deviceId: "dev", at: "2026-09-26T19:40:00.000Z", payload: .button(ButtonData(code: 2)), captureId: "cap", offsetUs: 5_000_000)
        #expect(String(decoding: try ContractJSON.encode(button), as: UTF8.self) == #"{"at":"2026-09-26T19:40:00.000Z","capture_id":"cap","data":{"code":2},"device_id":"dev","offset_us":5000000,"type":"button"}"#)

        let hb = EventBody(deviceId: "dev", at: "2026-09-26T19:40:00.000Z", payload: .heartbeat(HeartbeatData(battery: 83, charging: false, appState: "background", coverage: CoverageWatermark(captureId: "cap", throughOffsetUs: 734_000_000, throughChunkSequence: 11))))
        let hbJSON = String(decoding: try ContractJSON.encode(hb), as: UTF8.self)
        #expect(hbJSON == #"{"at":"2026-09-26T19:40:00.000Z","data":{"app_state":"background","battery":83,"charging":false,"coverage":{"capture_id":"cap","through_chunk_sequence":11,"through_offset_us":734000000}},"device_id":"dev","type":"heartbeat"}"#)
    }
}

/// Backend is type-strict for seals and events: timestamps are ISO-8601 strings, every number is a
/// JSON integer (never a string or float), and ring sync_complete seals carry covers_until + info_read_seq.
@Suite struct ContractJSONTypeTests {
    func isInteger(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return !CFNumberIsFloatType(n)
    }

    func isISO(_ v: Any?) -> Bool {
        guard let s = v as? String else { return false }
        return ISO8601UTC.parse(s) != nil && s.hasSuffix("Z")
    }

    @Test func sealFieldTypes() throws {
        let seal = SealBody(
            lastChunkSequence: 3, reason: .syncComplete, endedAt: ISO8601UTC.format(Date(timeIntervalSince1970: 1_790_451_125.5)),
            endOffsetUs: 41_000_000_123, deviceId: "dev", source: .deviceRing,
            ring: RingSealEvidence(generation: 2, infoReadSeq: 1200, infoWriteSeq: 1520, doneNextSeq: 1520, dropped: 0, rtcValid: true,
                                   coversUntil: ISO8601UTC.format(Date(timeIntervalSince1970: 1_790_451_000))))
        let o = try #require(try JSONSerialization.jsonObject(with: ContractJSON.encode(seal)) as? [String: Any])
        #expect(isInteger(o["last_chunk_sequence"]))
        #expect(isInteger(o["end_offset_us"]))
        #expect(isISO(o["ended_at"]))
        #expect(o["reason"] as? String == "sync_complete")
        let ring = try #require(o["ring"] as? [String: Any])
        for k in ["generation", "info_read_seq", "info_write_seq", "done_next_seq", "dropped"] { #expect(isInteger(ring[k]), "\(k)") }
        #expect(isISO(ring["covers_until"]))
        #expect(ring["rtc_valid"] as? Bool == true)
        let empty = SealBody(lastChunkSequence: -1, reason: .bleDisconnected, endedAt: ISO8601UTC.format(Date()), endOffsetUs: 0, deviceId: "d", source: .liveBLE)
        let e = try #require(try JSONSerialization.jsonObject(with: ContractJSON.encode(empty)) as? [String: Any])
        #expect(isInteger(e["last_chunk_sequence"]) && (e["last_chunk_sequence"] as? Int) == -1)
        #expect(e["ring"] == nil)
    }

    @Test func eventFieldTypes() throws {
        let button = EventBody(deviceId: "d", at: ISO8601UTC.format(Date()), payload: .button(ButtonData(code: 2)), captureId: "c", offsetUs: 5_000_001)
        let b = try #require(try JSONSerialization.jsonObject(with: ContractJSON.encode(button)) as? [String: Any])
        #expect(isISO(b["at"]))
        #expect(isInteger(b["offset_us"]))
        #expect(isInteger((b["data"] as? [String: Any])?["code"]))
        let hb = EventBody(deviceId: "d", at: ISO8601UTC.format(Date()), payload: .heartbeat(HeartbeatData(
            battery: 83, charging: false, rtcValid: true, offlineUnread: 7, outboxChunks: 3, outboxBytes: 812_345,
            appState: "background", coverage: CoverageWatermark(captureId: "c", throughOffsetUs: 734_000_000, throughChunkSequence: 11))))
        let h = try #require(try JSONSerialization.jsonObject(with: ContractJSON.encode(hb)) as? [String: Any])
        let data = try #require(h["data"] as? [String: Any])
        for k in ["battery", "offline_unread", "outbox_chunks", "outbox_bytes"] { #expect(isInteger(data[k]), "\(k)") }
        let cov = try #require(data["coverage"] as? [String: Any])
        #expect(isInteger(cov["through_offset_us"]) && isInteger(cov["through_chunk_sequence"]))
    }
}
