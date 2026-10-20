import Foundation

/// What the sync Live Activity shows (its ActivityKit content state). Only counts, durations and
/// stages: never titles, transcripts or audio. nil means unknown, never zero.
public struct SyncActivityState: Codable, Hashable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case sending, waiting, retrying, offline, paused, preparing, keptAside, queueUnreadable, allSent, notConfigured, unknown
    }

    public var stage: Stage
    public var title: String
    public var detail: String?
    /// Bytes per second, only while bytes were actually moving when this was made (never carried over).
    public var rate: Double?
    /// Audio queued on this iPhone for the server, from the chunks' own recorded lengths; nil if unknown.
    public var queuedAudioSeconds: Double?
    /// Some queued chunks have an unknown length: `queuedAudioSeconds` is a lower bound.
    public var queuedAudioPartial: Bool
    public var queuedFiles: Int?
    /// The batch currently handed to iOS, when its size is known (not a total for the whole backlog).
    public var batchSent: Int64?
    public var batchTotal: Int64?
    /// Audio waiting on the Watch, from the Watch's own report (as of `watchReportAt`).
    public var watchWaitingSeconds: Int?
    public var watchReportAt: Date?
    /// Conversations the server still has to process (as of its last status), if it said.
    public var serverPending: Int?
    /// When this state was made (the screen says "as of" once it is stale).
    public var asOf: Date

    /// Work the phone still has to move (or can't confirm is done): a reason to show the activity.
    public var hasWork: Bool {
        switch stage {
        case .allSent, .notConfigured, .unknown: return (watchWaitingSeconds ?? 0) > 0
        default: return true
        }
    }

    public init(stage: Stage, title: String, detail: String? = nil, rate: Double? = nil, queuedAudioSeconds: Double? = nil,
                queuedAudioPartial: Bool = false, queuedFiles: Int? = nil, batchSent: Int64? = nil, batchTotal: Int64? = nil,
                watchWaitingSeconds: Int? = nil, watchReportAt: Date? = nil, serverPending: Int? = nil, asOf: Date) {
        self.stage = stage
        self.title = title
        self.detail = detail
        self.rate = rate
        self.queuedAudioSeconds = queuedAudioSeconds
        self.queuedAudioPartial = queuedAudioPartial
        self.queuedFiles = queuedFiles
        self.batchSent = batchSent
        self.batchTotal = batchTotal
        self.watchWaitingSeconds = watchWaitingSeconds
        self.watchReportAt = watchReportAt
        self.serverPending = serverPending
        self.asOf = asOf
    }
}
