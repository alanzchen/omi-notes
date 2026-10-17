import Foundation

/// What the phone has actually sent to the server while the app is open, from the upload tasks' own
/// progress callbacks (`didSendBodyData`). Times are monotonic nanoseconds.
///
/// - Counting starts at `start` (the app coming to the foreground) and stops at `suspend`: in the
///   background nothing is live, and the counters describe only this window.
/// - Bytes are counted from each upload's first report in the window: whatever it sent before that
///   is never claimed. A restarted attempt (lower total than before) starts a new baseline, so a
///   delta is never negative; its later bytes are real network bytes (retries included).
/// - Delivered = the server acknowledged the file; each file counts once. Audio (chunks) and other
///   files (events, seals) are counted apart.
public struct TransferMeter: Equatable, Sendable {
    public enum Outcome: Sendable { case delivered, failed, cancelled }

    /// The rate is the bytes reported over this window (or since `start`, if shorter)...
    public static let rateWindow: UInt64 = 5_000_000_000
    /// ...and none at all when nothing was reported for this long.
    public static let idleAfter: UInt64 = 3_000_000_000

    struct Upload: Equatable, Sendable {
        var sent: Int64
        var expected: Int64?
        var audio: Bool
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
    public private(set) var failedAttempts = 0

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
        failedAttempts = 0
        // uploads keep their last report: a task still running only counts what follows it
    }

    public mutating func suspend() {
        since = nil
        samples = []
        lastReportMono = nil
    }

    public mutating func progress(name: String, audio: Bool, sent: Int64, expected: Int64?, atMono: UInt64) {
        let total = expected.flatMap { $0 > 0 ? $0 : nil }
        guard let previous = uploads[name] else {
            uploads[name] = Upload(sent: sent, expected: total, audio: audio)  // first report: the baseline
            return
        }
        uploads[name] = Upload(sent: sent, expected: total ?? previous.expected, audio: audio)
        guard since != nil else { return }
        let delta = sent - previous.sent
        guard delta > 0 else { return }  // a restarted attempt: its new baseline, never negative
        networkBytes += delta
        samples.append(Sample(at: atMono, bytes: delta))
        lastReportMono = atMono
        let oldest = atMono > Self.rateWindow ? atMono - Self.rateWindow : 0
        samples.removeAll { $0.at < oldest }
    }

    public mutating func finished(name: String, audio: Bool, bytes: Int64?, outcome: Outcome, atMono: UInt64) {
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
        case .failed: failedAttempts += 1
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
            if let e = u.expected { sent += min(u.sent, e); total += e } else { unknown += 1 }
        }
        return (sent, total, uploads.count, unknown)
    }
}
