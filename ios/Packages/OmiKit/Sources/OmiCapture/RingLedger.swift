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
        /// Persisted so degraded mode survives relaunches: once the ledger is rewritten after a read
        /// failure it holds only newer captures, and older ones remain unordered until acknowledged.
        var degraded: Bool?
    }

    private let url: URL
    private let dirs: CaptureDirectories
    private let outbox: Outbox
    private let lock = NSLock()
    private var entries: [Entry]
    private var nextOrder: Int
    /// The ledger file exists but could not be read or decoded, so the order of older ring captures
    /// is unknown. Fail closed: hold `sync_complete` seals while any other unacknowledged ring audio
    /// of the device is on the phone (see `degradedBlockers`). Cleared once none is left.
    public private(set) var degraded = false

    public init(dirs: CaptureDirectories, outbox: Outbox) {
        self.dirs = dirs
        self.outbox = outbox
        url = dirs.state.appendingPathComponent("ring-ledger.json")
        entries = []
        nextOrder = 1
        guard FileIO.exists(url) else { return }  // fresh install: nothing to order
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))
            entries = stored.entries
            nextOrder = stored.nextOrder
            degraded = stored.degraded ?? false
        } catch {
            degraded = true
            log(.error, "ring", "ring ledger unreadable (\(error)); holding sync_complete seals until older ring audio is acknowledged")
        }
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
        guard case .seal(let cid) = item.kind, let seal = ringSyncCompleteSeal(item) else { return nil }
        if degraded {
            let b = degradedBlockers(of: cid, deviceId: seal.deviceId, sealDate: item.modified)
            if b.isEmpty {
                return nil
            }
            return "ring ledger unreadable: sync_complete seal waits for other ring capture(s) \(b.joined(separator: ", "))"
        }
        let b = blockers(of: cid)
        return b.isEmpty ? nil : "sync_complete seal waits for earlier ring capture(s) \(b.joined(separator: ", "))"
    }

    /// Fail-closed ordering when the ledger is unreadable: every other ring capture of the device
    /// (or of an unknown device) with unacknowledged artifacts on the phone blocks. Captures whose
    /// only outstanding artifact is their own held `sync_complete` seal are ordered by seal file age,
    /// so two held seals can never wait on each other.
    func degradedBlockers(of captureId: String, deviceId: String, sealDate: Date) -> [String] {
        var blockers: [String] = []
        for (other, info) in unacknowledgedRingCaptures() where other != captureId {
            if let d = info.deviceId, d != deviceId { continue }
            if info.onlyHeldSeal, let otherSeal = info.sealDate, otherSeal > sealDate { continue }
            blockers.append(other)
        }
        return blockers.sorted()
    }

    private struct RingArtifacts {
        var deviceId: String?
        var onlyHeldSeal = true
        var sealDate: Date?
    }

    /// Ring captures with anything on the phone that the server hasn't acknowledged: journal or
    /// quarantined directories, and pending or quarantined outbox chunks and seals.
    private func unacknowledgedRingCaptures() -> [String: RingArtifacts] {
        var found: [String: RingArtifacts] = [:]
        for dir in FileIO.contents(of: dirs.journalRing) + FileIO.contents(of: dirs.journalQuarantine) where dir.hasDirectoryPath {
            let m = JSONFile.load(CaptureManifest.self, from: dir.appendingPathComponent(CaptureManifest.fileName))
            if let m, m.source != .deviceRing { continue }
            let id = m?.captureId ?? dir.lastPathComponent
            found[id, default: RingArtifacts()].deviceId = m?.deviceId
            found[id]?.onlyHeldSeal = false
        }
        for item in outbox.pending() + outbox.quarantined() {
            guard let id = item.kind.captureId, let data = try? Data(contentsOf: item.url) else { continue }
            switch item.kind {
            case .seal:
                guard let seal = try? JSONDecoder().decode(SealBody.self, from: data), seal.source == .deviceRing else { continue }
                found[id, default: RingArtifacts()].deviceId = seal.deviceId
                if seal.reason == .syncComplete { found[id]?.sealDate = item.modified } else { found[id]?.onlyHeldSeal = false }
            default:
                guard let env = try? Envelope.parse(data), env.header.source == .deviceRing else { continue }
                found[id, default: RingArtifacts()].deviceId = env.header.deviceId
                found[id]?.onlyHeldSeal = false
            }
        }
        return found
    }

    public func didAcknowledge(_ item: OutboxItem) {
        guard item.kind.captureId != nil else { return }
        prune()
        if degraded, unacknowledgedRingCaptures().isEmpty {
            // Everything older has been acknowledged: the ledger is complete again.
            lock.lock(); defer { lock.unlock() }
            degraded = false
            if (try? persistLocked()) != nil {
                log(.info, "ring", "ring ledger rebuilt; normal seal ordering resumed")
            } else {
                degraded = true
            }
        }
    }

    private func ringSyncCompleteSeal(_ item: OutboxItem) -> SealBody? {
        guard let data = try? Data(contentsOf: item.url), let seal = try? JSONDecoder().decode(SealBody.self, from: data),
              seal.source == .deviceRing, seal.reason == .syncComplete else { return nil }
        return seal
    }

    private func persistLocked() throws {
        try JSONFile.save(Stored(entries: entries, nextOrder: nextOrder, degraded: degraded ? true : nil), to: url)
    }
}
