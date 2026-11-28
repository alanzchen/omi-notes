// 2026-11-28 R1: a published chunk's identity comes from the capture's publication ledger (published.jsonl), never
// re-inferred (ASTRA-20261119-IT3-01). Captures written by builds up to 66 (no ledger, no manifest flag) keep their rule,
// except that a header that exists but can't be read now keeps the journal (build/deployment/nightly/2026-11-28/round1/DESIGN.md).
import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite(.serialized) struct PublicationLedgerTests {
    /// A published chunk 0 whose outbox entry was then lost, with its successor journal never created and the manifest
    /// checkpoint failed (Astra's IT3 setup), optionally turned into what a build-66 capture looks like on disk.
    func publishedThenLost(_ t: inout TestEnv, build66: Bool) throws -> (dir: URL, journal: URL, header: URL, output: URL, original: Data) {
        let faults = FaultInjector(); t.env.faults = faults
        var recorder: LiveCaptureRecorder? = try LiveCaptureTests().recorder(t).0
        let id = try #require(recorder?.captureId)
        let dir = t.dirs.journalLive.appendingPathComponent(id)
        #expect(recorder?.append(notification(seq: 0)) == true)
        faults.manifestSave = {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path); throw InjectedFault(what: "checkpoint")
        }
        try AstraR4Checks().restrict(t.dirs.outboxPending); t.clock.advance(61); recorder?.tick(); recorder = nil
        AstraR4Checks().allow(dir); AstraR4Checks().allow(t.dirs.outboxPending)
        try #require(!FileIO.exists(dir.appendingPathComponent("chunk-000001.journal")))
        let output = t.dirs.outboxPending.appendingPathComponent(OutboxKind.chunk(captureId: id, sequence: 0).fileName)
        let original = try Data(contentsOf: output)
        try FileManager.default.removeItem(at: output)
        if build66 { try makeBuild66(dir) }
        return (dir, dir.appendingPathComponent("chunk-000000.journal"), dir.appendingPathComponent("chunk-000000.header"), output, original)
    }

    /// What a build up to 66 leaves: no ledger file, no `publicationLedger` key in capture.json.
    func makeBuild66(_ dir: URL) throws {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("published.jsonl"))
        let url = dir.appendingPathComponent("capture.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["publicationLedger"] as? Bool == true, "a new capture is flagged")
        json["publicationLedger"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    @Test func aNewCaptureRebuildsAPublishedChunkFromItsLedgerWithItsHeaderFileGone() throws {
        var t = TestEnv()
        let p = try publishedThenLost(&t, build66: false)
        try FileManager.default.removeItem(at: p.header)
        _ = CaptureRecovery.run(env: TestEnv(root: t.dirs.root).env, codecFallback: { _ in 21 })
        #expect(try Data(contentsOf: p.output) == p.original, "the same envelope, bytes and identity")
    }

    @Test func aNewCaptureWithItsLedgerGoneKeepsTheJournalAndDerivesNothing() throws {
        var t = TestEnv()
        let p = try publishedThenLost(&t, build66: false)
        let raw = try Data(contentsOf: p.journal)
        try FileManager.default.removeItem(at: p.header)
        try FileManager.default.removeItem(at: p.dir.appendingPathComponent("published.jsonl"))
        _ = CaptureRecovery.run(env: TestEnv(root: t.dirs.root).env, codecFallback: { _ in 21 })
        #expect(!FileIO.exists(p.output), "unknown publication: never derived")
        #expect(try Data(contentsOf: p.journal) == raw, "the journal and its audio stay")
    }

    @Test func aBuild66CaptureWithAnUnreadableHeaderKeepsItsJournal() throws {
        var t = TestEnv()
        let p = try publishedThenLost(&t, build66: true)
        let raw = try Data(contentsOf: p.journal)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: p.header.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p.header.path) }
        _ = CaptureRecovery.run(env: TestEnv(root: t.dirs.root).env, codecFallback: { _ in 21 })
        #expect(!FileIO.exists(p.output), "unreadable is not absent: never derived")
        #expect(try Data(contentsOf: p.journal) == raw)
    }

    @Test func aBuild66CaptureWithAReadableHeaderStillRebuildsFromIt() throws {
        var t = TestEnv()
        let p = try publishedThenLost(&t, build66: true)
        _ = CaptureRecovery.run(env: TestEnv(root: t.dirs.root).env, codecFallback: { _ in 21 })
        #expect(try Data(contentsOf: p.output) == p.original)
    }

    @Test func aBuild66CaptureWithAnOpenJournalAndNoHeaderStillRecovers() throws {
        // a normal crash before any publication, from a build without the ledger: no migration, recovered as before
        let t = TestEnv()
        var rec: LiveCaptureRecorder? = try LiveCaptureTests().recorder(t).0
        let id = try #require(rec?.captureId)
        #expect(rec?.append(notification(seq: 0)) == true); rec?.syncNow(); rec = nil
        let dir = t.dirs.journalLive.appendingPathComponent(id)
        try makeBuild66(dir)
        _ = CaptureRecovery.run(env: TestEnv(root: t.dirs.root).env, codecFallback: { _ in 21 })
        #expect(t.outbox.contains(.chunk(captureId: id, sequence: 0)))
        #expect(t.outbox.contains(.seal(captureId: id)))
    }
}

extension EnvelopeHeader {
    static func sample(seq: Int, bytes: Int) -> EnvelopeHeader {
        EnvelopeHeader(captureId: "c", chunkSequence: seq, deviceId: "d", deviceName: nil, modelNumber: nil, firmwareRevision: nil,
                       hardwareRevision: nil, source: .liveBLE, payloadFormat: .bleNotificationsV1, codecId: 21,
                       captureStartedAt: "2026-11-28T00:00:00.000Z", chunkStartOffsetUs: 0, chunkEndOffsetUs: 1,
                       clockQuality: .phoneAnchored, timezone: nil, recordCount: 1, payloadBytes: bytes, offlineStorage: nil,
                       ring: nil, appVersion: nil)
    }
}
