import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

/// Regression tests for the iOS code review (`/tmp/review_ios.md`). Each reproduces the reported
/// failure mode against the real code (fault injection where needed).
@Suite struct CaptureReviewRegressionTests {
    func faultyEnv() -> (TestEnv, FaultInjector) {
        var t = TestEnv()
        let faults = FaultInjector()
        var env = t.env
        env.faults = faults
        t = TestEnv(overriding: t, env: env)
        return (t, faults)
    }

    // MARK: #1 — a published chunk must never change

    @Test func failedManifestCommitNeverMutatesAPublishedChunk() throws {
        let (t, faults) = faultyEnv()
        let r = LiveCaptureRecorder(env: t.env)
        let id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: .opus20ms))
        r.append(notification(seq: 1))
        r.append(notification(seq: 2))
        t.clock.advance(1)
        faults.manifestSave = { throw InjectedFault(what: "manifest") }
        r.rotateNow(reason: .forced)
        let chunk0 = try #require(t.pendingChunks().first)
        let chunk0Bytes = try Data(contentsOf: chunk0.0.url)
        #expect(r.manifestDirty)
        // Recording continues; the next rotation must not rewrite chunk 0.
        r.append(notification(seq: 3))
        r.append(notification(seq: 4))
        t.clock.advance(1)
        r.rotateNow(reason: .forced)
        let chunks = t.pendingChunks()
        #expect(chunks.map(\.1.chunkSequence) == [0, 1])
        #expect(try Data(contentsOf: chunks[0].0.url) == chunk0Bytes, "chunk 0 bytes unchanged")
        #expect(chunks[0].1.recordCount == 2)
        #expect(chunks[1].1.recordCount == 2)
        #expect(BLERecord.scan(chunks[1].2).records.map(\.bytes) == [notification(seq: 3), notification(seq: 4)])
        #expect(chunks[1].1.chunkStartOffsetUs == chunks[0].1.chunkEndOffsetUs)

        // Crash with the manifest still stale (openChunkSequence 0), one record in journal 2.
        r.append(notification(seq: 5))
        r.syncNow()
        faults.manifestSave = nil
        let report = CaptureRecovery.run(env: t.env)
        #expect(report.liveRecovered == [id])
        let after = t.pendingChunks()
        #expect(after.map(\.1.chunkSequence) == [0, 1, 2], "uncommitted rotations re-derived, no duplicates")
        #expect(try Data(contentsOf: after[0].0.url) == chunk0Bytes)
        #expect(after[2].1.chunkStartOffsetUs == after[1].1.chunkEndOffsetUs)
        #expect(BLERecord.scan(after[2].2).records.map(\.bytes) == [notification(seq: 5)])
        let seal = try #require(t.seal(id))
        #expect(seal.lastChunkSequence == 2)
        #expect(seal.endOffsetUs == after[2].1.chunkEndOffsetUs)
    }

    @Test func manifestCommitIsRetriedOnTick() throws {
        let (t, faults) = faultyEnv()
        let r = LiveCaptureRecorder(env: t.env)
        let id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: .opus20ms))
        r.append(notification(seq: 1))
        faults.manifestSave = { throw InjectedFault(what: "manifest") }
        r.rotateNow(reason: .forced)
        #expect(r.manifestDirty)
        faults.manifestSave = nil
        r.tick()
        #expect(!r.manifestDirty)
        let m = try #require(JSONFile.load(CaptureManifest.self, from: t.dirs.journalLive.appendingPathComponent(id).appendingPathComponent("capture.json")))
        #expect(m.openChunkSequence == 1)
    }

    @Test func outboxNeverOverwritesAnIdentityWithDifferentBytes() throws {
        let t = TestEnv()
        let kind = OutboxKind.chunk(captureId: "c", sequence: 0)
        try t.outbox.write(Data([1, 2, 3]), kind: kind)
        #expect(throws: OutboxError.identityConflict(kind.fileName)) { try t.outbox.write(Data([9]), kind: kind) }
        #expect(try t.outbox.write(Data([1, 2, 3]), kind: kind).size == 3)  // identical: idempotent
        try t.outbox.markSent(kind.fileName)
        #expect(throws: OutboxError.self) { try t.outbox.write(Data([7]), kind: kind) }  // also across sent/
        #expect(try Data(contentsOf: t.dirs.outboxSent.appendingPathComponent(kind.fileName)) == Data([1, 2, 3]))
    }

    @Test func ringWriterManifestFailureNeverMutatesAPublishedChunk() throws {
        let (t, faults) = faultyEnv()
        let w = RingCaptureWriter(env: t.env, recordsPerChunk: 2)
        let info = RingProtocol.Info(readSeq: 0, writeSeq: 10, capacity: 100, dropped: 0, recordSize: 444)
        let id = try w.begin(.init(meta: CaptureDeviceMeta(deviceId: "dev"), codecId: 21, info: info, generation: 1, rtcValid: true, coversUntil: t.clock.wallNow()))
        faults.manifestSave = { throw InjectedFault(what: "manifest") }
        for s in UInt64(0)..<5 { try w.append(seq: s, record: ringRecord(seq: s)) }
        try w.syncIfDue(force: true)
        let chunks = t.pendingChunks()
        #expect(chunks.map { $0.1.ring?.firstSequence } == [0, 2])
        let bytes0 = try Data(contentsOf: chunks[0].0.url)
        faults.manifestSave = nil
        _ = CaptureRecovery.run(env: t.env)  // crash with a stale manifest
        let after = t.pendingChunks()
        #expect(after.map { $0.1.ring?.firstSequence } == [0, 2, 4])
        #expect(try Data(contentsOf: after[0].0.url) == bytes0)
        #expect(t.seal(id)?.lastChunkSequence == 2)
    }

    // MARK: #8 — never delete audio because the manifest is unreadable

    @Test func corruptManifestQuarantinesInsteadOfDeleting() throws {
        let t = TestEnv()
        let r = LiveCaptureRecorder(env: t.env)
        let id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: .opus20ms))
        for i in 0..<3 { r.append(notification(seq: UInt16(i))) }
        r.syncNow()
        let dir = t.dirs.journalLive.appendingPathComponent(id)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("capture.json"))
        let journal = try Data(contentsOf: dir.appendingPathComponent("chunk-000000.journal"))
        let report = CaptureRecovery.run(env: t.env)
        #expect(report.quarantined == [id])
        let kept = t.dirs.journalQuarantine.appendingPathComponent(id)
        #expect(try Data(contentsOf: kept.appendingPathComponent("chunk-000000.journal")) == journal)
        #expect(BLERecord.scan(journal).records.count == 3)
        #expect(!FileIO.exists(dir))
    }

    @Test func missingManifestWithDataIsQuarantinedEmptyDirIsRemoved() throws {
        let t = TestEnv()
        let withData = t.dirs.journalRing.appendingPathComponent("aaaa")
        try FileManager.default.createDirectory(at: withData, withIntermediateDirectories: true)
        try RingJournal.encode(seq: 1, record: ringRecord(seq: 1)).write(to: withData.appendingPathComponent("chunk-000000.journal"))
        let empty = t.dirs.journalLive.appendingPathComponent("bbbb")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("chunk-000000.journal"))
        let report = CaptureRecovery.run(env: t.env)
        #expect(report.quarantined == ["aaaa"])
        #expect(FileIO.exists(t.dirs.journalQuarantine.appendingPathComponent("aaaa/chunk-000000.journal")))
        #expect(!FileIO.exists(empty))
    }

    @Test func unreadableManifestIsLeftForTheNextLaunch() throws {
        let t = TestEnv()
        let r = LiveCaptureRecorder(env: t.env)
        let id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: .opus20ms))
        r.append(notification(seq: 1))
        r.syncNow()
        let manifest = t.dirs.journalLive.appendingPathComponent(id).appendingPathComponent("capture.json")
        chmod(manifest.path, 0o000)
        defer { chmod(manifest.path, 0o644) }
        let report = CaptureRecovery.run(env: t.env)
        #expect(report.skipped == [id])
        #expect(FileIO.exists(manifest))
    }

    // MARK: #17 — ring chunks rotate by time too

    @Test func slowRingTransferRotatesByElapsedTime() throws {
        let t = TestEnv()
        let w = RingCaptureWriter(env: t.env, recordsPerChunk: 600)
        let info = RingProtocol.Info(readSeq: 0, writeSeq: 500, capacity: 1000, dropped: 0, recordSize: 444)
        let id = try w.begin(.init(meta: CaptureDeviceMeta(deviceId: "dev"), codecId: 21, info: info, generation: 1, rtcValid: true, coversUntil: t.clock.wallNow()))
        for s in UInt64(0)..<500 {  // 9 s per record: 4500 s in total, below the idle timeout each time
            try w.append(seq: s, record: ringRecord(seq: s))
            t.clock.advance(9)
        }
        try w.finish(reason: .syncComplete, doneNextSeq: 500)
        let chunks = t.pendingChunks()
        #expect(chunks.count > 60)
        for c in chunks { #expect(c.1.chunkEndOffsetUs - c.1.chunkStartOffsetUs <= 69_000_000) }
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(a.1.chunkEndOffsetUs == b.1.chunkStartOffsetUs)
            #expect(a.1.ring!.firstSequence + UInt64(a.1.recordCount) == b.1.ring!.firstSequence)
        }
        #expect(t.seal(id)?.endOffsetUs == chunks.last?.1.chunkEndOffsetUs)
    }

    // MARK: Backend rule — record t_offset_us within [0, chunk span], non-decreasing

    @Test func recordOffsetsAlwaysWithinChunkSpan() throws {
        let t = TestEnv()
        let r = LiveCaptureRecorder(env: t.env)
        _ = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: .opus20ms))
        var rng = SystemRandomNumberGenerator()
        for i in 0..<400 {
            r.append(notification(seq: UInt16(i)))
            t.clock.advance([0.001, 0.02, 0.3, 4.9, 5.2, 61][Int.random(in: 0..<6, using: &rng)])
            if i % 37 == 0 { r.tick() }
            if i % 91 == 0 { r.rotateNow(reason: .forced) }
        }
        r.finish(reason: .bleDisconnected)
        let chunks = t.pendingChunks()
        #expect(chunks.count > 10)
        for c in chunks {
            let span = c.1.chunkEndOffsetUs - c.1.chunkStartOffsetUs
            let ts = BLERecord.scan(c.2).records.map { Int64($0.tOffsetUs) }
            #expect(ts == ts.sorted())
            #expect(ts.allSatisfy { $0 >= 0 && $0 <= span }, "chunk \(c.1.chunkSequence): \(ts.last ?? 0) > \(span)")
        }
    }
}

extension TestEnv {
    init(overriding base: TestEnv, env: CaptureEnvironment) {
        self = base
        self.env = env
    }
}

@Suite struct RingReviewRegressionTests {
    func harness() -> (RingHarness, FaultInjector) {
        let t = TestEnv()
        let faults = FaultInjector()
        var env = t.env
        env.faults = faults
        let h = RingHarness(t: TestEnv(overriding: t, env: env))
        return (h, faults)
    }

    // MARK: #2 — no ADVANCE unless the prefix, envelope and seal are durable

    @Test func fsyncFailureAtDonePreventsAdvance() throws {
        let (h, faults) = harness()
        h.startThroughInfoRequest(unread: 3)
        h.feed([RingWire.info(read: 10, write: 13), RingWire.readBegin(10, 3)])
        h.feed(RingWire.data((10..<13).map { ringRecord(seq: UInt64($0)) }))
        faults.journalSync = { throw InjectedFault(what: "fsync") }
        h.feed([RingWire.done(0, 13)])
        #expect(!h.transport.writes.contains { $0.first == RingProtocol.Command.advance }, "no ADVANCE after a failed fsync")
        #expect(!h.seals().contains { $0.reason == .syncComplete })
        if case .interrupted = h.engine.state {} else { Issue.record("expected interrupted, got \(h.engine.state)") }
    }

    @Test func envelopeWriteFailurePreventsAdvance() throws {
        let (h, _) = harness()
        h.startThroughInfoRequest(unread: 2)
        h.feed([RingWire.info(read: 0, write: 2), RingWire.readBegin(0, 2)])
        h.feed(RingWire.data([ringRecord(seq: 0), ringRecord(seq: 1)]))
        chmod(h.t.dirs.outboxPending.path, 0o555)
        defer { chmod(h.t.dirs.outboxPending.path, 0o755) }
        h.feed([RingWire.done(0, 2)])
        #expect(!h.transport.writes.contains { $0.first == RingProtocol.Command.advance })
        if case .interrupted = h.engine.state {} else { Issue.record("expected interrupted, got \(h.engine.state)") }
        #expect(!FileIO.contents(of: h.t.dirs.journalRing).isEmpty, "journal kept for recovery")
    }

    @Test func advanceComesAfterEnvelopeAndSeal() throws {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 1)
        h.feed([RingWire.info(read: 0, write: 1), RingWire.readBegin(0, 1)])
        h.feed(RingWire.data([ringRecord(seq: 0)]))
        var sealSeenAtAdvance = false
        let transport = h.transport
        let outbox = h.t.outbox
        transport.onWrite = { cmd in
            if cmd.first == RingProtocol.Command.advance {
                sealSeenAtAdvance = outbox.pending().contains { if case .seal = $0.kind { return true } else { return false } }
            }
        }
        h.feed([RingWire.done(0, 1)])
        #expect(sealSeenAtAdvance)
    }

    @Test func fsyncFailureMidTransferStopsIt() throws {
        let (h, faults) = harness()
        h.startThroughInfoRequest(unread: 5)
        h.feed([RingWire.info(read: 0, write: 5), RingWire.readBegin(0, 5)])
        h.feed(RingWire.data([ringRecord(seq: 0)]))
        faults.journalSync = { throw InjectedFault(what: "fsync") }
        h.t.clock.advance(1.2)
        h.feed(RingWire.data([ringRecord(seq: 1)]))
        #expect(h.transport.writes.last == RingProtocol.stopCommand())
        if case .interrupted = h.engine.state {} else { Issue.record("expected interrupted") }
    }

    @Test func cursorPersistFailureStopsTransfer() throws {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 3)
        h.feed([RingWire.info(read: 0, write: 3), RingWire.readBegin(0, 3)])
        h.cursors.faultHook = { throw InjectedFault(what: "cursor") }
        h.feed(RingWire.data([ringRecord(seq: 0), ringRecord(seq: 1), ringRecord(seq: 2)]))
        h.feed([RingWire.done(0, 3)])
        #expect(!h.transport.writes.contains { $0.first == RingProtocol.Command.advance })
    }

    // MARK: #12 — sync_complete only when the whole INFO range was transferred

    @Test func earlyDoneIsNotSyncComplete() throws {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 10)
        h.feed([RingWire.info(read: 100, write: 110), RingWire.readBegin(100, 10)])
        h.feed(RingWire.data([ringRecord(seq: 100)]))
        h.feed([RingWire.done(0, 101)])
        #expect(!h.seals().contains { $0.reason == .syncComplete })
        #expect(h.seals().first?.reason == .syncInterrupted)
        #expect(!h.transport.writes.contains { $0.first == RingProtocol.Command.advance })
    }

    @Test func readBeginMustMatchTheRequestedRange() throws {
        for rb in [RingWire.readBegin(101, 9), RingWire.readBegin(100, 5)] {
            let h = RingHarness()
            h.startThroughInfoRequest(unread: 10)
            h.feed([RingWire.info(read: 100, write: 110), rb])
            #expect(h.transport.writes.last == RingProtocol.stopCommand())
            if case .interrupted = h.engine.state {} else { Issue.record("expected interrupted for \(rb)") }
        }
    }

    // MARK: #3 — seal evidence is exact

    @Test func sealEvidenceIsExact() throws {
        let h = RingHarness()
        h.startThroughInfoRequest(unread: 2)
        h.feed([RingWire.info(read: 700, write: 702, dropped: 4), RingWire.readBegin(700, 2)])
        h.feed(RingWire.data([ringRecord(seq: 700), ringRecord(seq: 701)]))
        h.feed([RingWire.done(0, 702)])
        let seal = try #require(h.seals().first)
        #expect(seal.ring == RingSealEvidence(generation: 1, infoReadSeq: 700, infoWriteSeq: 702, doneNextSeq: 702, dropped: 4, rtcValid: true, coversUntil: ISO8601UTC.format(h.reconnectedAt)))
    }

    @Test func ringCapturesRegisterInTheLedgerInOrder() throws {
        let h = RingHarness()
        let ledger = RingCaptureLedger(dirs: h.t.dirs, outbox: h.t.outbox)
        h.engine.writer.ledger = ledger
        h.startThroughInfoRequest(unread: 2)
        h.feed([RingWire.info(read: 0, write: 2), RingWire.readBegin(0, 2), RingWire.data([ringRecord(seq: 0)])[0]])
        h.engine.handleDisconnect()  // A interrupted
        let h2 = RingHarness(t: h.t)
        h2.engine.writer.ledger = ledger
        h2.startThroughInfoRequest(unread: 0)
        h2.feed([RingWire.info(read: 2, write: 2)])  // B: empty sync_complete
        let ids = ledger.snapshot.map(\.captureId)
        #expect(ids.count == 2)
        let bSeal = try #require(h2.t.outbox.pendingItem(named: OutboxKind.seal(captureId: ids[1]).fileName))
        #expect(ledger.heldReason(bSeal) != nil, "B's sync_complete is held behind interrupted A")
    }
}

// MARK: - Verification pass (Astra round 2)

@Suite struct RecoveryVerificationRegressionTests {
    /// Starts a live capture, rotates chunk 0 (published + committed), and returns its directory.
    func publishedChunkZero(_ t: TestEnv) throws -> (String, URL) {
        let r = LiveCaptureRecorder(env: t.env)
        let id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: .opus20ms))
        r.append(notification(seq: 1))
        t.clock.advance(2)
        r.rotateNow(reason: .forced)
        return (id, t.dirs.journalLive.appendingPathComponent(id))
    }

    func rewindManifest(_ dir: URL) throws {
        var m = try #require(JSONFile.load(CaptureManifest.self, from: dir.appendingPathComponent("capture.json")))
        m.openChunkSequence = 0
        m.openChunkStartOffsetUs = 0
        try JSONFile.save(m, to: dir.appendingPathComponent("capture.json"))
    }

    /// #1: an unreadable journal is not "no journal": nothing is sealed or deleted until it can be read.
    @Test func unreadableJournalIsKeptAndRetried() throws {
        let t = TestEnv()
        let (id, dir) = try publishedChunkZero(t)
        let journal = dir.appendingPathComponent("chunk-000001.journal")
        try BLERecord(tOffsetUs: 0, flags: 0, bytes: notification(seq: 2)).encoded().write(to: journal)
        chmod(journal.path, 0o000)
        _ = CaptureRecovery.run(env: t.env)
        #expect(t.seal(id) == nil, "no terminal seal while the journal is unreadable")
        #expect(FileIO.exists(journal), "journal kept")
        chmod(journal.path, 0o644)
        _ = CaptureRecovery.run(env: t.env)
        let seal = try #require(t.seal(id))
        #expect(seal.lastChunkSequence == 1, "the journal became chunk 1 once readable")
    }

    /// #2: after a failed manifest commit, retention must not delete the envelope recovery needs.
    @Test func retentionPinsChunksAnUncommittedManifestStillNeeds() throws {
        let t = TestEnv()
        let (id, dir) = try publishedChunkZero(t)
        let chunk0 = OutboxKind.chunk(captureId: id, sequence: 0)
        #expect(!CaptureRecovery.isPinned(chunk0, pins: CaptureRecovery.retentionPins(env: t.env)), "committed past chunk 0")
        try rewindManifest(dir)
        #expect(CaptureRecovery.isPinned(chunk0, pins: CaptureRecovery.retentionPins(env: t.env)), "manifest still at 0")
        try Data("{".utf8).write(to: dir.appendingPathComponent("capture.json"))
        #expect(CaptureRecovery.isPinned(chunk0, pins: CaptureRecovery.retentionPins(env: t.env)), "unknown progress pins everything")
    }

    /// #2 safety net: a later journal that the manifest/outbox can't explain is quarantined, not deleted.
    @Test func unaccountedLaterJournalIsQuarantinedNotDeleted() throws {
        let t = TestEnv()
        let (id, dir) = try publishedChunkZero(t)
        try rewindManifest(dir)
        // Chunk 0's envelope is gone (as if retention removed it) while chunk 1's journal holds audio.
        let item = try #require(t.outbox.pending().first { $0.kind == .chunk(captureId: id, sequence: 0) })
        try FileManager.default.removeItem(at: item.url)
        try BLERecord(tOffsetUs: 0, flags: 0, bytes: notification(seq: 2)).encoded()
            .write(to: dir.appendingPathComponent("chunk-000001.journal"))
        let report = CaptureRecovery.run(env: t.env)
        #expect(t.seal(id) == nil, "no seal claiming the capture ended at -1")
        #expect(report.quarantined.contains(id))
        let kept = t.dirs.journalQuarantine.appendingPathComponent(id).appendingPathComponent("chunk-000001.journal")
        #expect(FileIO.fileSize(kept) > 0, "audio preserved in quarantine")
    }

    /// An unknown codec quarantines the capture instead of discarding its journal.
    @Test func unknownCodecQuarantinesInsteadOfDiscarding() throws {
        let t = TestEnv()
        let r = LiveCaptureRecorder(env: t.env)
        let id = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev-1", codec: nil))
        let dir = t.dirs.journalLive.appendingPathComponent(id)
        try BLERecord(tOffsetUs: 0, flags: 1, bytes: notification(seq: 1)).encoded()
            .write(to: dir.appendingPathComponent("chunk-000000.journal"))
        let report = CaptureRecovery.run(env: t.env)
        #expect(t.seal(id) == nil)
        #expect(report.quarantined.contains(id))
    }
}

@Suite struct LedgerVerificationRegressionTests {
    /// Verification #3: an unreadable ledger must fail closed, not become an empty ledger.
    @Test func unreadableLedgerFailsClosed() throws {
        let h = RingHarness()
        let ledger = RingCaptureLedger(dirs: h.t.dirs, outbox: h.t.outbox)
        h.engine.writer.ledger = ledger
        h.startThroughInfoRequest(unread: 2)
        h.feed([RingWire.info(read: 0, write: 2), RingWire.readBegin(0, 2), RingWire.data([ringRecord(seq: 0)])[0]])
        h.engine.handleDisconnect()  // A interrupted, still pending
        let h2 = RingHarness(t: h.t)
        h2.engine.writer.ledger = ledger
        h2.startThroughInfoRequest(unread: 0)
        h2.feed([RingWire.info(read: 2, write: 2)])  // B: empty sync_complete
        let bId = try #require(ledger.snapshot.map(\.captureId).last)
        let bSeal = try #require(h2.t.outbox.pendingItem(named: OutboxKind.seal(captureId: bId).fileName))

        try Data("not json".utf8).write(to: h.t.dirs.state.appendingPathComponent("ring-ledger.json"))
        let reopened = RingCaptureLedger(dirs: h.t.dirs, outbox: h.t.outbox)
        #expect(reopened.degraded)
        #expect(!reopened.mayUpload(bSeal), "B stays held while A's audio is unacknowledged")

        // Once A is fully acknowledged, B is released and the ledger leaves degraded mode.
        for item in h.t.outbox.pending() where item.kind.captureId != bId {
            try h.t.outbox.markSent(item.name)
            reopened.didAcknowledge(item)
        }
        for dir in FileIO.contents(of: h.t.dirs.journalRing) { try FileManager.default.removeItem(at: dir) }
        #expect(reopened.mayUpload(bSeal))
        try h.t.outbox.markSent(bSeal.name)
        reopened.didAcknowledge(bSeal)
        #expect(!reopened.degraded)
    }

    /// Two held seals never wait on each other in degraded mode: the older one goes first.
    @Test func degradedHeldSealsDoNotDeadlock() throws {
        let t = TestEnv()
        func writeSeal(_ id: String) throws -> OutboxItem {
            let seal = SealBody(lastChunkSequence: -1, reason: .syncComplete, endedAt: "2026-09-26T19:40:00.000Z",
                                endOffsetUs: 0, deviceId: "dev-1", source: .deviceRing)
            return try t.outbox.write(try ContractJSON.encode(seal), kind: .seal(captureId: id))
        }
        let older = try writeSeal("aaaaaaaa-0000-0000-0000-000000000001")
        t.clock.advance(5)
        Thread.sleep(forTimeInterval: 0.02)
        let newer = try writeSeal("bbbbbbbb-0000-0000-0000-000000000002")
        try Data("{".utf8).write(to: t.dirs.state.appendingPathComponent("ring-ledger.json"))
        let ledger = RingCaptureLedger(dirs: t.dirs, outbox: t.outbox)
        #expect(ledger.degraded)
        #expect(ledger.mayUpload(older))
        #expect(!ledger.mayUpload(newer))
    }
}
