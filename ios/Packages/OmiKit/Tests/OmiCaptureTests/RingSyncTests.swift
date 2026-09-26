import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

final class FakeRingTransport: RingTransport {
    var statusReads = 0
    var notifyEnables = 0
    var writes: [Data] = []
    var onWrite: ((Data) -> Void)?
    func ringReadStatus() { statusReads += 1 }
    func ringEnableNotifications() { notifyEnables += 1 }
    func ringWrite(_ command: Data) {
        writes.append(command)
        onWrite?(command)
    }
}

enum RingWire {
    static func status(unread: UInt32, rtc: Bool = true) -> Data {
        var d = Data()
        for v: UInt32 in [unread * 444, unread, 1_000_000, rtc ? 1 : 0] { d.append(withUnsafeBytes(of: v.littleEndian) { Data($0) }) }
        return d
    }
    static func info(read: UInt64, write: UInt64, dropped: UInt64 = 0, size: UInt16 = 444) -> Data {
        var d = Data([0x02])
        d.append(RingProtocol.be(read)); d.append(RingProtocol.be(write)); d.append(RingProtocol.be(UInt32(10_000)))
        d.append(RingProtocol.be(dropped)); d.append(RingProtocol.be(size))
        return d
    }
    static func readBegin(_ start: UInt64, _ count: UInt32) -> Data {
        var d = Data([0x05]); d.append(RingProtocol.be(start)); d.append(RingProtocol.be(count)); return d
    }
    static func done(_ status: UInt8, _ next: UInt64) -> Data {
        var d = Data([0x04, status]); d.append(RingProtocol.be(next)); return d
    }
    /// DATA notifications of `chunk` bytes (not aligned to 444).
    static func data(_ records: [Data], chunk: Int = 243) -> [Data] {
        let stream = records.reduce(Data(), +)
        var out: [Data] = []
        var off = 0
        while off < stream.count {
            let n = min(chunk, stream.count - off)
            out.append(Data([0x03]) + stream.subdata(in: off..<(off + n)))
            off += n
        }
        return out
    }
}

final class RingHarness {
    let t: TestEnv
    let transport = FakeRingTransport()
    let cursors: RingCursorStore
    let engine: RingSyncEngine
    let reconnectedAt: Date

    init(t: TestEnv = TestEnv(), recordsPerChunk: Int = 600) {
        self.t = t
        cursors = RingCursorStore(stateDir: t.dirs.state)
        engine = RingSyncEngine(writer: RingCaptureWriter(env: t.env, recordsPerChunk: recordsPerChunk), cursors: cursors)
        engine.transport = transport
        reconnectedAt = t.clock.wallNow()
    }

    func context(fw: String = "3.0.21", features: UInt32? = 0x1EC, storage: Bool = true) -> RingSyncContext {
        RingSyncContext(
            meta: CaptureDeviceMeta(deviceId: "dev-1", deviceName: "Omi", modelNumber: "Omi CV 1", firmwareRevision: fw, codec: .opus20ms),
            codecId: 21, hasStorageService: storage, hasFeaturesCharacteristic: features != nil,
            features: features.map(DeviceFeatures.init(rawValue:)), reconnectedAt: reconnectedAt)
    }

    /// Runs detection up to the INFO request.
    func startThroughInfoRequest(unread: UInt32) {
        engine.start(context())
        engine.handleStatusRead(RingWire.status(unread: unread), error: nil)
        engine.handleNotificationsEnabled(error: nil)
    }

    func feed(_ notifications: [Data]) { notifications.forEach(engine.handleNotification) }

    func seals() -> [SealBody] {
        t.outbox.pending().filter { if case .seal = $0.kind { return true } else { return false } }
            .compactMap { try? JSONDecoder().decode(SealBody.self, from: Data(contentsOf: $0.url)) }
    }
}

@Suite struct RingSyncEngineTests {
    @Test func happyPath() throws {
        let h = RingHarness()
        h.engine.start(h.context())
        #expect(h.transport.statusReads == 1)
        #expect(h.transport.writes.isEmpty)  // nothing written before the status read
        h.engine.handleStatusRead(RingWire.status(unread: 5), error: nil)
        #expect(h.transport.notifyEnables == 1)
        #expect(h.transport.writes.isEmpty)
        h.engine.handleNotificationsEnabled(error: nil)
        #expect(h.transport.writes == [RingProtocol.infoCommand()])
        h.feed([RingWire.info(read: 100, write: 105, dropped: 2)])
        #expect(h.transport.writes.last == RingProtocol.readCommand(startSeq: 100, count: 0))
        h.feed([RingWire.readBegin(100, 5)])
        let records = (100..<105).map { ringRecord(seq: UInt64($0)) }
        h.feed(RingWire.data(records))
        #expect(h.engine.state == .receiving(received: 5, total: 5))
        h.feed([RingWire.done(0, 105)])
        #expect(h.transport.writes.last == RingProtocol.advanceCommand(newReadSeq: 105))
        #expect(h.engine.state == .complete(records: 5))

        let chunks = h.t.pendingChunks()
        try #require(chunks.count == 1)
        let (_, header, payload) = chunks[0]
        #expect(header.source == .deviceRing)
        #expect(header.payloadFormat == .ringRecordsV1)
        #expect(header.clockQuality == .deviceSeconds)
        #expect(header.ring == RingChunkInfo(firstSequence: 100, readSeq: 100, writeSeq: 105, dropped: 2))
        #expect(header.recordCount == 5)
        #expect(payload == records.reduce(Data(), +))
        let seal = try #require(h.seals().first)
        #expect(seal.reason == .syncComplete)
        #expect(seal.source == .deviceRing)
        #expect(seal.lastChunkSequence == 0)
        #expect(seal.deviceId == "dev-1")
        #expect(seal.ring == RingSealEvidence(generation: 1, infoReadSeq: 100, infoWriteSeq: 105, doneNextSeq: 105, dropped: 2, rtcValid: true, coversUntil: ISO8601UTC.format(h.reconnectedAt)))
        #expect(h.cursors.load("dev-1").lastPersistedSeq == 104)
        #expect(FileIO.contents(of: h.t.dirs.journalRing).isEmpty)
    }

    @Test func disconnectMidReadThenResumeWithDedupe() throws {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 10)
        h.feed([RingWire.info(read: 100, write: 110), RingWire.readBegin(100, 10)])
        let all = (100..<110).map { ringRecord(seq: UInt64($0)) }
        let stream = RingWire.data(all, chunk: 240)
        let firstHalf = Array(stream.prefix(12))  // 12 × 240 = 2880 B = 6 records + 216 B partial
        h.feed(Array(firstHalf.prefix(6)))
        h.t.clock.advance(1.1)
        h.feed(Array(firstHalf.dropFirst(6)))  // fsync + cursor save happen here (≥ 1 s)
        h.engine.handleDisconnect()
        #expect(h.engine.state == .interrupted("disconnected"))
        var seal = try #require(h.seals().first)
        #expect(seal.reason == .syncInterrupted)
        #expect(seal.ring?.doneNextSeq == nil)
        #expect(seal.lastChunkSequence == 0)
        #expect(h.t.pendingChunks().first?.1.recordCount == 6)
        #expect(h.cursors.load("dev-1").lastPersistedSeq == 105)
        #expect(!h.transport.writes.contains(RingProtocol.advanceCommand(newReadSeq: 110)))

        let firstCapture = try #require(h.t.pendingChunks().first?.1.captureId)
        // Reconnect: the firmware's checkpoint lags, so it resends 103…105.
        let h2 = RingHarness(t: h.t)
        h2.startThroughInfoRequest(unread: 7)
        h2.feed([RingWire.info(read: 103, write: 110)])
        #expect(h2.transport.writes.last == RingProtocol.readCommand(startSeq: 103))
        h2.feed([RingWire.readBegin(103, 7)])
        h2.feed(RingWire.data(Array(all[3...])))
        h2.feed([RingWire.done(0, 110)])
        #expect(h2.engine.state == .complete(records: 4))
        #expect(h2.engine.duplicatesDropped == 3)
        let resumed = h2.t.pendingChunks().filter { $0.1.captureId != firstCapture }
        try #require(resumed.count == 1)
        #expect(resumed[0].1.ring?.firstSequence == 106)
        #expect(resumed[0].2 == all[6...].reduce(Data(), +))
        seal = try #require(h2.seals().first { $0.reason == .syncComplete })
        #expect(seal.ring?.doneNextSeq == 110)
        #expect(h2.cursors.load("dev-1").lastPersistedSeq == 109)
    }

    @Test func unreadZeroGivesEmptySyncCompleteSeal() throws {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 0)
        h.feed([RingWire.info(read: 200, write: 200)])
        #expect(h.transport.writes == [RingProtocol.infoCommand()])  // no READ, no ADVANCE
        #expect(h.engine.state == .complete(records: 0))
        #expect(h.t.pendingChunks().isEmpty)
        let seal = try #require(h.seals().first)
        #expect(seal.lastChunkSequence == -1)
        #expect(seal.reason == .syncComplete)
        #expect(seal.ring?.infoReadSeq == 200)
        #expect(seal.ring?.doneNextSeq == 200)
        #expect(seal.ring?.coversUntil == ISO8601UTC.format(h.reconnectedAt))
    }

    @Test func legacyStatusIsUnsupportedAndWritesNothing() {
        let h = RingHarness()
        var support: [OfflineStorageSupport] = []
        h.engine.onSupportDetermined = { support.append($0) }
        h.engine.start(h.context())
        h.engine.handleStatusRead(Data(count: 8), error: nil)
        #expect(h.engine.state == .unsupported("legacy storage protocol (8-byte status)"))
        #expect(h.transport.writes.isEmpty)
        #expect(h.engine.commandsWritten.isEmpty)
        #expect(h.transport.notifyEnables == 0)
        #expect(support.last?.headerValue == false)
        #expect(h.seals().isEmpty)
    }

    @Test func staticChecksNeverTouchTheDevice() {
        for ctx in [RingHarness().context(fw: "3.0.19"), RingHarness().context(features: 0x1AC), RingHarness().context(storage: false), RingHarness().context(fw: "unknown")] {
            let h = RingHarness()
            h.engine.start(ctx)
            #expect(h.transport.statusReads == 0)
            #expect(h.transport.writes.isEmpty)
            #expect(!h.engine.state.isActive, "\(h.engine.state)")
        }
    }

    @Test func wrongRecordSizeIsUnsupportedAfterInfoOnly() {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 3)
        h.feed([RingWire.info(read: 0, write: 3, size: 440)])
        #expect(h.transport.writes == [RingProtocol.infoCommand()])
        if case .unsupported = h.engine.state {} else { Issue.record("expected unsupported") }
    }

    @Test func doneWithErrorInterruptsWithoutAdvance() throws {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 2)
        h.feed([RingWire.info(read: 10, write: 12), RingWire.readBegin(10, 2)])
        h.feed(RingWire.data([ringRecord(seq: 10)]))
        h.feed([RingWire.done(9, 11)])
        #expect(h.engine.state == .interrupted("DONE with storage not ready"))
        #expect(!h.transport.writes.contains { $0.first == RingProtocol.Command.advance })
        #expect(h.seals().first?.reason == .syncInterrupted)
        #expect(h.t.pendingChunks().first?.1.recordCount == 1)
    }

    @Test func nextSeqMismatchInterrupts() {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 2)
        h.feed([RingWire.info(read: 10, write: 12), RingWire.readBegin(10, 2)])
        h.feed(RingWire.data([ringRecord(seq: 10)]))
        h.feed([RingWire.done(0, 12)])  // claims 2 records, we reassembled 1
        if case .interrupted = h.engine.state {} else { Issue.record("expected interrupted") }
        #expect(!h.transport.writes.contains { $0.first == RingProtocol.Command.advance })
    }

    @Test func readRejectedByAck() {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 2)
        h.feed([RingWire.info(read: 10, write: 12), Data([0x01, 10])])
        #expect(h.engine.state == .interrupted("READ rejected: sequence out of range"))
        #expect(h.seals().first?.lastChunkSequence == -1)
    }

    @Test func stalledTransferTimesOutWithStop() {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 2)
        h.feed([RingWire.info(read: 10, write: 12)])
        h.t.clock.advance(16)
        h.engine.tick()
        #expect(h.transport.writes.last == RingProtocol.stopCommand())
        if case .interrupted = h.engine.state {} else { Issue.record("expected interrupted") }
    }

    @Test func infoTimeoutFailsWithoutCapture() {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 2)
        h.t.clock.advance(16)
        h.engine.tick()
        #expect(h.engine.state == .failed("no INFO response"))
        #expect(h.seals().isEmpty)
    }

    @Test func generationBumpReportedInSeal() throws {
        let h = RingHarness()
        var c = RingCursor()
        c.observe(info: .init(readSeq: 400, writeSeq: 500, capacity: 1, dropped: 0, recordSize: 444))
        c.notePersisted(499)
        try h.cursors.save(c, deviceId: "dev-1")
        h.startThroughInfoRequest(unread: 2)
        h.feed([RingWire.info(read: 0, write: 2), RingWire.readBegin(0, 2)])
        h.feed(RingWire.data([ringRecord(seq: 0), ringRecord(seq: 1)]))  // not dropped as duplicates
        h.feed([RingWire.done(0, 2)])
        #expect(h.engine.state == .complete(records: 2))
        #expect(try #require(h.seals().first).ring?.generation == 2)
        #expect(h.cursors.load("dev-1").generation == 2)
    }

    @Test func largeSyncSplitsIntoChunks() throws {
        let h = RingHarness(recordsPerChunk: 4)
        h.startThroughInfoRequest(unread: 10)
        h.feed([RingWire.info(read: 0, write: 10), RingWire.readBegin(0, 10)])
        h.feed(RingWire.data((0..<10).map { ringRecord(seq: UInt64($0)) }, chunk: 100))
        h.feed([RingWire.done(0, 10)])
        #expect(h.t.pendingChunks().map(\.1.recordCount) == [4, 4, 2])
        #expect(h.t.pendingChunks().map { $0.1.ring?.firstSequence } == [0, 4, 8])
        #expect(h.seals().first?.lastChunkSequence == 2)
    }
}
