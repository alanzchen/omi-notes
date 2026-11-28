// 2026-11-28 R1: the publication ledger's reading rules (DESIGN.md).
import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite struct PublicationLedgerUnitTests {
    @Test func theLedgerIgnoresATornLastLineAndRefusesAnyOtherDamage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omi-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PublicationLedger.lookup(0, in: dir) == .unknown, "missing")
        try PublicationLedger.create(in: dir)
        #expect(PublicationLedger.lookup(0, in: dir) == .none, "empty: nothing published")
        let h0 = EnvelopeHeader.sample(seq: 0, bytes: 10), h1 = EnvelopeHeader.sample(seq: 0, bytes: 20)
        try PublicationLedger.append(h0, in: dir); try PublicationLedger.append(h1, in: dir)
        #expect(PublicationLedger.lookup(0, in: dir) == .record(h1), "the last record for a sequence")
        #expect(PublicationLedger.lookup(1, in: dir) == .none)
        let url = dir.appendingPathComponent("published.jsonl")
        let fh = try FileHandle(forWritingTo: url); try fh.seekToEnd(); try fh.write(contentsOf: Data("{\"capture_id\":".utf8)); try fh.close()
        #expect(PublicationLedger.lookup(0, in: dir) == .record(h1), "a torn last line is an append that never finished")
        try Data("{}\n".utf8 + (try Data(contentsOf: url))).write(to: url)
        #expect(PublicationLedger.lookup(0, in: dir) == .unknown, "a damaged complete line: can't be trusted")
    }
}
