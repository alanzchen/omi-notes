// ASTRA-20261118-IT3 review checks (reused unchanged).
import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite(.serialized) struct AstraR3BoundaryChecks {
    func restrict(_ dir: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions:0o300],ofItemAtPath:dir.path)
        let fd=open(dir.path,O_RDONLY), code=errno
        if fd >= 0 { close(fd) }
        try #require(fd < 0 && code == EACCES)
    }
    func allow(_ dir: URL) { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:dir.path) }

    @Test func recoveryMustConfirmActualQuarantineDirectoryBeforeRetiringOriginal() throws {
        let t=TestEnv()
        defer { allow(t.dirs.outboxPending); allow(t.dirs.outboxQuarantine) }
        let (recorder,id)=try LiveCaptureTests().recorder(t)
        #expect(recorder.append(notification(seq:0)))
        try restrict(t.dirs.outboxPending)
        t.clock.advance(5)
        try #require(recorder.finish(reason:.bleDisconnected) != nil)
        let dir=t.dirs.journalLive.appendingPathComponent(id)
        let journal=dir.appendingPathComponent(CaptureManifest.journalName(0))
        try #require(FileIO.exists(journal))
        // Same production transition as a rejected background upload. Its target permits rename but refuses fsync-open.
        try restrict(t.dirs.outboxQuarantine)
        try t.outbox.quarantine(OutboxKind.chunk(captureId:id,sequence:0).fileName,reason:"422: synthetic rejection")
        allow(t.dirs.outboxPending)
        _ = CaptureRecovery.run(env:t.env,codecFallback:{_ in 21})
        #expect(FileIO.exists(journal),"syncing pending does not confirm the unsynced quarantine destination")
        #expect(FileIO.exists(dir))
    }

    @Test func nextLiveRotationMustNotRetireAChunkMovedToUnconfirmedQuarantine() throws {
        let t=TestEnv()
        defer { allow(t.dirs.outboxPending); allow(t.dirs.outboxQuarantine) }
        let (recorder,id)=try LiveCaptureTests().recorder(t)
        #expect(recorder.append(notification(seq:0)))
        try restrict(t.dirs.outboxPending)
        t.clock.advance(61);recorder.tick()
        let journal=t.dirs.journalLive.appendingPathComponent(id).appendingPathComponent(CaptureManifest.journalName(0))
        try #require(FileIO.exists(journal))
        try restrict(t.dirs.outboxQuarantine)
        try t.outbox.quarantine(OutboxKind.chunk(captureId:id,sequence:0).fileName,reason:"422: synthetic rejection")
        allow(t.dirs.outboxPending)
        #expect(recorder.append(notification(seq:1)))
        t.clock.advance(61);recorder.tick()
        #expect(FileIO.exists(journal),"a later pending-only confirm cannot retire the old quarantined chunk's source")
    }

    @Test func recoveryMustRebuildRetainedEarlierJournalIfUnconfirmedOutputIsLost() throws { try lostOutput(sealed: false) }
    @Test func aSurvivingSealDoesNotProveItsMissingChunkIsDurable() throws { try lostOutput(sealed: true) }
    func lostOutput(sealed: Bool) throws {
        let t=TestEnv()
        defer { allow(t.dirs.outboxPending) }
        var recorder:LiveCaptureRecorder?=try LiveCaptureTests().recorder(t).0
        let id=try #require(recorder?.captureId)
        #expect(recorder?.append(notification(seq:0)) == true)
        try restrict(t.dirs.outboxPending)
        t.clock.advance(61);recorder?.tick()
        let dir=t.dirs.journalLive.appendingPathComponent(id)
        let journal=dir.appendingPathComponent(CaptureManifest.journalName(0))
        let retainedBytes=try Data(contentsOf:journal)
        try #require(!retainedBytes.isEmpty)
        let chunk=OutboxKind.chunk(captureId:id,sequence:0)
        let output=t.dirs.outboxPending.appendingPathComponent(chunk.fileName)
        try #require(FileIO.exists(output))
        if sealed { try #require(recorder?.finish(reason:.bleDisconnected) != nil) }
        recorder=nil // synthetic process loss; rotated journal is frozen
        // Simulate only the permitted crash outcome of failed directory publication, not corruption of durable audio.
        try FileManager.default.removeItem(at:output)
        allow(t.dirs.outboxPending)
        let fresh=TestEnv(root:t.dirs.root)
        _ = CaptureRecovery.run(env:fresh.env,codecFallback:{_ in 21})
        #expect(FileIO.exists(output) || FileIO.exists(journal),"must reconstruct the missing chunk or preserve its journal, never drop both")
        #expect(FileIO.exists(output),"recovery skipped the retained journal below the manifest sequence")
    }
    @Test func frozenJournalAndPublishedBytesStayUnchangedWhileLiveRecordingContinues() throws {
        let t=TestEnv()
        defer { allow(t.dirs.outboxPending) }
        let (recorder,id)=try LiveCaptureTests().recorder(t)
        #expect(recorder.append(notification(seq:0)))
        try restrict(t.dirs.outboxPending)
        t.clock.advance(61);recorder.tick()
        let journal=t.dirs.journalLive.appendingPathComponent(id).appendingPathComponent(CaptureManifest.journalName(0))
        let output=t.dirs.outboxPending.appendingPathComponent(OutboxKind.chunk(captureId:id,sequence:0).fileName)
        let frozen=try Data(contentsOf:journal), envelope=try Data(contentsOf:output)
        for n in 1...20 { #expect(recorder.append(notification(seq:UInt16(n))));t.clock.advance(0.02) }
        #expect(try Data(contentsOf:journal) == frozen)
        #expect(try Data(contentsOf:output) == envelope)
        allow(t.dirs.outboxPending)
        t.clock.advance(61);recorder.tick()
        #expect(!FileIO.exists(journal))
        #expect(try Data(contentsOf:output) == envelope)
        #expect(t.pendingChunks().map(\.1.chunkSequence).sorted() == [0,1])
        #expect(t.outbox.quarantined().isEmpty)
    }

}
