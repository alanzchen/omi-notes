// Astra R1 2026-11-28 (R1-01), ported: fixture root moved from her worktree to the test temp dir.
import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite(.serialized) struct AstraLedgerCompatibilityChecks {
    @Test func sealedFlaggedCaptureNeverFallsBackToStaleHeaderWhenLedgerIsMissing() throws {
        let t = TestEnv()
        let (recorder, id) = try LiveCaptureTests().recorder(t)
        let dir = t.dirs.journalLive.appendingPathComponent(id)
        let journal = dir.appendingPathComponent("chunk-000000.journal")
        let header = dir.appendingPathComponent("chunk-000000.header")
        let output = t.dirs.outboxPending.appendingPathComponent(OutboxKind.chunk(captureId:id,sequence:0).fileName)
        defer { AstraR4Checks().allow(dir); AstraR4Checks().allow(t.dirs.outboxPending) }
        #expect(recorder.append(notification(seq:0)))
        // Attempt 1 saves its header/ledger but cannot publish into a non-writable outbox.
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:t.dirs.outboxPending.path)
        t.clock.advance(61); recorder.tick()
        try #require(!FileIO.exists(output))
        let stale = try Data(contentsOf:header)
        // Attempt 2 can append the existing ledger and publish, but best-effort .header replacement fails.
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:dir.path)
        try AstraR4Checks().restrict(t.dirs.outboxPending)
        t.clock.advance(61); recorder.tick()
        let published = try Data(contentsOf:output)
        try #require(try Data(contentsOf:header) == stale)
        let original = try Envelope.parse(published)
        let old = try JSONDecoder().decode(EnvelopeHeader.self,from:stale)
        try #require(original.header.chunkEndOffsetUs != old.chunkEndOffsetUs)
        try #require(FileIO.exists(journal))
        // Manifest checkpoint succeeds; finish writes a seal while failed directory sync keeps the journal.
        AstraR4Checks().allow(dir); recorder.tick()
        try #require(recorder.finish(reason:.bleDisconnected) != nil)
        try #require(t.outbox.contains(.seal(captureId:id)))
        try #require(FileIO.exists(journal))
        let m = try JSONDecoder().decode(CaptureManifest.self,from:Data(contentsOf:dir.appendingPathComponent("capture.json")))
        try #require(m.publicationLedger == true && m.openChunkSequence == 1)
        // The unconfirmed chunk entry and authoritative ledger are now unavailable after a synthetic crash.
        AstraR4Checks().allow(t.dirs.outboxPending)
        try FileManager.default.removeItem(at:output)
        try FileManager.default.removeItem(at:dir.appendingPathComponent("published.jsonl"))
        let report = CaptureRecovery.run(env:TestEnv(root:t.dirs.root).env,codecFallback:{_ in 21})
        let rebuilt = try? Data(contentsOf:output)
        print("FLAGGED MISSING LEDGER", "oldEnd",old.chunkEndOffsetUs,"publishedEnd",original.header.chunkEndOffsetUs,"rebuiltEqual",rebuilt == published,"journalExists",FileIO.exists(journal),"skipped",report.skipped)
        #expect(rebuilt == nil || rebuilt == published, "never republish the stale legacy header under the published identity")
        #expect(FileIO.exists(journal), "a flagged capture with a missing authoritative ledger remains unknown, including the sealed fast path")
    }
}
