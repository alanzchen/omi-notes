import Foundation
import OmiCapture
import OmiProtocol
import OmiWatchKit

/// What the transfer screens show, in three separate stages. Each says only what its own source
/// knows, as of its own time: the Watch's report, this iPhone's uploads, the server's last status.
/// Nothing here is a completion percentage of a continuous recording, or an ETA.
public struct TransferSummary: Equatable, Sendable {
    // MARK: Watch → iPhone
    public struct Watch: Equatable, Sendable {
        public var inUse: Bool
        /// The Watch's own report: audio still on the Watch (its parts' own start/end offsets).
        public var reportAt: Date?
        public var reportFresh: Bool
        public var waitingParts: Int?
        public var waitingSeconds: Int?
        /// Parts this iPhone stored durably (and acknowledged to the Watch).
        public var receivedOnPhone: Int
        public var lastReceivedAt: Date?
        /// Received parts still being turned into uploads on this iPhone.
        public var converting: Int
        /// Watch audio files queued here for the server.
        public var waitingForServer: Int
    }

    // MARK: iPhone → server
    public enum UploadState: Equatable, Sendable {
        case notConfigured, paused(String), offline(String), sending, retrying, waiting, allSent, unknown
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
        public var deliveredAudioFiles: Int
        public var deliveredAudioBytes: Int64
        public var deliveredOtherFiles: Int
        public var failedAttempts: Int
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
            inUse: watchInstalled == true || report != nil || s.watchLastReceivedAt != nil || s.watchReceived > 0,
            reportAt: report?.at,
            reportFresh: report.map { now.timeIntervalSince($0.at) <= WatchSummary.fresh && $0.at <= now.addingTimeInterval(60) } ?? false,
            waitingParts: report?.waitingParts, waitingSeconds: report?.waitingSeconds,
            receivedOnPhone: s.watchReceived, lastReceivedAt: s.watchLastReceivedAt,
            converting: s.watchPending, waitingForServer: s.watchWaitingUpload)

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
        } else {
            state = .allSent
        }
        let phone = Phone(
            state: state, rate: rate, networkBytes: m.networkBytes, since: m.since,
            inFlightUploads: flight.uploads, inFlightSent: flight.sent, inFlightTotal: flight.total,
            deliveredAudioFiles: m.deliveredAudioFiles, deliveredAudioBytes: m.deliveredAudioBytes,
            deliveredOtherFiles: m.deliveredOtherFiles, failedAttempts: m.failedAttempts,
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

    /// "820 B/s", "48.2 KB/s", "1.3 MB/s" (decimal units, like the Files app).
    public static func rateText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1_000 { return "\(Int(bytesPerSecond.rounded())) B/s" }
        if bytesPerSecond < 1_000_000 { return String(format: "%.1f KB/s", bytesPerSecond / 1_000) }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}
