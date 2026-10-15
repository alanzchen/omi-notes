import Foundation

// Apple Watch performance telemetry (capture-format-v1.md, "Watch performance"): observations the
// Watch makes while recording, relayed by the phone as `watch_perf` events. Nothing here is audio,
// and none of it is tied to a capture's chunk sequence.

/// One observation. `battery` is absent when the Watch didn't report a level (never 0 for unknown).
/// Counters are cumulative since `launch_id` began (an app launch); gauges are current values.
public struct WatchPerfSample: Codable, Equatable, Sendable {
    public var id: String
    /// Watch wall clock, ISO-8601 UTC.
    public var at: String
    /// Monotonic seconds since the recording started (like audio chunk offsets); absent when the
    /// recording began before a reboot.
    public var monoS: Double?
    /// Random id of the Watch's current boot (a new one after a reboot); not the boot time.
    public var bootId: String
    public var launchId: String
    public var recordingId: String?
    /// `start`, `periodic`, `interrupted`, `resumed`, `paused`, `failed`, `stopped`, `recovered`.
    public var event: String
    /// `recording`, `paused` or `idle`.
    public var state: String
    /// 0...1, absent when unknown.
    public var battery: Double?
    /// `unplugged`, `charging`, `full` or `unknown`.
    public var batteryState: String
    public var counters: [String: Int]
    public var gauges: [String: Int]
    /// Watch app version (build), watchOS version, hardware model identifier.
    public var app: String
    public var os: String
    public var model: String

    public init(id: String, at: String, monoS: Double?, bootId: String, launchId: String, recordingId: String?, event: String,
                state: String, battery: Double?, batteryState: String, counters: [String: Int], gauges: [String: Int],
                app: String, os: String, model: String) {
        self.id = id
        self.at = at
        self.monoS = monoS
        self.bootId = bootId
        self.launchId = launchId
        self.recordingId = recordingId
        self.event = event
        self.state = state
        self.battery = battery
        self.batteryState = batteryState
        self.counters = counters
        self.gauges = gauges
        self.app = app
        self.os = os
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case id, at, event, state, battery, counters, gauges, app, os, model
        case monoS = "mono_s", bootId = "boot_id", launchId = "launch_id", recordingId = "recording_id"
        case batteryState = "battery_state"
    }
}

/// `watch_perf` event data: one batch of samples. `dropped_batches`: batches the Watch discarded
/// (its telemetry cap) since the previous batch, so the gap is reported, not hidden.
public struct WatchPerfData: Codable, Equatable, Sendable {
    public var schema: Int
    public var batchId: String
    public var samples: [WatchPerfSample]
    public var droppedBatches: Int

    public init(batchId: String, samples: [WatchPerfSample], droppedBatches: Int, schema: Int = 1) {
        self.schema = schema
        self.batchId = batchId
        self.samples = samples
        self.droppedBatches = droppedBatches
    }

    enum CodingKeys: String, CodingKey {
        case schema, samples
        case batchId = "batch_id", droppedBatches = "dropped_batches"
    }
}

/// `GET /v1/watch/performance`: per-recording summaries computed by the server (servers with
/// `watch_performance`). Only the fields the app shows are decoded.
public struct WatchPerformance: Decodable, Equatable, Sendable {
    public struct Session: Decodable, Equatable, Sendable, Identifiable {
        public var recordingId: String
        public var startedAt: String?
        public var lastAt: String?
        public var complete: Bool
        public var batteryStart: Double?
        public var batteryEnd: Double?
        public var measuredS: Double
        public var ratePerHour: Double?
        /// `ok`, `coarse` (small change) or `insufficient`.
        public var rateQuality: String
        public var gaps: Int
        public var chargingS: Double
        public var builds: [String]
        public var id: String { recordingId }

        enum CodingKeys: String, CodingKey {
            case complete, gaps, builds
            case recordingId = "recording_id", startedAt = "started_at", lastAt = "last_at"
            case batteryStart = "battery_start", batteryEnd = "battery_end", measuredS = "measured_s"
            case ratePerHour = "rate_pp_per_hour", rateQuality = "rate_quality", chargingS = "charging_s"
        }
    }

    public var sessions: [Session]
}
