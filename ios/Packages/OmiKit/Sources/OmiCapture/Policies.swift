import Foundation
import OmiProtocol

// MARK: - Retention

/// Phone retention (architecture decision 18): unacknowledged files are kept forever; acknowledged
/// copies in `sent/` are deleted once the server processed them + 24 h, hard cap 7 days / 1 GB.
public struct RetentionPolicy: Sendable, Equatable {
    public var processedGrace: TimeInterval = 24 * 3600
    public var maxAge: TimeInterval = 7 * 24 * 3600
    public var maxSentBytes: Int64 = 1 << 30

    public init() {}

    public struct SentFile: Sendable, Equatable {
        public var name: String
        public var kind: OutboxKind
        public var size: Int64
        public var sentAt: Date

        public init(name: String, kind: OutboxKind, size: Int64, sentAt: Date) {
            self.name = name
            self.kind = kind
            self.size = size
            self.sentAt = sentAt
        }
    }

    /// Names of `sent/` files to delete. `processedThrough[captureId]` is the server's watermark.
    /// Only `sent/` files are ever passed in, so pending/quarantined files can never be selected.
    public func filesToDelete(sent: [SentFile], processedThrough: [String: Int], now: Date) -> [String] {
        var delete = Set<String>()
        for f in sent {
            let age = now.timeIntervalSince(f.sentAt)
            if age >= maxAge { delete.insert(f.name); continue }
            switch f.kind {
            case .chunk(let cid, let seq):
                if age >= processedGrace, let p = processedThrough[cid], seq <= p { delete.insert(f.name) }
            case .seal, .event:
                if age >= processedGrace { delete.insert(f.name) }
            }
        }
        var remaining = sent.filter { !delete.contains($0.name) }.sorted { $0.sentAt < $1.sentAt }
        var total = remaining.reduce(Int64(0)) { $0 + $1.size }
        while total > maxSentBytes, !remaining.isEmpty {
            let oldest = remaining.removeFirst()
            delete.insert(oldest.name)
            total -= oldest.size
        }
        return sent.map(\.name).filter { delete.contains($0) }
    }

    /// Capture ids whose status is worth fetching (chunks old enough to be deletable if processed).
    public func capturesNeedingStatus(sent: [SentFile], known: [String: Int], now: Date) -> Set<String> {
        var ids = Set<String>()
        for f in sent {
            guard case .chunk(let cid, let seq) = f.kind, now.timeIntervalSince(f.sentAt) >= processedGrace else { continue }
            if let p = known[cid], seq <= p { continue }
            ids.insert(cid)
        }
        return ids
    }
}

// MARK: - Storage guard

/// < 200 MB free → stop journaling, disconnect on purpose (the firmware then buffers to its SD
/// ring), and suppress auto-reconnect until space recovers (with hysteresis).
public struct StorageGuardPolicy: Sendable, Equatable {
    public var tripBelow: Int64 = 200 * 1024 * 1024
    public var recoverAbove: Int64 = 300 * 1024 * 1024

    public init() {}

    public enum Decision: Equatable, Sendable {
        case ok
        case trip        // just crossed below the threshold
        case stayTripped
        case recover     // space is back
    }

    public func evaluate(freeBytes: Int64?, tripped: Bool) -> Decision {
        guard let freeBytes else { return tripped ? .stayTripped : .ok }  // unknown: keep state
        if tripped { return freeBytes >= recoverAbove ? .recover : .stayTripped }
        return freeBytes < tripBelow ? .trip : .ok
    }
}

// MARK: - Ring cursor (per device)

/// Phone-side dedupe state for offline sync: last persisted ring sequence, last INFO write_seq,
/// and a generation counter bumped when sequences go backwards (storage reset / reflash).
public struct RingCursor: Codable, Equatable, Sendable {
    public var generation: Int = 1
    public var lastPersistedSeq: UInt64?
    public var lastWriteSeq: UInt64?
    public init() {}

    /// Applies an INFO snapshot. Returns true if a new generation started.
    @discardableResult
    public mutating func observe(info: RingProtocol.Info) -> Bool {
        var reset = false
        if let lw = lastWriteSeq, info.writeSeq < lw { reset = true }
        // We hold a sequence the device claims it never wrote.
        if let lp = lastPersistedSeq, lp >= info.writeSeq { reset = true }
        if reset {
            generation += 1
            lastPersistedSeq = nil
        }
        lastWriteSeq = info.writeSeq
        return reset
    }

    public func isDuplicate(_ seq: UInt64) -> Bool {
        guard let lp = lastPersistedSeq else { return false }
        return seq <= lp
    }

    public mutating func notePersisted(_ seq: UInt64) {
        if lastPersistedSeq.map({ seq > $0 }) ?? true { lastPersistedSeq = seq }
    }
}

public final class RingCursorStore: @unchecked Sendable {
    private let dir: URL
    private let lock = NSLock()

    public init(stateDir: URL) { dir = stateDir }

    private func url(_ deviceId: String) -> URL { dir.appendingPathComponent("ring-cursor-\(deviceId).json") }

    public func load(_ deviceId: String) -> RingCursor {
        lock.lock(); defer { lock.unlock() }
        return JSONFile.load(RingCursor.self, from: url(deviceId)) ?? RingCursor()
    }

    /// Test seam.
    var faultHook: (() throws -> Void)?

    public func save(_ cursor: RingCursor, deviceId: String) throws {
        lock.lock(); defer { lock.unlock() }
        try faultHook?()
        try JSONFile.save(cursor, to: url(deviceId))
    }

    public func forget(_ deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(deviceId))
    }
}

// MARK: - Per-device memory (last codec)

/// Remembers each device's codec so a capture that ends before the codec read can still be labeled.
public final class DeviceMemory: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var codecs: [String: Int]

    public init(stateDir: URL) {
        url = stateDir.appendingPathComponent("device-codecs.json")
        codecs = JSONFile.load([String: Int].self, from: url) ?? [:]
    }

    public func codec(for deviceId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return codecs[deviceId]
    }

    public func remember(codec: Int, for deviceId: String) {
        lock.lock()
        let changed = codecs[deviceId] != codec
        codecs[deviceId] = codec
        let snapshot = codecs
        lock.unlock()
        if changed { try? JSONFile.save(snapshot, to: url) }
    }
}

// MARK: - Events

/// Writes side events (button, heartbeat) into the outbox.
public struct EventWriter: Sendable {
    public var outbox: Outbox
    public var idGenerator: @Sendable () -> UUID
    public var clock: CaptureClock

    public init(outbox: Outbox, clock: CaptureClock, idGenerator: @escaping @Sendable () -> UUID = { UUID() }) {
        self.outbox = outbox
        self.clock = clock
        self.idGenerator = idGenerator
    }

    @discardableResult
    public func button(code: Int, deviceId: String, captureId: String?, offsetUs: Int64?) throws -> OutboxItem {
        let body = EventBody(
            deviceId: deviceId, at: ISO8601UTC.format(clock.wallNow()), payload: .button(ButtonData(code: code)),
            captureId: captureId, offsetUs: offsetUs)
        return try write(body)
    }

    @discardableResult
    public func heartbeat(deviceId: String, data: HeartbeatData) throws -> OutboxItem {
        try write(EventBody(deviceId: deviceId, at: ISO8601UTC.format(clock.wallNow()), payload: .heartbeat(data)))
    }

    private func write(_ body: EventBody) throws -> OutboxItem {
        let id = idGenerator().uuidString.lowercased()
        return try outbox.write(try ContractJSON.encode(body), kind: .event(eventId: id))
    }
}
