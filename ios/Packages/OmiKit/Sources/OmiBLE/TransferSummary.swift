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
    /// `-OmiNotesDebugTransferState sending|waiting|offline|retrying|kept-aside|all-sent|unknown-watch`
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

    /// "820 B/s", "48.2 KB/s", "1.3 MB/s" (decimal units, like the Files app).
    public static func rateText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1_000 { return "\(Int(bytesPerSecond.rounded())) B/s" }
        if bytesPerSecond < 1_000_000 { return String(format: "%.1f KB/s", bytesPerSecond / 1_000) }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}
