import CryptoKit
import Foundation
import Testing
@testable import OmiWatchKit

/// ASTRA-20261117-IT2-02: fsync's result was discarded, so a part whose bytes may not be on disk was still renamed into
/// place and acknowledged to the Watch (which then deletes its copy). A failed sync must stop the write, throw, and leave
/// nothing that answers for the part; the Watch keeps it and sends it again. SYNTHETIC bytes.
@Suite struct WatchSyncFailureTests {
    @Test func aFailedSyncStoresNothingAndAcknowledgesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-sync-\(UUID().uuidString)")
        let inbox = PhoneWatchInbox(root: root, currentBinding: { "phone-A" })
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("omi-sync-src-\(UUID().uuidString).m4a")
        try Data(repeating: 7, count: 4096).write(to: source)
        let sha = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        let segment = WatchSegment(recordingId: "rec-1", index: 0, deviceId: "watch-1", deviceName: "Apple Watch", binding: "phone-A",
                                   recordingStartedAt: Date(timeIntervalSince1970: 1_790_500_000), startOffsetUs: 0, endOffsetUs: 2_000_000,
                                   bytes: 4096, sha256: sha)
        SyncFaults.set(root, failing: true)
        defer { SyncFaults.set(root, failing: false) }
        #expect(throws: (any Error).self) { try inbox.accept(file: source, segment: segment) }
        let stored = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("inbox").path)) ?? []
        #expect(!stored.contains { !$0.hasPrefix(".") }, "nothing renamed into place: \(stored)")
        #expect(try inbox.answer(items: [WatchInventoryItem(id: segment.id, sha256: sha)], binding: "phone-A").acks.isEmpty,
                "asked again, the iPhone doesn't claim the part")
        // the Watch sends it again once syncing works: stored and acknowledged
        SyncFaults.set(root, failing: false)
        try inbox.accept(file: source, segment: segment)
        #expect(try inbox.answer(items: [WatchInventoryItem(id: segment.id, sha256: sha)], binding: "phone-A").acks == [segment.id])
    }

    @Test func aFailedDirectorySyncIsAnErrorToo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omi-sync-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("receipt.json")
        SyncFaults.set(dir, failing: true, exactly: true)  // the file syncs, its directory doesn't
        defer { SyncFaults.set(dir, failing: false) }
        #expect(throws: (any Error).self) { try Files.durableWrite(Data("x".utf8), to: url) }
    }
}
