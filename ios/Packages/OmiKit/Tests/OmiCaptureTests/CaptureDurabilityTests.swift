import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

/// ASTRA-20261118-IT2-01: a pendant journal (or its capture directory) is deleted, and ADVANCE is sent to the pendant, only
/// once the outbox entries it produced are confirmed durable (their directory synced). A failed confirmation keeps the
/// journal, sends no ADVANCE and never stops live capture; the next rotation, ring sync or launch recovery confirms
/// again (one directory sync covers every entry already published), and nothing is rebuilt under a published identity.
/// Real 0300 `outbox/pending` (write and rename allowed, open for its sync refused), no fault seam. SYNTHETIC audio.
@Suite(.serialized) struct CaptureDurabilityTests {
    func refuseDirectorySync(_ t: TestEnv) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: t.dirs.outboxPending.path)
        let fd = open(t.dirs.outboxPending.path, O_RDONLY), code = errno
        if fd >= 0 { close(fd) }
        try #require(fd < 0 && code == EACCES, "the OS must actually refuse the directory open")
    }

    func allowDirectorySync(_ t: TestEnv) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: t.dirs.outboxPending.path)
    }

    // MARK: ring

    @Test func ringMustNotAdvanceAndDropJournalAfterFailedOutputDirectorySync() throws {
        let h = RingHarness()
        defer { allowDirectorySync(h.t) }
        h.startThroughInfoRequest(unread: 1)
        h.feed([RingWire.info(read: 100, write: 101), RingWire.readBegin(100, 1)])
        h.feed(RingWire.data([ringRecord(seq: 100)]))
        let journals = FileIO.contents(of: h.t.dirs.journalRing)
        try #require(journals.count == 1)
        let journal = journals[0].appendingPathComponent(CaptureManifest.journalName(0))
        try #require(!(try Data(contentsOf: journal)).isEmpty)
        try refuseDirectorySync(h.t)
        h.feed([RingWire.done(0, 101)])
        #expect(!h.transport.writes.contains(RingProtocol.advanceCommand(newReadSeq: 101)), "the pendant keeps its records")
        #expect(FileIO.exists(journal), "the journal stays until the outbox is confirmed")
        #expect(h.engine.state != .complete(records: 1))
    }

    @Test func aRingResendAfterAMissingAdvanceIsDedupedAndRecoveryThenRetiresTheJournal() throws {
        let h = RingHarness()
        defer { allowDirectorySync(h.t) }
        h.startThroughInfoRequest(unread: 2)
        h.feed([RingWire.info(read: 100, write: 102), RingWire.readBegin(100, 2)])
        let records = [ringRecord(seq: 100), ringRecord(seq: 101)]
        h.feed(RingWire.data(records))
        try refuseDirectorySync(h.t)
        h.feed([RingWire.done(0, 102)])
        #expect(!h.transport.writes.contains(RingProtocol.advanceCommand(newReadSeq: 102)))
        allowDirectorySync(h.t)
        // the pendant wasn't advanced: it sends the same records again; they are dropped as duplicates, not re-stored
        let h2 = RingHarness(t: h.t)
        h2.startThroughInfoRequest(unread: 2)
        h2.feed([RingWire.info(read: 100, write: 102), RingWire.readBegin(100, 2)])
        h2.feed(RingWire.data(records))
        h2.feed([RingWire.done(0, 102)])
        #expect(h2.engine.duplicatesDropped == 2)
        #expect(h2.transport.writes.contains(RingProtocol.advanceCommand(newReadSeq: 102)))
        #expect(FileIO.contents(of: h.t.dirs.outboxQuarantine).isEmpty, "no conflict, nothing set aside")
        // the first capture's kept journal is retired by launch recovery once its seal is confirmed
        _ = CaptureRecovery.run(env: h.t.env, codecFallback: { _ in 21 })
        #expect(FileIO.contents(of: h.t.dirs.journalRing).isEmpty)
        #expect(h.t.pendingChunks().reduce(0) { $0 + $1.1.recordCount } == 2, "the two records once, under the first capture")
    }

    // MARK: live

    @Test func liveRotationMustKeepItsJournalWhenOutputDirectoryCannotSync() throws {
        let t = TestEnv()
        defer { allowDirectorySync(t) }
        let (recorder, id) = try LiveCaptureTests().recorder(t)
        #expect(recorder.append(notification(seq: 0)))
        let dir = t.dirs.journalLive.appendingPathComponent(id)
        let journal0 = dir.appendingPathComponent(CaptureManifest.journalName(0))
        try #require(FileIO.exists(journal0))
        try refuseDirectorySync(t)
        t.clock.advance(61)
        recorder.tick()
        #expect(FileIO.exists(journal0), "chunk 0 is in the outbox but not confirmed: its journal stays")
        // live capture goes on into chunk 1
        #expect(recorder.append(notification(seq: 1)))
        allowDirectorySync(t)
        t.clock.advance(61)
        recorder.tick()
        #expect(!FileIO.exists(journal0), "the next rotation confirms chunk 0 too and retires its journal")
        #expect(!FileIO.exists(dir.appendingPathComponent(CaptureManifest.journalName(1))))
        #expect(t.pendingChunks().map(\.1.chunkSequence).sorted() == [0, 1], "each chunk once, under its own identity")
        #expect(FileIO.contents(of: t.dirs.outboxQuarantine).isEmpty)
    }

    @Test func aSealedLiveCaptureKeepsItsDirectoryUntilRecoveryConfirmsIt() throws {
        let t = TestEnv()
        defer { allowDirectorySync(t) }
        let (recorder, id) = try LiveCaptureTests().recorder(t)
        #expect(recorder.append(notification(seq: 0)))
        let dir = t.dirs.journalLive.appendingPathComponent(id)
        try refuseDirectorySync(t)
        t.clock.advance(5)
        #expect(recorder.finish(reason: .bleDisconnected) != nil, "sealed in the outbox")
        #expect(FileIO.exists(dir), "but its journals stay until confirmed")
        _ = CaptureRecovery.run(env: t.env, codecFallback: { _ in 21 })
        #expect(FileIO.exists(dir), "still not confirmable: still kept")
        allowDirectorySync(t)
        _ = CaptureRecovery.run(env: t.env, codecFallback: { _ in 21 })
        #expect(!FileIO.exists(dir), "confirmed at the next launch: retired")
        #expect(t.pendingChunks().count == 1 && FileIO.contents(of: t.dirs.outboxQuarantine).isEmpty)
    }

    @Test func recoveryKeepsAnUnsealedCaptureUntilItsOutputIsConfirmed() throws {
        let t = TestEnv()
        defer { allowDirectorySync(t) }
        let (recorder, id) = try LiveCaptureTests().recorder(t)
        #expect(recorder.append(notification(seq: 0)))
        let dir = t.dirs.journalLive.appendingPathComponent(id)
        _ = recorder  // the app dies here: no finish
        try refuseDirectorySync(t)
        _ = CaptureRecovery.run(env: t.env, codecFallback: { _ in 21 })
        #expect(FileIO.exists(dir), "rebuilt and sealed in the outbox, but not confirmed: the journal stays")
        allowDirectorySync(t)
        _ = CaptureRecovery.run(env: t.env, codecFallback: { _ in 21 })
        #expect(!FileIO.exists(dir))
        #expect(t.pendingChunks().count == 1 && FileIO.contents(of: t.dirs.outboxQuarantine).isEmpty)
    }
}
