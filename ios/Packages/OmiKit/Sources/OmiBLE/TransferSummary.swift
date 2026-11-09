import Foundation
import OmiCapture
import OmiProtocol
import OmiWatchKit

/// What the transfer screens show, in three separate stages. Each says only what its own source
/// knows, as of its own time: the Watch's report, this iPhone's uploads, the server's last status.
/// Recording continues, so the bars cover only what is known now and the time left is a rough
/// "at this speed" figure, never a promise.
public struct TransferSummary: Equatable, Sendable {
    // MARK: Watch → iPhone
    public struct Watch: Equatable, Sendable {
        /// nil while unknown (WatchConnectivity not activated yet and nothing received).
        public var inUse: Bool?
        /// The Watch's own report: audio still on the Watch (its parts' own start/end offsets).
        public var reportAt: Date?
        public var reportFresh: Bool
        public var waitingParts: Int?
        public var waitingSeconds: Int?
        /// Parts this iPhone stored durably (and acknowledged to the Watch).
        public var receivedOnPhone: Int
        /// The last receipt in this run of the app (unknown after a relaunch until one arrives).
        public var lastReceivedAt: Date?
        /// Received parts still being turned into uploads on this iPhone.
        public var converting: Int
        /// Watch audio files queued here for the server.
        public var waitingForServer: Int
        /// Audio parts the Watch keeps but can't send (from its report): never "all sent" unless it
        /// reported 0 (nil: an older Watch app that doesn't say, or no report).
        public var keptOnWatch: Int? = 0
        /// Of the waiting parts, re-checks: parts the iPhone had no checksum receipt for (mostly converted by
        /// an older build), sent after new audio. Still unacknowledged: they stay in every total and nothing
        /// says "all sent" while any remain; they are only named apart.
        public var recheckParts: Int = 0
        public var recheckSeconds: Int = 0

        /// Waiting parts that aren't re-checks.
        public var newParts: Int? { waitingParts.map { max(0, $0 - recheckParts) } }
    }

    // MARK: iPhone → server
    public enum UploadState: Equatable, Sendable {
        case notConfigured, paused(String), offline(String), sending, retrying, waiting
        /// Nothing waiting to upload, but Watch parts are still being prepared for upload.
        case preparing(Int)
        /// Nothing waiting to upload, but files are kept aside on this iPhone (not uploaded).
        case keptAside(Int)
        /// The queue couldn't be read, so its counts are unknown.
        case queueUnreadable
        case allSent, unknown
    }

    public struct Phone: Equatable, Sendable {
        public var state: UploadState
        /// Bytes per second over the last few seconds of progress reports; nil when none are arriving.
        public var rate: Double?
        /// Network bytes reported since `since` (audio, metadata and retries alike).
        public var networkBytes: Int64
        public var since: Date?
        public var inFlightUploads: Int
        /// Of the uploads in flight with a known size: bytes sent / their total.
        public var inFlightSent: Int64
        public var inFlightTotal: Int64
        /// Uploads in flight whose size isn't known (not in `inFlightTotal`).
        public var inFlightUnknownTotals: Int
        public var deliveredAudioFiles: Int
        public var deliveredAudioBytes: Int64
        public var deliveredOtherFiles: Int
        /// Failed attempts tried again automatically / now held on this iPhone.
        public var retryingAttempts: Int
        public var heldAttempts: Int
        public var queuedFiles: Int
        public var queuedAudioFiles: Int
        public var queuedBytes: Int64
        /// Queued audio, summed from the chunks' headers; `audioUnknown` chunks couldn't be read.
        public var queuedAudioSeconds: Double
        public var queuedAudioUnknown: Int
        public var retryingFiles: Int
        public var keptAside: Int
    }

    // MARK: server
    public struct Server: Equatable, Sendable {
        public var reachable: Bool?
        public var checkedAt: Date?
        public var chunksPending: Int?
        public var conversationsPending: Int?
        public var lastNoteAt: Date?
    }

    public var watch: Watch
    public var phone: Phone
    public var server: Server

    public static func evaluate(snapshot s: EngineSnapshot, server: ServerReachability, status: ServerStatus?, statusAt: Date?,
                                watchInstalled: Bool?, nowMono: UInt64, now: Date) -> TransferSummary {
        let report = s.watchReport
        let watch = Watch(
            inUse: watchInstalled == true || report != nil || s.watchLastReceivedAt != nil || s.watchReceived > 0
                ? true : watchInstalled == false ? false : nil,
            reportAt: report?.at,
            reportFresh: report.map { now.timeIntervalSince($0.at) <= WatchSummary.fresh && $0.at <= now.addingTimeInterval(60) } ?? false,
            waitingParts: report?.waitingParts, waitingSeconds: report?.waitingSeconds,
            receivedOnPhone: s.watchReceived, lastReceivedAt: s.watchLastReceiptAt,
            converting: s.watchPending, waitingForServer: s.watchWaitingUpload, keptOnWatch: report?.keptParts,
            recheckParts: report?.recheckParts ?? 0, recheckSeconds: report?.recheckSeconds ?? 0)

        let m = s.transfer.meter
        let rate = m.rate(atMono: nowMono)
        let flight = m.inFlight
        let state: UploadState
        if !s.serverConfigured {
            state = .notConfigured
        } else if let paused = s.upload.pausedReason {
            state = .paused(paused)
        } else if m.since == nil {
            state = .unknown  // not counting (in the background): nothing here is live
        } else if rate != nil {
            state = .sending
        } else if case .unreachable(let why) = server, s.outbox.pendingCount > 0 {
            state = .offline(why)
        } else if case .unauthorized = server {
            state = .offline("the server rejected this phone")
        } else if s.upload.backingOff > 0 {
            state = .retrying
        } else if s.outbox.pendingCount > 0 || flight.uploads > 0 {
            state = .waiting
        } else if !s.outbox.inventoryReadable {
            state = .queueUnreadable
        } else if s.watchPending > 0 {
            state = .preparing(s.watchPending)
        } else if s.outbox.quarantineCount > 0 {
            state = .keptAside(s.outbox.quarantineCount)
        } else {
            state = .allSent  // nothing waiting, preparing or kept aside, and the queue was read
        }
        let phone = Phone(
            state: state, rate: rate, networkBytes: m.networkBytes, since: m.since,
            inFlightUploads: flight.uploads, inFlightSent: flight.sent, inFlightTotal: flight.total, inFlightUnknownTotals: flight.unknownTotals,
            deliveredAudioFiles: m.deliveredAudioFiles, deliveredAudioBytes: m.deliveredAudioBytes,
            deliveredOtherFiles: m.deliveredOtherFiles, retryingAttempts: m.retryingAttempts, heldAttempts: m.heldAttempts,
            queuedFiles: s.outbox.pendingCount, queuedAudioFiles: s.outbox.pendingChunks, queuedBytes: s.outbox.pendingBytes,
            queuedAudioSeconds: s.transfer.pendingAudioSeconds, queuedAudioUnknown: s.transfer.pendingAudioUnknown,
            retryingFiles: s.upload.backingOff, keptAside: s.outbox.quarantineCount)

        let reachable: Bool?
        switch server {
        case .reachable: reachable = true
        case .unreachable, .unauthorized: reachable = false
        default: reachable = nil
        }
        let srv = Server(reachable: reachable, checkedAt: statusAt, chunksPending: status?.queue?.chunksPending,
                         conversationsPending: status?.queue?.conversationsPending,
                         lastNoteAt: status?.lastNoteAt.flatMap(ISO8601UTC.parse))
        return TransferSummary(watch: watch, phone: phone, server: srv)
    }

    #if DEBUG
    /// Simulator screenshots only (debug builds): SYNTHETIC values, labelled as such on screen.
    /// `-OmiNotesDebugTransferState backlog|sending|waiting|offline|retrying|kept-aside|all-sent|unknown-watch`
    public static func debugFixture(_ name: String, now: Date) -> TransferSummary? {
        var watch = Watch(inUse: true, reportAt: now.addingTimeInterval(-120), reportFresh: true, waitingParts: 4, waitingSeconds: 230,
                          receivedOnPhone: 266, lastReceivedAt: now.addingTimeInterval(-95), converting: 0, waitingForServer: 3)
        var phone = Phone(state: .waiting, rate: nil, networkBytes: 0, since: now.addingTimeInterval(-300), inFlightUploads: 0,
                          inFlightSent: 0, inFlightTotal: 0, inFlightUnknownTotals: 0, deliveredAudioFiles: 0, deliveredAudioBytes: 0,
                          deliveredOtherFiles: 0, retryingAttempts: 0, heldAttempts: 0, queuedFiles: 38, queuedAudioFiles: 36,
                          queuedBytes: 9_400_000, queuedAudioSeconds: 2_170, queuedAudioUnknown: 0, retryingFiles: 0, keptAside: 0)
        let server = Server(reachable: true, checkedAt: now.addingTimeInterval(-40), chunksPending: 6, conversationsPending: 1,
                            lastNoteAt: now.addingTimeInterval(-1_500))
        switch name {
        case "sending":
            phone.state = .sending; phone.rate = 1_240_000; phone.networkBytes = 24_100_000; phone.inFlightUploads = 32
            phone.inFlightSent = 3_900_000; phone.inFlightTotal = 8_100_000; phone.deliveredAudioFiles = 12
            phone.deliveredAudioBytes = 5_200_000; phone.deliveredOtherFiles = 3
        case "backlog":  // the numbers of the build-41 feedback screenshot (2026-11-08 04:31Z)
            phone.state = .sending; phone.rate = 111_700; phone.networkBytes = 12_600_000; phone.inFlightUploads = 40
            phone.inFlightSent = 781_000; phone.inFlightTotal = 4_200_000; phone.deliveredAudioFiles = 295
            phone.deliveredAudioBytes = 46_600_000; phone.deliveredOtherFiles = 1; phone.queuedFiles = 5_135
            phone.queuedAudioFiles = 5_120; phone.queuedBytes = 5_390_000_000; phone.queuedAudioSeconds = 201_480
            phone.queuedAudioUnknown = 8
        case "waiting": break
        case "offline":
            phone.state = .offline("timed out")
        case "retrying":
            phone.state = .retrying; phone.retryingFiles = 2; phone.retryingAttempts = 2
        case "kept-aside":
            phone.state = .keptAside(1); phone.queuedFiles = 0; phone.queuedAudioFiles = 0; phone.queuedBytes = 0
            phone.queuedAudioSeconds = 0; phone.keptAside = 1; phone.heldAttempts = 1
        case "all-sent":
            phone.state = .allSent; phone.queuedFiles = 0; phone.queuedAudioFiles = 0; phone.queuedBytes = 0; phone.queuedAudioSeconds = 0
            phone.deliveredAudioFiles = 9; phone.deliveredAudioBytes = 2_300_000
            watch.waitingParts = 0; watch.waitingSeconds = 0; watch.waitingForServer = 0
        case "unknown-watch":
            watch = Watch(inUse: nil, reportAt: nil, reportFresh: false, waitingParts: nil, waitingSeconds: nil, receivedOnPhone: 0,
                          lastReceivedAt: nil, converting: 0, waitingForServer: 0)
            phone.state = .allSent; phone.queuedFiles = 0; phone.queuedAudioFiles = 0; phone.queuedBytes = 0; phone.queuedAudioSeconds = 0
        default: return nil
        }
        return TransferSummary(watch: watch, phone: phone, server: server)
    }
    #endif

    /// Seconds to send what is queued now at the current speed; nil unless bytes are moving. A rough
    /// "at this speed" figure: recording continues and the speed changes, so it is no promise.
    public var phoneTimeLeft: Double? {
        guard phone.state == .sending, let rate = phone.rate, rate > 0, phone.queuedBytes > 0 else { return nil }
        return Double(phone.queuedBytes) / rate
    }

    /// iPhone → server bar: audio bytes the server confirmed since the app opened, of those plus
    /// the bytes still queued. nil when nothing is known (not counting, or nothing at all).
    public var phoneFraction: Double? {
        guard phone.since != nil else { return nil }
        let done = Double(phone.deliveredAudioBytes), total = done + Double(phone.queuedBytes)
        guard total > 0 else { return phone.state == .allSent ? 1 : nil }
        return done / total
    }

    /// Watch → iPhone bar: parts received, of those plus the parts the Watch still reports. nil
    /// without a current Watch report (a stale or future-dated one isn't evidence of now).
    public var watchFraction: Double? {
        guard watch.inUse == true, watch.reportAt != nil, watch.reportFresh, watch.keptOnWatch == 0, let waiting = watch.waitingParts else { return nil }
        let total = watch.receivedOnPhone + waiting
        return total > 0 ? Double(watch.receivedOnPhone) / Double(total) : 1
    }

    /// The Watch → iPhone line. Counts from the Watch's report (kept parts too) are statements about
    /// now only while the report is fresh and not dated ahead of this iPhone.
    public func watchLine(now: Date) -> String {
        let w = watch
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        if w.inUse == nil { return "Checking for Apple Watch" }
        if let at = w.reportAt, w.reportFresh {
            if let kept = w.keptOnWatch, kept > 0 { return "\(plural(kept, "part", "parts")) kept on the Watch, can't be sent" }
            if let parts = w.newParts {
                let recheck = w.recheckParts > 0 ? "re-checking \(plural(w.recheckParts, "older part", "older parts"))" : nil
                return parts == 0 ? (recheck.map { "R" + $0.dropFirst() } ?? "Nothing left on the Watch")
                    : "\(plural(parts, "part", "parts")) left on the Watch" + (recheck.map { " · \($0)" } ?? "")
            }
            return "Last Watch report \(SystemHealth.relative(at, now))"
        }
        if let at = w.reportAt, at <= now.addingTimeInterval(60) {
            return "Last Watch report \(SystemHealth.relative(at, now))"  // not current: no claim about now
        }
        if w.reportAt != nil { return "Watch report time is ahead of this iPhone" }
        return "No report from the Watch yet"
    }

    /// Everything reached the server as far as anyone can tell: this iPhone sent all it had, and the
    /// Watch (if one is in use) reported, recently, nothing waiting or being prepared.
    public var everythingSent: Bool {
        guard phone.state == .allSent else { return false }
        if watch.inUse == false { return true }
        return watch.reportFresh && watch.waitingParts == 0 && watch.keptOnWatch == 0 && watch.converting == 0 && watch.waitingForServer == 0
    }

    /// Audio files plus conversations the server last said it still has to process: exact only when
    /// it gave both counts; with one missing, an "at least" from the other if that is above 0; nil
    /// otherwise (a missing count is never zero).
    public var serverWork: (left: Int, atLeast: Bool)? {
        switch (server.chunksPending, server.conversationsPending) {
        case let (c?, v?): return (c + v, false)
        case let (n?, nil) where n > 0, let (nil, n?) where n > 0: return (n, true)
        default: return nil
        }
    }

    /// The exact count of work left on the server; nil unless the server gave both counts.
    public var serverWorkLeft: Int? { serverWork.flatMap { $0.atLeast ? nil : $0.left } }

    /// "820 B/s", "48.2 KB/s", "1.3 MB/s" (decimal units, like the Files app).
    public static func rateText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1_000 { return "\(Int(bytesPerSecond.rounded())) B/s" }
        if bytesPerSecond < 1_000_000 { return String(format: "%.1f KB/s", bytesPerSecond / 1_000) }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}
