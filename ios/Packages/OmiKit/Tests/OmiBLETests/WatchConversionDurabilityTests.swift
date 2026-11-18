import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
@testable import OmiWatchKit

/// ASTRA-20261118-IT1-01: the Watch part's conversion handed its output to the outbox, whose directory sync failure was
/// ignored, then removed the durable inbox original and wrote the receipt the Watch deletes its copy on. A part is
/// converted only once its output is durably published; until then the original stays and is what a receipt rests
/// on. Real OS errors (a 0300 directory that can't be opened for its sync), no fault seam. SYNTHETIC audio.
@Suite(.serialized) struct WatchConversionDurabilityTests {
    struct Rig {
        let root: URL, dirs: CaptureDirectories, inbox: PhoneWatchInbox, relay: WatchRelayProcessor, segment: WatchSegment
        var original: URL { inbox.root.appendingPathComponent("inbox/\(segment.id).m4a") }
        var quarantined: URL { inbox.root.appendingPathComponent("quarantine/\(segment.id).m4a") }
        func receipts() throws -> [WatchInventoryItem] {
            try inbox.receipts(items: [WatchInventoryItem(id: segment.id, sha256: segment.sha256)], binding: "phone-A")
        }
        func lockOutput() throws { try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: dirs.outboxPending.path) }
        func unlockOutput() { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirs.outboxPending.path) }
    }

    func rig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-conversion-\(UUID().uuidString)")
        let dirs = CaptureDirectories(root: root)
        try dirs.create()
        let inbox = PhoneWatchInbox(root: root.appendingPathComponent("watch"), binding: "phone-A")
        let relay = WatchRelayProcessor(inbox: inbox, outbox: Outbox(dirs: dirs), appVersion: "synthetic", timezone: "UTC", serverTakesAAC: { true })
        let file = try WatchRelayTests.segmentFile(seconds: 0.25, in: root, name: "synthetic")
        let segment = WatchRelayTests().manifest(file, recording: UUID().uuidString.lowercased(), index: 0, binding: "phone-A", start: 0)
        try inbox.accept(file: file, segment: segment)
        return Rig(root: root, dirs: dirs, inbox: inbox, relay: relay, segment: segment)
    }

    func directoryRefusesOpen(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY), code = errno
        if fd >= 0 { close(fd) }
        return fd < 0 && code == EACCES
    }

    @Test func noConvertedReceiptWhenOutputDirectoryCannotBeSynced() throws {
        let r = try rig()
        defer { r.unlockOutput(); try? FileManager.default.removeItem(at: r.root) }
        try r.lockOutput()
        try #require(directoryRefusesOpen(r.dirs.outboxPending), "the OS must actually refuse the directory open")
        #expect(r.relay.process() == 0, "not converted while its output's directory sync fails")
        #expect(FileManager.default.fileExists(atPath: r.original.path), "the original stays in the inbox, to be tried again")
        #expect(!FileManager.default.fileExists(atPath: r.quarantined.path), "a storage failure isn't a bad part: not set aside")
        #expect(try r.receipts().count == 1, "the receipt rests on the durable original")
    }

    @Test func anOutputAlreadyInPlaceIsNotTrustedUntilItsDirectorySyncs() throws {
        let r = try rig()
        defer { r.unlockOutput(); try? FileManager.default.removeItem(at: r.root) }
        try r.lockOutput()
        _ = r.relay.process()  // renamed in, directory not synced
        #expect(r.relay.process() == 0, "the file being there doesn't make the earlier publication durable")
        #expect(FileManager.default.fileExists(atPath: r.original.path))
        r.unlockOutput()
        #expect(r.relay.process() == 1, "once the directory syncs, the same output is accepted")
        #expect(!FileManager.default.fileExists(atPath: r.original.path), "and only then is the original replaced by the receipt")
        #expect(try r.receipts().count == 1)
    }

    @Test func pendantCaptureWritesKeepTheirBehaviourWhenTheDirectoryCantSync() throws {
        // per-caller decision: live/ring capture chunks, seals and stores keep best-effort directory syncs (a throw there
        // would make the capture retry a chunk it already published, against a journal that may have grown)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-capture-dir-\(UUID().uuidString)")
        let dirs = CaptureDirectories(root: root)
        try dirs.create()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirs.outboxPending.path); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: dirs.outboxPending.path)
        let outbox = Outbox(dirs: dirs)
        _ = try outbox.write(Data("seal".utf8), kind: .seal(captureId: "capture-1"))
        #expect(throws: (any Error).self, "a durable publication says the directory didn't sync") {
            try outbox.write(Data("other".utf8), kind: .seal(captureId: "capture-2"), requireDurable: true)
        }
    }

    @Test func fileErrorsKeepOperationAndErrnoWhereTheBridgeLogsThem() throws {
        // ASTRA-20261118-IT1-02: PhoneWatchBridge logs `localizedDescription`, which said only "DurableFileError error 1"
        let p = try WatchReceiptDurabilityTests().part(index: 7)
        SyncFaults.set(p.inboxDir, failing: true, exactly: true)
        defer { SyncFaults.set(p.inboxDir, failing: false) }
        do {
            try p.inbox.accept(file: p.file, segment: p.segment)
            Issue.record("expected a sync failure")
        } catch {
            let text = error.localizedDescription
            #expect(text.contains("fsync") && text.contains("errno 5"), "\(text)")
            #expect(!text.contains(p.segment.recordingId), "no recording id in the diagnostic: \(text)")
        }
        let io = FileIOError.posix("fsync directory", EACCES)
        #expect(io.localizedDescription.contains("fsync directory") && io.localizedDescription.contains("errno \(EACCES)"))
    }
}
