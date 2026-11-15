import Foundation

/// How many more files the Watch may hand to WatchConnectivity now. Only transfers that are moving count
/// against the window (watch_perf showed `outstanding_files` pinned at 4 for hours: queued transfers that
/// only progress when an app runs would otherwise hold every slot); all outstanding ones, moving or not,
/// are bounded at twice the window so a stalled link never queues the whole backlog.
public enum WatchTransferWindow {
    public static func room(maxInFlight: Int, transferring: Int, outstanding: Int) -> Int {
        max(0, min(maxInFlight - transferring, 2 * maxInFlight - outstanding))
    }
}

/// Which outstanding transfers are actually moving. `isTransferring` alone isn't progress: a transfer it
/// reports for minutes without a byte sent is stalled, and stops holding a window slot (the twice-the-window
/// bound on everything outstanding still applies). A transfer stalled for `cancelAfter` is handed back (`overdue`):
/// the Watch cancels it and sends the part again. Its file stays in the Watch's outbox until a receipt retires it
/// (2026-11-15: three transfers stalled with no progress for four days were never cancelled, so never resent).
public struct WatchTransferStalls: Codable, Sendable {
    /// No progress for this long: stalled.
    public static let stallAfter: TimeInterval = 3 * 60
    /// Stalled this long: cancelled and sent again (the part itself stays until a receipt).
    public static let cancelAfter: TimeInterval = 30 * 60

    public struct Observation: Sendable {
        public var id: String
        public var transferring: Bool
        public var completedBytes: Int64
        public init(id: String, transferring: Bool, completedBytes: Int64) {
            self.id = id
            self.transferring = transferring
            self.completedBytes = completedBytes
        }
    }

    public struct Counts: Equatable, Sendable {
        public var moving = 0, stalled = 0, queued = 0
        public init(moving: Int = 0, stalled: Int = 0, queued: Int = 0) {
            self.moving = moving
            self.stalled = stalled
            self.queued = queued
        }
    }

    /// A transfer attempt's bytes when last seen changing, and when (saved: a relaunch keeps its age,
    /// ASTRA-20261115-IT1-04).
    public struct Progress: Codable, Equatable, Sendable {
        public var bytes: Int64
        public var at: Date
    }

    /// Keyed by transfer attempt (the part id and its attempt number), never the part id alone: a replacement starts
    /// its own clock (ASTRA-20261115-IT1-02). Only attempts outstanding at the last observation are kept.
    private var progress: [String: Progress] = [:]
    /// Transfers seen transferring without progress, as of the last observation.
    private var stalledIds: Set<String> = []

    public init() {}

    /// A saved tracker (nil, unreadable: a new one). A last-progress time in the future (a clock that moved back) is
    /// taken as now: such an attempt waits its full time again rather than being cancelled early.
    public init(restoring data: Data?, now: Date) {
        guard let data, let saved = try? JSONDecoder().decode(Self.self, from: data) else { return }
        progress = saved.progress.mapValues { $0.at > now ? Progress(bytes: $0.bytes, at: now) : $0 }
    }

    public var saved: Data? { try? JSONEncoder().encode(self) }

    enum CodingKeys: String, CodingKey { case progress }

    /// Records what WatchConnectivity reports now and counts moving, stalled and queued transfers.
    public mutating func observe(_ transfers: [Observation], now: Date) -> Counts {
        var counts = Counts(), seen: [String: Progress] = [:]
        stalledIds = []
        for t in transfers {
            var entry = Progress(bytes: t.completedBytes, at: now)
            if let last = progress[t.id], last.bytes == t.completedBytes { entry = last }
            seen[t.id] = entry
            if !t.transferring { counts.queued += 1 }
            else if now.timeIntervalSince(entry.at) < Self.stallAfter { counts.moving += 1 }
            else { counts.stalled += 1; stalledIds.insert(t.id) }
        }
        progress = seen  // finished transfers are forgotten
        return counts
    }

    /// Transfers stalled (transferring, no progress) for at least `cancelAfter` as of the last observation: to be
    /// cancelled and sent again.
    public func overdue(now: Date) -> Set<String> {
        stalledIds.filter { id in progress[id].map { now.timeIntervalSince($0.at) >= Self.cancelAfter } ?? false }
    }
}

/// A small `sendMessage` asks the iPhone for checksum receipts about once a minute while parts wait:
/// Apple documents that this wakes the iPhone app in the background, so acknowledgements arrive within
/// seconds instead of hours. Only while reachable and some part is waiting (delivered or not: the phone
/// answers only with receipts it can verify).
public enum WatchSyncPing {
    public static let interval: TimeInterval = 55
    /// Parts asked about per ping (oldest first).
    public static let batch = 50

    public static func due(now: Date, last: Date?, reachable: Bool, waitingParts: Int) -> Bool {
        guard reachable, waitingParts > 0 else { return false }
        return last.map { now.timeIntervalSince($0) >= interval } ?? true
    }
}

/// App-side work a WatchConnectivity callback queued (a main-actor task) but hasn't finished. A background
/// wake waits for it as well as `hasContentPending`: the session can report nothing pending while what it
/// delivered is still waiting for the main actor.
public final class WatchCallbackWork: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0

    public init() {}

    public func begin() { lock.withLock { running += 1 } }
    public func end() { lock.withLock { running = max(0, running - 1) } }
    public var isIdle: Bool { lock.withLock { running == 0 } }
}

/// Handover → checksum receipt latency, for telemetry: the last `capacity` values (seconds).
public struct WatchAckLatency: Sendable {
    public private(set) var values: [Double] = []
    public let capacity: Int

    public init(capacity: Int = 100) { self.capacity = capacity }

    public mutating func add(_ seconds: Double) {
        values.append(max(0, seconds))
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    /// Whole seconds at quantile `q` (0…1), nil without values.
    public func quantile(_ q: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return Int(sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))].rounded())
    }
}
