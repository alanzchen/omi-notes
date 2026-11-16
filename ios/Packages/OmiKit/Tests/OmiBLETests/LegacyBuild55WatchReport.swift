import Foundation
struct LegacyBuild55WatchReport: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case recording, paused, idle }
    public var state: State
    /// When the current recording started (recording or paused).
    public var since: Date?
    /// Audio parts on the Watch the phone hasn't acknowledged yet, and their recorded length in
    /// seconds (absent from older Watch apps).
    public var waitingParts: Int
    public var waitingSeconds: Int?
    /// The Watch's device id (as in its chunks and samples); absent from older Watch apps.
    public var deviceId: String?
    public var at: Date
    /// Counters since the Watch app launched (transfers, resends, capture buffer allocations…), to
    /// compare builds; absent from older Watch apps.
    public var stats: [String: Int]?
    /// Audio parts kept on the Watch that it can't send (no manifest matches them; `orphan_parts`).
    /// nil when the report doesn't say (older Watch apps): unknown, never taken as none.
    public var keptParts: Int? { stats?["orphan_parts"] }
    /// Of the waiting parts, those being re-checked: audio an older iPhone build already converted, which
    /// the Watch sends again after any new audio (`recheck_parts`, `recheck_s`; absent from older Watch apps).
    public var recheckParts: Int { stats?["recheck_parts"] ?? 0 }
    public var recheckSeconds: Int { stats?["recheck_s"] ?? 0 }

    public init(state: State, since: Date?, waitingParts: Int, waitingSeconds: Int? = nil, at: Date, deviceId: String? = nil,
                stats: [String: Int]? = nil) {
        self.deviceId = deviceId
        self.state = state
        self.since = since
        self.waitingParts = waitingParts
        self.waitingSeconds = waitingSeconds
        self.at = at
        self.stats = stats
    }
}

