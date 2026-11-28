// Astra R1 2026-11-28 (R1-02), ported: scratch dir moved to the test temp dir.
import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite struct AstraLedgerAppendChecks {
    @Test func aSuccessfulRetryMustLeaveItsPublicationRecordReadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("astra-ledger-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try PublicationLedger.create(in: dir)
        let old = EnvelopeHeader.sample(seq: 0, bytes: 10)
        let next = EnvelopeHeader.sample(seq: 1, bytes: 20)
        try PublicationLedger.append(old, in: dir)
        // A failed write left an incomplete final line. lookup currently ignores this safely.
        let file = try FileHandle(forWritingTo: PublicationLedger.url(dir))
        try file.seekToEnd(); try file.write(contentsOf: Data("{\"capture_id\":".utf8)); try file.close()
        #expect(PublicationLedger.lookup(0, in: dir) == .record(old))
        // The recorder retries append before publishing. This returns success, authorizing its outbox.write.
        try PublicationLedger.append(next, in: dir)
        #expect(PublicationLedger.lookup(1, in: dir) == .record(next), "successful append must not authorize publication behind an unreadable line")
        #expect(PublicationLedger.lookup(0, in: dir) == .record(old), "a failed append must not hide previous published identities")
    }
}
