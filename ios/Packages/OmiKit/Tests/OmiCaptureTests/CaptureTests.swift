import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite struct RotationPolicyTests {
    let p = ChunkRotationPolicy()

    @Test func automaticReasons() {
        #expect(p.automaticReason(chunkAgeUs: 60_000_000, recordCount: 0, sinceLastRecordUs: nil) == .maxAge)
        #expect(p.automaticReason(chunkAgeUs: 59_000_000, recordCount: 3, sinceLastRecordUs: 5_000_000) == .idle)
        #expect(p.automaticReason(chunkAgeUs: 59_000_000, recordCount: 3, sinceLastRecordUs: 4_999_999) == nil)
        // Idle never rotates an empty chunk (it waits for max age: empty chunks carry coverage).
        #expect(p.automaticReason(chunkAgeUs: 30_000_000, recordCount: 0, sinceLastRecordUs: nil) == nil)
    }

    @Test func closingEndsSplitLongSpans() {
        #expect(p.closingEnds(chunkStartUs: 0, nowUs: 61_000_000) == [61_000_000])
        let ends = p.closingEnds(chunkStartUs: 1_000_000, nowUs: 10_801_000_000)
        #expect(ends == [4_001_000_000, 8_001_000_000, 10_801_000_000])
        var start: Int64 = 1_000_000
        for e in ends {
            #expect(e - start < Int64(UInt32.max))
            start = e
        }
    }
}

@Suite struct LiveCaptureTests {
    func recorder(_ t: TestEnv, codec: OmiCodec? = .opus20ms) throws -> (LiveCaptureRecorder, String) {
        let r = LiveCaptureRecorder(env: t.env)
        let id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", deviceName: "Omi", modelNumber: "Omi CV 1", firmwareRevision: "3.0.21", codec: codec, offlineStorage: true))
        return (r, id)
    }

    @Test func journalsRotatesAtMaxAgeAndSeals() throws {
        let t = TestEnv()
        let (r, id) = try recorder(t)
        for i in 0..<3 {
            #expect(r.append(notification(seq: UInt16(i))))
            t.clock.advance(0.02)
        }
        t.clock.advance(61 - 0.06)  // 61 s after capture start
        r.tick()
        var chunks = t.pendingChunks()
        try #require(chunks.count == 1)
        let (_, h0, p0) = chunks[0]
        #expect(h0.captureId == id)
        #expect(h0.chunkSequence == 0)
        #expect(h0.chunkStartOffsetUs == 0)
        #expect(h0.chunkEndOffsetUs == 61_000_000)
        #expect(h0.recordCount == 3)
        #expect(h0.codecId == 21)
        #expect(h0.source == .liveBLE)
        #expect(h0.clockQuality == .phoneAnchored)
        #expect(h0.offlineStorage == true)
        #expect(h0.captureStartedAt == "2026-09-26T19:32:05.123Z")
        let recs = BLERecord.scan(p0).records
        #expect(recs.map(\.tOffsetUs) == [0, 20_000, 40_000])
        #expect(recs.map(\.flags) == [1, 0, 0])  // SESSION_START only on the first record
        #expect(recs[1].bytes == notification(seq: 1))

        r.append(notification(seq: 3))
        t.clock.advance(1)
        let seal = try #require(r.finish(reason: .bleDisconnected))
        chunks = t.pendingChunks()
        #expect(chunks.count == 2)
        let (_, h1, p1) = chunks[1]
        #expect(h1.chunkStartOffsetUs == h0.chunkEndOffsetUs)  // contiguous coverage
        #expect(h1.chunkEndOffsetUs == 62_000_000)
        #expect(BLERecord.scan(p1).records.first?.flags == 0)
        #expect(BLERecord.scan(p1).records.first?.tOffsetUs == 0)
        #expect(seal.lastChunkSequence == 1)
        #expect(seal.endOffsetUs == 62_000_000)
        #expect(seal.reason == .bleDisconnected)
        #expect(seal.endedAt == "2026-09-26T19:33:07.123Z")
        #expect(t.seal(id) == seal)
        #expect(FileIO.contents(of: t.dirs.journalLive).isEmpty)
        #expect(!r.isActive)
    }

    @Test func idleRotationThenEmptyCoverageChunk() throws {
        let t = TestEnv()
        let (r, _) = try recorder(t)
        r.append(notification(seq: 10))
        t.clock.advance(5)
        r.tick()
        #expect(t.pendingChunks().count == 1)
        #expect(t.pendingChunks()[0].1.chunkEndOffsetUs == 5_000_000)
        t.clock.advance(5)
        r.tick()
        #expect(t.pendingChunks().count == 1)  // empty chunk does not idle-rotate
        t.clock.advance(55)
        r.tick()
        let chunks = t.pendingChunks()
        #expect(chunks.count == 2)
        #expect(chunks[1].1.recordCount == 0)
        #expect(chunks[1].1.payloadBytes == 0)
        #expect(chunks[1].1.chunkStartOffsetUs == 5_000_000)
        #expect(chunks[1].1.chunkEndOffsetUs == 65_000_000)
    }

    @Test func wakeAfterLongSuspensionClosesBoundedChunks() throws {
        let t = TestEnv()
        let (r, _) = try recorder(t)
        r.append(notification(seq: 1))
        t.clock.advance(3 * 3600)  // app suspended while the mic slept
        r.append(notification(seq: 2))
        let chunks = t.pendingChunks()
        #expect(chunks.map(\.1.recordCount) == [1, 0, 0])
        #expect(chunks.map(\.1.chunkEndOffsetUs) == [4_000_000_000, 8_000_000_000, 10_800_000_000])
        for c in chunks { #expect(c.1.chunkEndOffsetUs - c.1.chunkStartOffsetUs < Int64(UInt32.max)) }
        #expect(r.stats.chunkRecords == 1)
        #expect(r.coverage() == CoverageWatermark(captureId: r.captureId!, throughOffsetUs: 10_800_000_000, throughChunkSequence: 2))
    }

    @Test func wallClockJumpDoesNotReorder() throws {
        let t = TestEnv()
        let (r, _) = try recorder(t)
        r.append(notification(seq: 1))
        t.clock.advance(1)
        t.clock.jumpWall(-3600)
        r.append(notification(seq: 2))
        t.clock.advance(1)
        r.rotateNow(reason: .forced)
        let c = t.pendingChunks()[0]
        #expect(c.1.captureStartedAt == "2026-09-26T19:32:05.123Z")
        #expect(BLERecord.scan(c.2).records.map(\.tOffsetUs) == [0, 1_000_000])
        #expect(c.1.chunkEndOffsetUs == 2_000_000)
    }

    @Test func doubleTapAndResubscribe() throws {
        let t = TestEnv()
        let (r, _) = try recorder(t)
        r.append(notification(seq: 1))
        t.clock.advance(0.5)
        r.rotateNow(reason: .doubleTap)
        r.markResubscribed()
        r.append(notification(seq: 2))
        r.append(notification(seq: 3))
        t.clock.advance(0.5)
        r.rotateNow(reason: .forced)
        let chunks = t.pendingChunks()
        #expect(chunks.count == 2)
        #expect(chunks[0].1.chunkEndOffsetUs == 500_000)
        #expect(BLERecord.scan(chunks[1].2).records.map(\.flags) == [1, 0])
    }

    @Test func coverageWatermarkOnlyReferencesRotatedChunks() throws {
        let t = TestEnv()
        let (r, id) = try recorder(t)
        r.append(notification(seq: 1))
        t.clock.advance(12)
        #expect(r.coverage() == nil)  // nothing rotated yet: the open journal is never referenced
        r.rotateNow(reason: .forced)
        t.clock.advance(30)
        r.append(notification(seq: 2))
        let c = try #require(r.coverage())
        #expect(c == CoverageWatermark(captureId: id, throughOffsetUs: 12_000_000, throughChunkSequence: 0))
        #expect(t.pendingChunks().last?.1.chunkEndOffsetUs == c.throughOffsetUs)
    }

    @Test func sealEndEqualsLastChunkEndOnEveryPath() throws {
        let t = TestEnv()
        let (r, id) = try recorder(t)
        r.append(notification(seq: 1))
        t.clock.advance(61)
        r.tick()  // chunk 0 closes at 61 s; chunk 1 open and empty
        let seal = try #require(r.finish(reason: .userStopped))  // same instant: no zero-span chunk
        #expect(seal.lastChunkSequence == 0)
        #expect(seal.endOffsetUs == t.pendingChunks().last?.1.chunkEndOffsetUs)
        #expect(t.seal(id)?.endOffsetUs == 61_000_000)
    }

    /// An unsupported codec uploads nothing, but the journaled audio is quarantined, never deleted.
    @Test func abortQuarantinesInsteadOfDeleting() throws {
        let t = TestEnv()
        let (r, id) = try recorder(t, codec: nil)
        r.append(notification(seq: 1))
        r.abort()
        #expect(t.outbox.pending().isEmpty)
        #expect(FileIO.contents(of: t.dirs.journalLive).isEmpty)
        let kept = t.dirs.journalQuarantine.appendingPathComponent(id).appendingPathComponent("chunk-000000.journal")
        #expect(FileIO.fileSize(kept) > 0)
    }

    @Test func abortWithoutAudioLeavesNothing() throws {
        let t = TestEnv()
        let (r, _) = try recorder(t, codec: nil)
        r.abort()
        #expect(FileIO.contents(of: t.dirs.journalLive).isEmpty)
        #expect(FileIO.contents(of: t.dirs.journalQuarantine).isEmpty)
    }

    @Test func unknownCodecAtFinish() throws {
        let t = TestEnv()
        let (r, id) = try recorder(t, codec: nil)
        r.append(notification(seq: 1))
        t.clock.advance(1)
        // The codec was never read: nothing can be uploaded yet, but the audio stays in the journal.
        #expect(r.finish(reason: .bleDisconnected) == nil)
        #expect(t.pendingChunks().isEmpty)
        #expect(t.seal(id) == nil)
        // Next launch, once the device's codec is known, recovery turns it into a chunk + seal.
        _ = CaptureRecovery.run(env: t.env, codecFallback: { _ in 21 })
        #expect(t.pendingChunks().first { $0.1.captureId == id }?.1.codecId == 21)
        #expect(t.seal(id)?.lastChunkSequence == 0)

        // Without audio, an unknown codec still seals an empty capture (coverage evidence).
        let (r0, id0) = try recorder(t, codec: nil)
        t.clock.advance(1)
        #expect(r0.finish(reason: .bleDisconnected)?.lastChunkSequence == -1)
        #expect(t.seal(id0) != nil)

        let (r2, _) = try recorder(t, codec: nil)
        r2.codecFallback = { _ in 21 }
        r2.append(notification(seq: 2))
        t.clock.advance(1)
        #expect(r2.finish(reason: .userStopped)?.lastChunkSequence == 0)
        #expect(t.pendingChunks().first?.1.codecId == 21)
    }

    @Test func metadataUpdatesReachLaterChunks() throws {
        let t = TestEnv()
        let (r, _) = try recorder(t, codec: nil)
        r.append(notification(seq: 1))
        r.updateMeta(CaptureDeviceMeta(deviceId: "dev-1", hardwareRevision: "5.0", codec: .opus20ms, offlineStorage: false))
        t.clock.advance(1)
        r.rotateNow(reason: .forced)
        let h = try #require(t.pendingChunks().first?.1)
        #expect(h.codecId == 21)
        #expect(h.hardwareRevision == "5.0")
        #expect(h.offlineStorage == false)
        #expect(h.modelNumber == "Omi CV 1")
    }
}

@Suite struct RecoveryTests {
    @Test func tornTailIsCutAndCaptureSealedAppRecovered() throws {
        let t = TestEnv()
        var id = ""
        do {
            let r = LiveCaptureRecorder(env: t.env)
            id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: .opus20ms))
            for i in 0..<5 {
                r.append(notification(seq: UInt16(i)))
                t.clock.advance(0.02)
            }
            r.syncNow()
            // "crash": the recorder is dropped without finish()
        }
        let journal = t.dirs.journalLive.appendingPathComponent(id).appendingPathComponent("chunk-000000.journal")
        let size = FileIO.fileSize(journal)
        let fh = try FileHandle(forWritingTo: journal)
        try fh.truncate(atOffset: UInt64(size - 7))  // torn final record
        try fh.close()

        let report = CaptureRecovery.run(env: t.env)
        #expect(report.liveRecovered == [id])
        let chunks = t.pendingChunks()
        try #require(chunks.count == 1)
        #expect(chunks[0].1.recordCount == 4)
        #expect(chunks[0].1.chunkEndOffsetUs == 60_000)  // last journaled record
        let seal = try #require(t.seal(id))
        #expect(seal.reason == .appRecovered)
        #expect(seal.lastChunkSequence == 0)
        #expect(seal.endOffsetUs == 60_000)
        #expect(seal.source == .liveBLE)
        #expect(FileIO.contents(of: t.dirs.journalLive).isEmpty)
        // Idempotent: a second run finds nothing.
        #expect(CaptureRecovery.run(env: t.env).liveRecovered.isEmpty)
    }

    @Test func recoveryAfterRotationContinuesSequence() throws {
        let t = TestEnv()
        let r = LiveCaptureRecorder(env: t.env)
        let id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: .opus10ms))
        r.append(notification(seq: 1))
        t.clock.advance(61)
        r.append(notification(seq: 2))  // rotates chunk 0 first
        t.clock.advance(0.5)
        r.append(notification(seq: 3))
        r.syncNow()
        _ = CaptureRecovery.run(env: t.env)
        let chunks = t.pendingChunks()
        #expect(chunks.map(\.1.chunkSequence) == [0, 1])
        #expect(chunks[1].1.chunkStartOffsetUs == 61_000_000)
        #expect(chunks[1].1.chunkEndOffsetUs == 61_500_000)
        #expect(chunks[1].1.codecId == 20)
        #expect(t.seal(id)?.lastChunkSequence == 1)
    }

    @Test func crashBetweenEnvelopeAndManifestDoesNotDuplicate() throws {
        let t = TestEnv()
        let r = LiveCaptureRecorder(env: t.env)
        let id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: .opus20ms))
        r.append(notification(seq: 1))
        t.clock.advance(2)
        r.rotateNow(reason: .forced)
        // Rewind the manifest as if the process died right after writing chunk 0's envelope.
        let dir = t.dirs.journalLive.appendingPathComponent(id)
        var m = try #require(JSONFile.load(CaptureManifest.self, from: dir.appendingPathComponent("capture.json")))
        m.openChunkSequence = 0
        m.openChunkStartOffsetUs = 0
        try JSONFile.save(m, to: dir.appendingPathComponent("capture.json"))
        try BLERecord(tOffsetUs: 0, flags: 1, bytes: notification(seq: 1)).encoded().write(to: dir.appendingPathComponent("chunk-000000.journal"))
        let before = try Data(contentsOf: t.pendingChunks()[0].0.url)
        _ = CaptureRecovery.run(env: t.env)
        #expect(t.pendingChunks().count == 1)
        #expect(try Data(contentsOf: t.pendingChunks()[0].0.url) == before)
        let seal = try #require(t.seal(id))
        #expect(seal.lastChunkSequence == 0)
        #expect(seal.endOffsetUs == 2_000_000)
    }

    @Test func emptyCaptureRecoversAsEmptySeal() throws {
        let t = TestEnv()
        let r = LiveCaptureRecorder(env: t.env)
        let id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: .opus20ms))
        _ = r
        _ = CaptureRecovery.run(env: t.env)
        #expect(t.seal(id)?.lastChunkSequence == -1)
        #expect(t.pendingChunks().isEmpty)
    }

    @Test func ringJournalRecovery() throws {
        let t = TestEnv()
        let w = RingCaptureWriter(env: t.env)
        let info = RingProtocol.Info(readSeq: 100, writeSeq: 110, capacity: 1000, dropped: 0, recordSize: 444)
        let id = try w.begin(.init(meta: CaptureDeviceMeta(deviceId: "dev-1", firmwareRevision: "3.0.21"), codecId: 21, info: info, generation: 2, rtcValid: true, coversUntil: t.clock.wallNow()))
        for s in UInt64(100)..<103 { try w.append(seq: s, record: ringRecord(seq: s)) }
        try w.syncIfDue(force: true)
        // Torn half record at the tail.
        let journal = t.dirs.journalRing.appendingPathComponent(id).appendingPathComponent("chunk-000000.journal")
        let fh = try FileHandle(forWritingTo: journal)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(repeating: 0x55, count: 200))
        try fh.close()

        let report = CaptureRecovery.run(env: t.env)
        #expect(report.ringRecovered == [id])
        #expect(report.ringDurable == [.init(deviceId: "dev-1", generation: 2, seq: 102)])
        let c = try #require(t.pendingChunks().first)
        #expect(c.1.source == .deviceRing)
        #expect(c.1.payloadFormat == .ringRecordsV1)
        #expect(c.1.ring?.firstSequence == 100)
        #expect(c.1.recordCount == 3)
        #expect(c.2 == ringRecord(seq: 100) + ringRecord(seq: 101) + ringRecord(seq: 102))
        let seal = try #require(t.seal(id))
        #expect(seal.reason == .appRecovered)
        #expect(seal.source == .deviceRing)
        #expect(seal.lastChunkSequence == 0)
    }
}

@Suite struct RingWriterTests {
    @Test func chunksByRecordCountAndDiscontinuity() throws {
        let t = TestEnv()
        let w = RingCaptureWriter(env: t.env, recordsPerChunk: 4)
        let info = RingProtocol.Info(readSeq: 100, writeSeq: 120, capacity: 1000, dropped: 3, recordSize: 444)
        let id = try w.begin(.init(meta: CaptureDeviceMeta(deviceId: "dev-1"), codecId: 21, info: info, generation: 1, rtcValid: false, coversUntil: t.clock.wallNow()))
        for s in UInt64(100)..<110 { try w.append(seq: s, record: ringRecord(seq: s)) }
        try w.append(seq: 115, record: ringRecord(seq: 115))  // discontinuity
        t.clock.advance(3)
        let seal = try #require(try w.finish(reason: .syncComplete, doneNextSeq: 116))
        let chunks = t.pendingChunks()
        #expect(chunks.map(\.1.recordCount) == [4, 4, 2, 1])
        #expect(chunks.map { $0.1.ring?.firstSequence } == [100, 104, 108, 115])
        #expect(chunks.allSatisfy { $0.1.clockQuality == .unknown && $0.1.ring?.dropped == 3 && $0.1.offlineStorage == nil })
        #expect(seal.lastChunkSequence == 3)
        #expect(seal.ring?.doneNextSeq == 116)
        #expect(seal.ring?.generation == 1)
        #expect(seal.ring?.infoReadSeq == 100)
        #expect(t.seal(id) == seal)
    }
}

@Suite struct OutboxTests {
    @Test func namesRoundTrip() {
        for k: OutboxKind in [.chunk(captureId: "0b8a1f5e-2c3d-4e5f-8a9b-0c1d2e3f4a5b", sequence: 12), .seal(captureId: "abc"), .event(eventId: "e1")] {
            #expect(OutboxKind.parse(k.fileName) == k)
        }
        #expect(OutboxKind.chunk(captureId: "c", sequence: 12).path == "/v1/captures/c/chunks/12")
        #expect(OutboxKind.seal(captureId: "c").path == "/v1/captures/c/seal")
        #expect(OutboxKind.event(eventId: "e").path == "/v1/events/e")
        #expect(OutboxKind.parse(".tmp-x-chunk_a_000001.omnc") == nil)
        #expect(OutboxKind.parse("chunk_a_000001.omnc.reason") == nil)
    }

    @Test func movesBetweenDirectories() throws {
        let t = TestEnv()
        let item = try t.outbox.write(Data("{}".utf8), kind: .event(eventId: "e1"))
        let item2 = try t.outbox.write(Data("{}".utf8), kind: .event(eventId: "e2"))
        #expect(t.outbox.stats().pendingCount == 2)
        try t.outbox.markSent(item.name)
        try t.outbox.quarantine(item2.name, reason: "409")
        #expect(t.outbox.pending().isEmpty)
        #expect(t.outbox.sent().map(\.name) == [item.name])
        #expect(t.outbox.quarantined().map(\.name) == [item2.name])
        #expect(t.outbox.quarantineReason(item2.name) == "409")
        #expect(t.outbox.contains(.event(eventId: "e2")))
    }
}
