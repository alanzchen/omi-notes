import Foundation

/// What the phone has actually sent to the server while the app is open, from the upload tasks' own
/// progress callbacks (`didSendBodyData`). Times are monotonic nanoseconds.
///
/// - Counting starts at `start` (the app becoming active) and stops at `suspend`: in the background
///   nothing is live, and the counters describe only this window.
/// - Uploads are keyed by their full task identity (`"<generation>.<epoch>|<file>"`). An attempt the
///   uploader `began` starts from 0, so its first report counts in full. An upload adopted from
///   before (a relaunch, or one that ran while the app was in the background) has no known baseline
///   until its first report in this window: what it sent before that is never claimed.
/// - A report lower than the last one starts a new baseline, so a delta is never negative; later
///   bytes of a retry are real network bytes.
/// - Delivered = the server acknowledged the file; each file counts once. Audio (chunks) and other
///   files (events, seals) are counted apart. A failed attempt is either retried automatically or
///   held (kept on this iPhone for a person to look at).
public struct TransferMeter: Equatable, Sendable {
    public enum Outcome: Sendable { case delivered, retrying, held, cancelled }

    /// The rate is the bytes reported over this window (or since `start`, if shorter)...
    public static let rateWindow: UInt64 = 5_000_000_000
    /// ...and none at all when nothing was reported for this long.
    public static let idleAfter: UInt64 = 3_000_000_000

    struct Upload: Equatable, Sendable {
        /// Last reported bytes of this attempt; nil = no baseline in this window yet.
        var sent: Int64?
        var expected: Int64?
        var audio: Bool
        /// Seen (begun or reported) while counting, with no suspension since: its baseline holds.
        var current = false
    }

    struct Sample: Equatable, Sendable {
        var at: UInt64
        var bytes: Int64
    }

    /// When counting started (wall clock, for "since 3:04 PM"); nil while not counting.
    public private(set) var since: Date?
    private var sinceMono: UInt64 = 0
    private var uploads: [String: Upload] = [:]
    private var samples: [Sample] = []
    private var lastReportMono: UInt64?
    private var delivered: Set<String> = []

    /// Every byte the upload tasks reported sending in this window (audio, metadata and retries).
    public private(set) var networkBytes: Int64 = 0
    public private(set) var deliveredAudioFiles = 0
    public private(set) var deliveredAudioBytes: Int64 = 0
    public private(set) var deliveredOtherFiles = 0
    /// Failed attempts that will be tried again automatically.
    public private(set) var retryingAttempts = 0
    /// Failed attempts whose file is now held (kept aside or uploads paused).
    public private(set) var heldAttempts = 0

    public init() {}

    public mutating func start(atMono: UInt64, wall: Date) {
        since = wall
        sinceMono = atMono
        samples = []
        lastReportMono = nil
        delivered = []
        networkBytes = 0
        deliveredAudioFiles = 0
        deliveredAudioBytes = 0
        deliveredOtherFiles = 0
        retryingAttempts = 0
        heldAttempts = 0
        // an upload last seen while not counting (before activation, or across a suspension) may have
        // sent bytes nobody reported: its next report becomes its baseline
        for (id, u) in uploads where !u.current { uploads[id]?.sent = nil }
    }

    /// The uploader started a new attempt: it begins at 0 bytes.
    public mutating func began(id: String, audio: Bool, expected: Int64?) {
        uploads[id] = Upload(sent: 0, expected: expected.flatMap { $0 > 0 ? $0 : nil }, audio: audio, current: since != nil)
    }

    /// Drops uploads of any other configuration or epoch (their callbacks no longer count).
    public mutating func retain(key: String) {
        uploads = uploads.filter { $0.key.split(separator: "|", maxSplits: 1).first.map(String.init) == key }
    }

    public mutating func suspend() {
        for id in uploads.keys { uploads[id]?.current = false }  // they keep running unobserved
        since = nil
        samples = []
        lastReportMono = nil
    }

    public mutating func progress(id name: String, audio: Bool, sent: Int64, expected: Int64?, atMono: UInt64) {
        let total = expected.flatMap { $0 > 0 ? $0 : nil }
        let previous = uploads[name]
        uploads[name] = Upload(sent: sent, expected: total ?? previous?.expected, audio: audio, current: since != nil)
        guard since != nil, let base = previous?.sent else { return }  // no baseline yet: this report becomes it
        let delta = sent - base
        guard delta > 0 else { return }  // a restarted attempt: its new baseline, never negative
        networkBytes += delta
        samples.append(Sample(at: atMono, bytes: delta))
        lastReportMono = atMono
        let oldest = atMono > Self.rateWindow ? atMono - Self.rateWindow : 0
        samples.removeAll { $0.at < oldest }
    }

    public mutating func finished(id name: String, audio: Bool, bytes: Int64?, outcome: Outcome, atMono: UInt64) {
        uploads[name] = nil
        guard since != nil else { return }
        switch outcome {
        case .delivered:
            guard delivered.insert(name).inserted else { return }
            if audio {
                deliveredAudioFiles += 1
                deliveredAudioBytes += bytes ?? 0
            } else {
                deliveredOtherFiles += 1
            }
        case .retrying: retryingAttempts += 1
        case .held: heldAttempts += 1
        case .cancelled: break
        }
    }

    /// Bytes per second over the recent window; nil when not counting, idle, or too early to say.
    public func rate(atMono now: UInt64) -> Double? {
        guard since != nil, let last = lastReportMono, now >= last, now - last <= Self.idleAfter else { return nil }
        let window = min(Self.rateWindow, now - sinceMono)
        guard window >= 1_000_000_000 else { return nil }
        let from = now - window
        let bytes = samples.filter { $0.at > from && $0.at <= now }.reduce(Int64(0)) { $0 + $1.bytes }
        return Double(bytes) / (Double(window) / 1e9)
    }

    /// Uploads reporting progress now. `sent`/`total` cover only those with a known total.
    public var inFlight: (sent: Int64, total: Int64, uploads: Int, unknownTotals: Int) {
        var sent: Int64 = 0, total: Int64 = 0, unknown = 0
        for u in uploads.values {
            if let e = u.expected { sent += min(u.sent ?? 0, e); total += e } else { unknown += 1 }
        }
        return (sent, total, uploads.count, unknown)
    }
}
