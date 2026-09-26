import Foundation
import OmiProtocol

/// Decides whether an outbox item may be uploaded yet (dependency ordering).
public protocol UploadGate: AnyObject {
    func mayUpload(_ item: OutboxItem) -> Bool
    func didAcknowledge(_ item: OutboxItem)
    /// Human-readable reason an item is held, if it is.
    func heldReason(_ item: OutboxItem) -> String?
}

/// Ordered record of ring captures per device. A ring capture's `sync_complete` seal resolves
/// coverage on the server, so it is **held** until every earlier ring capture of the same device
/// and generation is fully acknowledged (all its chunks and its own seal answered 2xx). Otherwise
/// an interrupted capture A still in the outbox could be overtaken by a later, possibly empty,
/// `sync_complete` capture B, and conversations would finalize before A's audio arrives.
///
/// Entries are registered before a ring capture's journal is created and pruned once acknowledged.
public final class RingCaptureLedger: UploadGate, @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var captureId: String
        public var deviceId: String
        public var generation: Int
        public var order: Int
    }

    private struct Stored: Codable {
        var entries: [Entry]
        var nextOrder: Int
    }

    private let url: URL
    private let dirs: CaptureDirectories
    private let outbox: Outbox
    private let lock = NSLock()
    private var entries: [Entry]
    private var nextOrder: Int

    public init(dirs: CaptureDirectories, outbox: Outbox) {
        self.dirs = dirs
        self.outbox = outbox
        url = dirs.state.appendingPathComponent("ring-ledger.json")
        let stored = JSONFile.load(Stored.self, from: url)
        entries = stored?.entries ?? []
        nextOrder = stored?.nextOrder ?? 1
    }

    public var snapshot: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func register(captureId: String, deviceId: String, generation: Int) throws {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(captureId: captureId, deviceId: deviceId, generation: generation, order: nextOrder))
        nextOrder += 1
        do {
            try persistLocked()
        } catch {
            entries.removeAll { $0.captureId == captureId }
            throw error
        }
    }

    public func unregister(captureId: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.captureId == captureId }
        try? persistLocked()
    }

    /// All chunks and the seal answered 2xx (the seal may since have been deleted by retention).
    public func isFullyAcknowledged(_ captureId: String) -> Bool {
        let journalDirs = FileIO.contents(of: dirs.journalRing) + FileIO.contents(of: dirs.journalQuarantine)
        if journalDirs.contains(where: { $0.lastPathComponent.hasPrefix(captureId) }) { return false }
        if !outbox.unacknowledged(captureId: captureId).isEmpty { return false }
        let seal = OutboxKind.seal(captureId: captureId)
        return outbox.isAcknowledged(seal) || outbox.locate(seal) == nil
    }

    /// Earlier captures (same device + generation) not yet fully acknowledged.
    public func blockers(of captureId: String) -> [String] {
        lock.lock()
        let all = entries
        lock.unlock()
        guard let e = all.first(where: { $0.captureId == captureId }) else { return [] }
        return all
            .filter { $0.deviceId == e.deviceId && $0.generation == e.generation && $0.order < e.order }
            .map(\.captureId)
            .filter { !isFullyAcknowledged($0) }
    }

    /// Removes acknowledged entries. Returns the ids removed.
    @discardableResult
    public func prune() -> [String] {
        lock.lock()
        let all = entries
        lock.unlock()
        let done = all.filter { isFullyAcknowledged($0.captureId) }.map(\.captureId)
        guard !done.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { done.contains($0.captureId) }
        try? persistLocked()
        return done
    }

    // MARK: UploadGate

    public func mayUpload(_ item: OutboxItem) -> Bool { heldReason(item) == nil }

    public func heldReason(_ item: OutboxItem) -> String? {
        guard case .seal(let cid) = item.kind, isRingSyncComplete(item) else { return nil }
        let b = blockers(of: cid)
        return b.isEmpty ? nil : "sync_complete seal waits for earlier ring capture(s) \(b.joined(separator: ", "))"
    }

    public func didAcknowledge(_ item: OutboxItem) {
        if item.kind.captureId != nil { prune() }
    }

    private func isRingSyncComplete(_ item: OutboxItem) -> Bool {
        guard let data = try? Data(contentsOf: item.url), let seal = try? JSONDecoder().decode(SealBody.self, from: data) else {
            return false
        }
        return seal.source == .deviceRing && seal.reason == .syncComplete
    }

    private func persistLocked() throws {
        try JSONFile.save(Stored(entries: entries, nextOrder: nextOrder), to: url)
    }
}
