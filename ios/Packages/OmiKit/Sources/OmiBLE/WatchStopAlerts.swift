import Foundation
import OmiProtocol

/// One iPhone notification when an Apple Watch recording stops without the wearer stopping it, from
/// the Watch's own timestamped samples (which arrive late, twice or out of order). Never from a
/// lost connection or an old status alone.
///
/// - Unexpected: `interrupted` (a call or Siri, not resumed by the system), `failed` (a capture
///   error), `paused` (storage) and `recovered` (the app was closed during a recording). A user's
///   Stop (`stopped`) never alerts.
/// - An interruption waits `grace` before alerting: most resume by themselves. A later sample of
///   that recording that shows it going again, or ended by the wearer, cancels it (and withdraws an
///   alert already shown); so does a newer recording on the same Watch.
/// - Each recording alerts at most once per stop (sample id remembered across launches); an event
///   older than `maxAge` when it arrives is not alerted at all.
public final class WatchStopAlerts: @unchecked Sendable {
    public struct Alert: Equatable, Sendable {
        public var identifier: String
        public var title: String
        public var body: String
        public var fireAt: Date
    }

    public enum Decision: Equatable, Sendable {
        case schedule(Alert)
        case withdraw(identifier: String)
    }

    public static let grace: TimeInterval = 120
    public static let maxAge: TimeInterval = 24 * 3600
    static let unexpected: Set<String> = ["interrupted", "failed", "paused", "recovered"]
    static let going: Set<String> = ["start", "resumed", "periodic"]

    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let stateKey = "omi.watchStopAlerts"
    private static let reportKey = "omi.watchStopAlerts.recordingReports"
    /// Reports without a device (older Watch apps) apply to every Watch.
    static let anyDevice = "*"

    /// Per recording: its latest sample seen (time, event), and the stop sample already alerted.
    struct Recording: Codable, Equatable {
        var device: String
        var at: Date
        var event: String
        var sampleId: String
        var alerted: String?
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Per Watch: the latest time its status report said it was recording. A stop from before then
    /// is already over, whichever arrives first.
    private var recordingReports: [String: Date] {
        get { (defaults.dictionary(forKey: Self.reportKey) as? [String: Date]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.reportKey) }
    }

    private func recordingKnownAfter(_ at: Date, device: String) -> Bool {
        let reports = recordingReports
        return [device, Self.anyDevice].contains { (reports[$0] ?? .distantPast) > at }
    }

    private var recordings: [String: Recording] {
        get { (defaults.data(forKey: Self.stateKey)).flatMap { try? JSONDecoder().decode([String: Recording].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.stateKey) }
    }

    static func identifier(_ recordingId: String) -> String { "omi.watch-stop.\(recordingId)" }

    /// Feed every sample batch the phone accepts; returns what to schedule or withdraw.
    public func process(deviceId: String, samples: [WatchPerfSample], now: Date) -> [Decision] {
        lock.lock(); defer { lock.unlock() }
        var all = recordings
        var touched: Set<String> = []
        for s in samples {
            // `opened` says nothing about whether the recording is going (the app was just opened)
            guard let rid = s.recordingId, let at = Self.date(s.at), s.event != "opened" else { continue }
            if let known = all[rid], known.at > at || (known.at == at && known.sampleId >= s.id) { continue }  // older or the same
            all[rid] = Recording(device: deviceId, at: at, event: s.event, sampleId: s.id, alerted: all[rid]?.alerted)
            touched.insert(rid)
        }
        var out: [Decision] = []
        for rid in touched.sorted() {
            guard var r = all[rid] else { continue }
            let newer = all.contains { $0.key != rid && $0.value.device == r.device && $0.value.at > r.at && Self.going.contains($0.value.event) }
            if Self.unexpected.contains(r.event) && !newer && !recordingKnownAfter(r.at, device: r.device) {
                guard r.alerted != r.sampleId, now.timeIntervalSince(r.at) < Self.maxAge else { continue }
                r.alerted = r.sampleId
                all[rid] = r
                let fire = r.event == "interrupted" ? max(now, r.at.addingTimeInterval(Self.grace)) : now
                out.append(.schedule(Self.alert(rid, r.event, at: r.at, fireAt: fire)))
            } else if r.alerted != nil {
                // going again, ended by the wearer, or superseded: the alert no longer describes now
                r.alerted = nil
                all[rid] = r
                out.append(.withdraw(identifier: Self.identifier(rid)))
            }
        }
        // a newer recording supersedes alerts about older ones on the same Watch
        for (rid, r) in all where r.alerted != nil && !touched.contains(rid) {
            if all.contains(where: { $0.value.device == r.device && $0.value.at > r.at && Self.going.contains($0.value.event) }) {
                all[rid]?.alerted = nil
                out.append(.withdraw(identifier: Self.identifier(rid)))
            }
        }
        // bounded: forget recordings older than two days
        recordings = all.filter { now.timeIntervalSince($0.value.at) < 2 * 86400 }
        return out
    }

    /// The Watch's latest status report says it is recording (as of `at`): alerts about stops
    /// before then no longer describe now.
    public func recording(asOf at: Date, deviceId: String? = nil) -> [Decision] {
        lock.lock(); defer { lock.unlock() }
        let key = deviceId ?? Self.anyDevice
        var reports = recordingReports
        reports[key] = max(reports[key] ?? .distantPast, at)
        recordingReports = reports
        var all = recordings, out: [Decision] = []
        for (rid, r) in all where r.alerted != nil && r.at < at && (deviceId == nil || r.device == deviceId) {
            all[rid]?.alerted = nil
            out.append(.withdraw(identifier: Self.identifier(rid)))
        }
        recordings = all
        return out
    }

    static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    static func alert(_ rid: String, _ event: String, at: Date, fireAt: Date) -> Alert {
        let time = at.formatted(date: .omitted, time: .shortened)
        let title: String, body: String
        switch event {
        case "interrupted":
            title = "Apple Watch recording paused"
            body = "Paused at \(time) by a call or another app. Open Omi Notes on your Watch and tap Resume."
        case "paused":
            title = "Apple Watch recording paused"
            body = "Paused at \(time). Open Omi Notes on your Watch to see why and resume."
        case "recovered":
            title = "Apple Watch recording stopped"
            body = "Omi Notes on your Watch closed during a recording (found at \(time)). What was recorded is kept; open it to record again."
        default:
            title = "Apple Watch recording stopped"
            body = "Stopped at \(time) by an error. What was recorded is kept; open Omi Notes on your Watch to start again."
        }
        return Alert(identifier: identifier(rid), title: title, body: body, fireAt: fireAt)
    }
}

/// Posts Watch stop alerts as local notifications (the app implements it).
public protocol WatchStopAlertSink: AnyObject, Sendable {
    func schedule(_ alert: WatchStopAlerts.Alert)
    func withdraw(identifier: String)
}
