import Foundation
import OmiProtocol

public enum OutboxKind: Sendable, Equatable, Hashable {
    case chunk(captureId: String, sequence: Int)
    case seal(captureId: String)
    case event(eventId: String)

    /// File name, which is also the upload identity (`taskDescription`).
    public var fileName: String {
        switch self {
        case .chunk(let c, let s): return "chunk_\(c)_\(String(format: "%06d", s)).omnc"
        case .seal(let c): return "seal_\(c).json"
        case .event(let e): return "event_\(e).json"
        }
    }

    public static func parse(_ name: String) -> OutboxKind? {
        if name.hasPrefix("chunk_"), name.hasSuffix(".omnc") {
            let core = name.dropFirst(6).dropLast(5)
            guard let us = core.lastIndex(of: "_") else { return nil }
            let cid = String(core[core.startIndex..<us])
            guard let seq = Int(core[core.index(after: us)...]), !cid.isEmpty else { return nil }
            return .chunk(captureId: cid, sequence: seq)
        }
        if name.hasPrefix("seal_"), name.hasSuffix(".json") {
            let cid = String(name.dropFirst(5).dropLast(5))
            return cid.isEmpty ? nil : .seal(captureId: cid)
        }
        if name.hasPrefix("event_"), name.hasSuffix(".json") {
            let eid = String(name.dropFirst(6).dropLast(5))
            return eid.isEmpty ? nil : .event(eventId: eid)
        }
        return nil
    }

    /// HTTP path for `PUT`.
    public var path: String {
        switch self {
        case .chunk(let c, let s): return "/v1/captures/\(c)/chunks/\(s)"
        case .seal(let c): return "/v1/captures/\(c)/seal"
        case .event(let e): return "/v1/events/\(e)"
        }
    }

    public var contentType: String {
        if case .chunk = self { return "application/octet-stream" }
        return "application/json"
    }

    public var isChunk: Bool { if case .chunk = self { return true } else { return false } }

    public var captureId: String? {
        switch self {
        case .chunk(let c, _), .seal(let c): return c
        case .event: return nil
        }
    }
}

public struct OutboxItem: Sendable, Equatable {
    public let kind: OutboxKind
    public let url: URL
    public let size: Int64
    public let modified: Date
    public var name: String { kind.fileName }
}

public enum OutboxError: Error, Equatable, CustomStringConvertible {
    case identityConflict(String)
    public var description: String {
        switch self {
        case .identityConflict(let n): return "outbox identity \(n) already exists with different content"
        }
    }
}

public struct OutboxStats: Sendable, Equatable {
    public var pendingCount = 0
    public var pendingChunks = 0
    public var pendingBytes: Int64 = 0
    public var sentCount = 0
    public var sentBytes: Int64 = 0
    public var quarantineCount = 0
    public init() {}
}

/// Durable upload queue. `pending/` is the source of truth; `sent/` holds acknowledged copies until
/// retention deletes them; `quarantine/` holds files that must be kept but not retried.
public final class Outbox: @unchecked Sendable {
    public let dirs: CaptureDirectories
    private let lock = NSLock()

    public init(dirs: CaptureDirectories) { self.dirs = dirs }

    /// Writes atomically into `pending/`. An identity is immutable once published: if a file with
    /// the same name exists anywhere (pending, sent, quarantine), identical bytes are a no-op and
    /// different (or unreadable) bytes throw `OutboxError.identityConflict` — never an overwrite.
    @discardableResult
    public func write(_ data: Data, kind: OutboxKind) throws -> OutboxItem {
        lock.lock(); defer { lock.unlock() }
        let name = kind.fileName
        for dir in [dirs.outboxPending, dirs.outboxSent, dirs.outboxQuarantine] {
            let existing = dir.appendingPathComponent(name)
            guard FileIO.exists(existing) else { continue }
            if let bytes = try? Data(contentsOf: existing), bytes == data {
                return OutboxItem(kind: kind, url: existing, size: Int64(data.count), modified: FileIO.modificationDate(existing))
            }
            throw OutboxError.identityConflict(name)
        }
        let url = dirs.outboxPending.appendingPathComponent(name)
        try FileIO.atomicWrite(data, to: url)
        return OutboxItem(kind: kind, url: url, size: Int64(data.count), modified: Date())
    }

    /// Location of an item in any directory (pending first).
    public func locate(_ kind: OutboxKind) -> URL? {
        [dirs.outboxPending, dirs.outboxSent, dirs.outboxQuarantine]
            .map { $0.appendingPathComponent(kind.fileName) }
            .first { FileIO.exists($0) }
    }

    /// Files (any kind) of a capture that are still waiting (pending) or kept unuploaded (quarantine).
    public func unacknowledged(captureId: String) -> [OutboxItem] {
        (pending() + quarantined()).filter { $0.kind.captureId == captureId }
    }

    public func isAcknowledged(_ kind: OutboxKind) -> Bool {
        FileIO.exists(dirs.outboxSent.appendingPathComponent(kind.fileName))
    }

    public func pending() -> [OutboxItem] { list(dirs.outboxPending) }
    public func sent() -> [OutboxItem] { list(dirs.outboxSent) }
    public func quarantined() -> [OutboxItem] { list(dirs.outboxQuarantine) }

    public func pendingItem(named name: String) -> OutboxItem? {
        let url = dirs.outboxPending.appendingPathComponent(name)
        guard let kind = OutboxKind.parse(name), FileIO.exists(url) else { return nil }
        return OutboxItem(kind: kind, url: url, size: FileIO.fileSize(url), modified: FileIO.modificationDate(url))
    }

    /// True if the item exists in any of the three directories.
    public func contains(_ kind: OutboxKind) -> Bool {
        let n = kind.fileName
        return [dirs.outboxPending, dirs.outboxSent, dirs.outboxQuarantine]
            .contains { FileIO.exists($0.appendingPathComponent(n)) }
    }

    /// pending → sent, stamping the time of acknowledgement as the modification date.
    public func markSent(_ name: String, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        let src = dirs.outboxPending.appendingPathComponent(name)
        let dst = dirs.outboxSent.appendingPathComponent(name)
        guard FileIO.exists(src) else { return }
        if FileIO.exists(dst) { try? FileManager.default.removeItem(at: dst) }
        try FileManager.default.moveItem(at: src, to: dst)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dst.path)
    }

    /// pending → quarantine with a `.reason` sidecar.
    public func quarantine(_ name: String, reason: String) throws {
        lock.lock(); defer { lock.unlock() }
        let src = dirs.outboxPending.appendingPathComponent(name)
        let dst = dirs.outboxQuarantine.appendingPathComponent(name)
        guard FileIO.exists(src) else { return }
        if FileIO.exists(dst) { try? FileManager.default.removeItem(at: dst) }
        try FileManager.default.moveItem(at: src, to: dst)
        try? Data(reason.utf8).write(to: dst.appendingPathExtension("reason"))
    }

    public func quarantineReason(_ name: String) -> String? {
        let url = dirs.outboxQuarantine.appendingPathComponent(name).appendingPathExtension("reason")
        return (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Debug: move a quarantined file back to pending for another attempt.
    public func requeueQuarantined(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        let src = dirs.outboxQuarantine.appendingPathComponent(name)
        guard FileIO.exists(src) else { return }
        try FileManager.default.moveItem(at: src, to: dirs.outboxPending.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: src.appendingPathExtension("reason"))
    }

    /// Only ever called by retention on `sent/` files.
    public func deleteSent(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: dirs.outboxSent.appendingPathComponent(name))
    }

    public func stats() -> OutboxStats {
        var s = OutboxStats()
        for item in pending() {
            s.pendingCount += 1
            s.pendingBytes += item.size
            if item.kind.isChunk { s.pendingChunks += 1 }
        }
        for item in sent() {
            s.sentCount += 1
            s.sentBytes += item.size
        }
        s.quarantineCount = quarantined().count
        return s
    }

    private func list(_ dir: URL) -> [OutboxItem] {
        FileIO.contents(of: dir).compactMap { url in
            guard let kind = OutboxKind.parse(url.lastPathComponent) else { return nil }
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return OutboxItem(
                kind: kind, url: url, size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast)
        }
        .sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }
    }
}
