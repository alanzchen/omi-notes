import CryptoKit
import Foundation
import Testing
@testable import OmiWatchKit

/// One rule (2026-11-18): the iPhone only tells the Watch it holds a part after the part's audio, its manifest and
/// their directory were synced. Every answer that can say "held" (a repeat accept, the inventory answer, a sync-ping
/// receipt) goes through the same check, so a part whose publication sync failed (ASTRA-20261117-IT3-01) is answered
/// by none of them until a later sync succeeds. SYNTHETIC bytes; failures are injected at `SyncFaults`.
@Suite(.serialized) struct WatchReceiptDurabilityTests {
    struct Part {
        let inbox: PhoneWatchInbox
        let root: URL
        let file: URL
        let segment: WatchSegment
        var item: WatchInventoryItem { WatchInventoryItem(id: segment.id, sha256: segment.sha256) }
        var inboxDir: URL { root.appendingPathComponent("inbox") }

        func held() throws -> Bool {
            let inventory = try inbox.answer(items: [item], binding: "phone-A").acks == [segment.id]
            let ping = try inbox.receipts(items: [item], binding: "phone-A") == [item]
            #expect(inventory == ping, "the inventory answer and the sync ping agree")
            return inventory && ping
        }
    }

    func part(index: Int = 0) throws -> Part {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-receipt-\(UUID().uuidString)")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("omi-receipt-src-\(UUID().uuidString).m4a")
        try Data(repeating: UInt8(index + 3), count: 4096).write(to: file)
        let sha = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        let segment = WatchSegment(recordingId: "rec-1", index: index, deviceId: "watch-1", deviceName: "Apple Watch", binding: "phone-A",
                                   recordingStartedAt: Date(timeIntervalSince1970: 1_790_500_000), startOffsetUs: 0, endOffsetUs: 2_000_000,
                                   bytes: 4096, sha256: sha)
        return Part(inbox: PhoneWatchInbox(root: root, currentBinding: { "phone-A" }), root: root, file: file, segment: segment)
    }

    @Test func aDirectorySyncFailureAfterTheManifestRenameIsAnsweredByNoPath() throws {
        let p = try part()
        // the audio's directory sync succeeds, the manifest's fails: both files are in place, not known durable
        SyncFaults.set(p.inboxDir, failing: true, exactly: true, after: 1)
        defer { SyncFaults.set(p.inboxDir, failing: false) }
        #expect(throws: (any Error).self) { try p.inbox.accept(file: p.file, segment: p.segment) }
        #expect(FileManager.default.fileExists(atPath: p.inboxDir.appendingPathComponent("\(p.segment.id).json").path))
        #expect(throws: (any Error).self, "a repeat accept doesn't acknowledge") { try p.inbox.accept(file: p.file, segment: p.segment) }
        #expect(try !p.held(), "neither the inventory answer nor a sync ping")
        // a later sync succeeds: now every path says held
        SyncFaults.set(p.inboxDir, failing: false)
        #expect(try p.held())
        try p.inbox.accept(file: p.file, segment: p.segment)
    }

    @Test func afterARelaunchAPartIsHeldOnlyOnceItSyncs() throws {
        let p = try part(index: 1)
        SyncFaults.set(p.inboxDir, failing: true, exactly: true, after: 1)
        defer { SyncFaults.set(p.inboxDir, failing: false) }
        #expect(throws: (any Error).self) { try p.inbox.accept(file: p.file, segment: p.segment) }
        let relaunched = Part(inbox: PhoneWatchInbox(root: p.root, currentBinding: { "phone-A" }), root: p.root, file: p.file, segment: p.segment)
        #expect(try !relaunched.held(), "files left by the earlier run aren't trusted until they sync")
        SyncFaults.set(p.inboxDir, failing: false)
        #expect(try relaunched.held())
    }

    @Test func audioPublishedWithoutAManifestIsMissingUntilTheResend() throws {
        let p = try part(index: 2)
        // the audio's own directory sync fails once: no manifest is written
        SyncFaults.set(p.inboxDir, failing: true, exactly: true, times: 1)
        defer { SyncFaults.set(p.inboxDir, failing: false) }
        #expect(throws: (any Error).self) { try p.inbox.accept(file: p.file, segment: p.segment) }
        #expect(try !p.held())
        try p.inbox.accept(file: p.file, segment: p.segment)  // the Watch sends it again
        #expect(try p.held())
    }
}

/// ASTRA-20261117-IT3-03: on the Watch, a part or end whose publication failed while the outbox index was loaded stayed
/// out of the index (unsent) until the app relaunched. SYNTHETIC bytes.
@Suite(.serialized) struct WatchOutboxRetryTests {
    @Test func aFailedPublicationIsStillFoundWithoutARelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-outbox-\(UUID().uuidString)")
        let outbox = WatchOutbox(root: root)
        #expect(outbox.segments().isEmpty && outbox.ends().isEmpty)  // both indexes are loaded now
        let file = root.appendingPathComponent("rec.m4a")
        try Data(repeating: 9, count: 2048).write(to: file)
        let sha = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        let segment = WatchSegment(recordingId: "r", index: 0, deviceId: "watch-1", deviceName: "W", binding: "p",
                                   recordingStartedAt: Date(timeIntervalSince1970: 1_790_500_000), startOffsetUs: 0, endOffsetUs: 2_000_000,
                                   bytes: 2048, sha256: sha)
        let segmentsDir = root.appendingPathComponent("segments"), endsDir = root.appendingPathComponent("ends")
        SyncFaults.set(segmentsDir, failing: true, exactly: true, after: 1, times: 1)  // the intent syncs, the manifest doesn't
        defer { SyncFaults.set(segmentsDir, failing: false) }
        #expect(throws: (any Error).self) { try outbox.add(segmentFile: file, segment: segment) }
        #expect(outbox.segments().contains { $0.segment.id == segment.id }, "published again from its intent, no relaunch")
        let end = WatchRecordingEnd(recordingId: "r", deviceId: "watch-1", binding: "p", lastIndex: 0, endOffsetUs: 2_000_000,
                                    endedAt: Date(timeIntervalSince1970: 1_790_500_002), reason: .userStopped)
        SyncFaults.set(endsDir, failing: true, exactly: true, times: 1)
        defer { SyncFaults.set(endsDir, failing: false) }
        #expect(throws: (any Error).self) { try outbox.add(end: end) }
        #expect(outbox.ends().contains { $0.id == end.id }, "the end that was written is sent without a relaunch")
    }
}
