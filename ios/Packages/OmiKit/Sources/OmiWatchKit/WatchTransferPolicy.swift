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

/// While the Watch records, a small `sendMessage` asks the iPhone for checksum receipts about once a minute:
/// Apple documents that this wakes the iPhone app in the background, so acknowledgements arrive within
/// seconds instead of hours. Only while recording, reachable, and something is unacknowledged.
public enum WatchSyncPing {
    public static let interval: TimeInterval = 55
    /// Parts asked about per ping (oldest first).
    public static let batch = 50

    public static func due(now: Date, last: Date?, recording: Bool, reachable: Bool, unacknowledged: Int) -> Bool {
        guard recording, reachable, unacknowledged > 0 else { return false }
        return last.map { now.timeIntervalSince($0) >= interval } ?? true
    }
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
