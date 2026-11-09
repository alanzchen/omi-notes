import Foundation

// JSON bodies of the phone ↔ server API (capture-format-v1.md "HTTP API").

public enum SealReason: String, Codable, Sendable {
    case bleDisconnected = "ble_disconnected"
    case userStopped = "user_stopped"
    case deviceForgotten = "device_forgotten"
    case appRecovered = "app_recovered"
    case syncComplete = "sync_complete"
    case syncInterrupted = "sync_interrupted"
    case replayComplete = "replay_complete"
}

/// Evidence carried by ring seals (`sync_complete` / `sync_interrupted`).
public struct RingSealEvidence: Codable, Equatable, Sendable {
    public var generation: Int
    public var infoReadSeq: UInt64
    public var infoWriteSeq: UInt64
    public var doneNextSeq: UInt64?
    public var dropped: UInt64
    public var rtcValid: Bool
    public var coversUntil: String

    public init(generation: Int, infoReadSeq: UInt64, infoWriteSeq: UInt64, doneNextSeq: UInt64?, dropped: UInt64, rtcValid: Bool, coversUntil: String) {
        self.generation = generation
        self.infoReadSeq = infoReadSeq
        self.infoWriteSeq = infoWriteSeq
        self.doneNextSeq = doneNextSeq
        self.dropped = dropped
        self.rtcValid = rtcValid
        self.coversUntil = coversUntil
    }

    enum CodingKeys: String, CodingKey {
        case generation
        case infoReadSeq = "info_read_seq"
        case infoWriteSeq = "info_write_seq"
        case doneNextSeq = "done_next_seq"
        case dropped
        case rtcValid = "rtc_valid"
        case coversUntil = "covers_until"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generation, forKey: .generation)
        try c.encode(infoReadSeq, forKey: .infoReadSeq)
        try c.encode(infoWriteSeq, forKey: .infoWriteSeq)
        try c.encode(doneNextSeq, forKey: .doneNextSeq)
        try c.encode(dropped, forKey: .dropped)
        try c.encode(rtcValid, forKey: .rtcValid)
        try c.encode(coversUntil, forKey: .coversUntil)
    }
}

/// `PUT /v1/captures/{capture_id}/seal` body.
public struct SealBody: Codable, Equatable, Sendable {
    public var lastChunkSequence: Int
    public var reason: SealReason
    public var endedAt: String
    public var endOffsetUs: Int64
    public var deviceId: String
    public var source: CaptureSource
    public var ring: RingSealEvidence?

    public init(lastChunkSequence: Int, reason: SealReason, endedAt: String, endOffsetUs: Int64, deviceId: String, source: CaptureSource, ring: RingSealEvidence? = nil) {
        self.lastChunkSequence = lastChunkSequence
        self.reason = reason
        self.endedAt = endedAt
        self.endOffsetUs = endOffsetUs
        self.deviceId = deviceId
        self.source = source
        self.ring = ring
    }

    enum CodingKeys: String, CodingKey {
        case lastChunkSequence = "last_chunk_sequence"
        case reason
        case endedAt = "ended_at"
        case endOffsetUs = "end_offset_us"
        case deviceId = "device_id"
        case source
        case ring
    }
}

/// Heartbeat coverage watermark.
public struct CoverageWatermark: Codable, Equatable, Sendable {
    public var captureId: String
    public var throughOffsetUs: Int64
    public var throughChunkSequence: Int

    public init(captureId: String, throughOffsetUs: Int64, throughChunkSequence: Int) {
        self.captureId = captureId
        self.throughOffsetUs = throughOffsetUs
        self.throughChunkSequence = throughChunkSequence
    }

    enum CodingKeys: String, CodingKey {
        case captureId = "capture_id"
        case throughOffsetUs = "through_offset_us"
        case throughChunkSequence = "through_chunk_sequence"
    }
}

public struct HeartbeatData: Codable, Equatable, Sendable {
    public var battery: Int?
    public var charging: Bool?
    public var firmwareRevision: String?
    public var modelNumber: String?
    public var rtcValid: Bool?
    public var offlineUnread: Int?
    public var outboxChunks: Int?
    public var outboxBytes: Int64?
    public var appState: String?
    public var coverage: CoverageWatermark?
    /// The phone's side of the Apple Watch relay (absent before any Watch audio).
    public var watchRelay: WatchRelayHealth?

    public init(battery: Int? = nil, charging: Bool? = nil, firmwareRevision: String? = nil, modelNumber: String? = nil, rtcValid: Bool? = nil, offlineUnread: Int? = nil, outboxChunks: Int? = nil, outboxBytes: Int64? = nil, appState: String? = nil, coverage: CoverageWatermark? = nil, watchRelay: WatchRelayHealth? = nil) {
        self.watchRelay = watchRelay
        self.battery = battery
        self.charging = charging
        self.firmwareRevision = firmwareRevision
        self.modelNumber = modelNumber
        self.rtcValid = rtcValid
        self.offlineUnread = offlineUnread
        self.outboxChunks = outboxChunks
        self.outboxBytes = outboxBytes
        self.appState = appState
        self.coverage = coverage
    }

    enum CodingKeys: String, CodingKey {
        case battery, charging
        case firmwareRevision = "firmware_revision"
        case modelNumber = "model_number"
        case rtcValid = "rtc_valid"
        case offlineUnread = "offline_unread"
        case outboxChunks = "outbox_chunks"
        case outboxBytes = "outbox_bytes"
        case appState = "app_state"
        case coverage
        case watchRelay = "watch_relay"
    }
}

/// Heartbeat `watch_relay`: Watch parts this phone has stored (in all), refused since the app
/// launched (with the last reason: the Watch keeps refused parts), and still converting.
public struct WatchRelayHealth: Codable, Equatable, Sendable {
    public var received: Int
    public var refused: Int
    public var lastRefusal: String?
    public var lastReceivedAt: String?
    public var inboxPending: Int

    public init(received: Int, refused: Int, lastRefusal: String?, lastReceivedAt: String?, inboxPending: Int) {
        self.received = received
        self.refused = refused
        self.lastRefusal = lastRefusal
        self.lastReceivedAt = lastReceivedAt
        self.inboxPending = inboxPending
    }

    enum CodingKeys: String, CodingKey {
        case received, refused
        case lastRefusal = "last_refusal", lastReceivedAt = "last_received_at", inboxPending = "inbox_pending"
    }
}

/// `phone_status`: the phone's own state, sent whether or not a pendant is involved (heartbeats are
/// pendant-only). `device_id` is `phone-<install id>`; `at` is when it was generated. The counts
/// describe the outbox, not what is eligible to upload now.
public struct PhoneStatusData: Codable, Equatable, Sendable {
    public var schema = 1
    /// "0.1.0 (34)": the build that wrote this event.
    public var appVersion: String?
    /// One per app process: tells a relaunch from continuous running.
    public var launchId: String
    /// What prompted it: `launch`, `foreground`, `background_wake` or `watch_receipt`.
    public var trigger: String
    public var appState: String
    public var outboxPending: Int
    public var outboxChunks: Int
    public var outboxBytes: Int64
    public var outboxQuarantined: Int
    public var uploadInFlight: Int
    public var uploadHeld: Int
    public var uploadPaused: Bool
    public var pendantRemembered: Bool
    public var watchRelay: WatchRelayHealth?

    public init(appVersion: String?, launchId: String, trigger: String, appState: String, outboxPending: Int, outboxChunks: Int,
                outboxBytes: Int64, outboxQuarantined: Int, uploadInFlight: Int, uploadHeld: Int, uploadPaused: Bool,
                pendantRemembered: Bool, watchRelay: WatchRelayHealth?) {
        self.appVersion = appVersion
        self.launchId = launchId
        self.trigger = trigger
        self.appState = appState
        self.outboxPending = outboxPending
        self.outboxChunks = outboxChunks
        self.outboxBytes = outboxBytes
        self.outboxQuarantined = outboxQuarantined
        self.uploadInFlight = uploadInFlight
        self.uploadHeld = uploadHeld
        self.uploadPaused = uploadPaused
        self.pendantRemembered = pendantRemembered
        self.watchRelay = watchRelay
    }

    enum CodingKeys: String, CodingKey {
        case schema, trigger
        case appVersion = "app_version", launchId = "launch_id", appState = "app_state"
        case outboxPending = "outbox_pending", outboxChunks = "outbox_chunks", outboxBytes = "outbox_bytes"
        case outboxQuarantined = "outbox_quarantined", uploadInFlight = "upload_in_flight", uploadHeld = "upload_held"
        case uploadPaused = "upload_paused", pendantRemembered = "pendant_remembered", watchRelay = "watch_relay"
    }
}

public struct ButtonData: Codable, Equatable, Sendable {
    public var code: Int
    public init(code: Int) { self.code = code }
}

/// `voice_enrollment_start`: the wearer starts reading enrollment prompts. `capture_id`/`offset_us`
/// (top level) mark the window start on the live capture's monotonic clock.
public struct VoiceEnrollmentStartData: Codable, Equatable, Sendable {
    public var enrollmentId: String
    public init(enrollmentId: String) { self.enrollmentId = enrollmentId }
    enum CodingKeys: String, CodingKey { case enrollmentId = "enrollment_id" }
}

/// `voice_enrollment_end`: the window end and how the attempt ended.
public struct VoiceEnrollmentEndData: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case completed, cancelled, interrupted }
    public var enrollmentId: String
    public var endOffsetUs: Int64
    public var outcome: Outcome
    public init(enrollmentId: String, endOffsetUs: Int64, outcome: Outcome) {
        self.enrollmentId = enrollmentId
        self.endOffsetUs = endOffsetUs
        self.outcome = outcome
    }
    enum CodingKeys: String, CodingKey {
        case enrollmentId = "enrollment_id", endOffsetUs = "end_offset_us", outcome
    }
}

/// `PUT /v1/events/{event_id}` body.
public struct EventBody: Encodable, Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        case button(ButtonData)
        case heartbeat(HeartbeatData)
        case voiceEnrollmentStart(VoiceEnrollmentStartData)
        case voiceEnrollmentEnd(VoiceEnrollmentEndData)
        case watchPerf(WatchPerfData)
        case phoneStatus(PhoneStatusData)
    }

    public var deviceId: String
    public var at: String
    public var payload: Payload
    /// Button and enrollment events: the live capture and monotonic offset they belong to.
    public var captureId: String?
    public var offsetUs: Int64?

    public init(deviceId: String, at: String, payload: Payload, captureId: String? = nil, offsetUs: Int64? = nil) {
        self.deviceId = deviceId
        self.at = at
        self.payload = payload
        self.captureId = captureId
        self.offsetUs = offsetUs
    }

    public var type: String {
        switch payload {
        case .button: return "button"
        case .heartbeat: return "heartbeat"
        case .voiceEnrollmentStart: return "voice_enrollment_start"
        case .voiceEnrollmentEnd: return "voice_enrollment_end"
        case .watchPerf: return "watch_perf"
        case .phoneStatus: return "phone_status"
        }
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id", type, at, data
        case captureId = "capture_id"
        case offsetUs = "offset_us"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(type, forKey: .type)
        try c.encode(at, forKey: .at)
        switch payload {
        case .button(let d): try c.encode(d, forKey: .data)
        case .heartbeat(let d): try c.encode(d, forKey: .data)
        case .voiceEnrollmentStart(let d): try c.encode(d, forKey: .data)
        case .voiceEnrollmentEnd(let d): try c.encode(d, forKey: .data)
        case .watchPerf(let d): try c.encode(d, forKey: .data)
        case .phoneStatus(let d): try c.encode(d, forKey: .data)
        }
        try c.encodeIfPresent(captureId, forKey: .captureId)
        try c.encodeIfPresent(offsetUs, forKey: .offsetUs)
    }
}

public enum ContractJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

// MARK: - Responses

public struct ServerStatus: Decodable, Equatable, Sendable {
    public struct Provider: Decodable, Equatable, Sendable {
        public var provider: String?
        /// Non-secret model label (newer servers).
        public var model: String?
        /// STT only: `auto`, `provider`, `local` or `off`.
        public var diarization: String?
        /// Configured, not proven to work: the status call never runs inference.
        public var ready: Bool?
    }
    public struct Queue: Decodable, Equatable, Sendable {
        public var chunksPending: Int?
        public var conversationsOpen: Int?
        public var conversationsPending: Int?
        /// Conversations + chunks (older servers send only this).
        public var failed: Int?
        public var conversationsFailed: Int?
        public var chunksFailed: Int?
        public var conversationsRetrying: Int?
        public var notesConflicted: Int?
        enum CodingKeys: String, CodingKey {
            case chunksPending = "chunks_pending"
            case conversationsOpen = "conversations_open"
            case conversationsPending = "conversations_pending"
            case failed
            case conversationsFailed = "conversations_failed"
            case chunksFailed = "chunks_failed"
            case conversationsRetrying = "conversations_retrying"
            case notesConflicted = "notes_conflicted"
        }
    }
    /// What the pipeline is doing (newer servers).
    public struct Activity: Decodable, Equatable, Sendable {
        public struct Running: Decodable, Equatable, Sendable {
            public var conversationId: String
            public var stage: String
            public var startedAt: String?
            enum CodingKeys: String, CodingKey {
                case conversationId = "conversation_id"
                case stage
                case startedAt = "started_at"
            }
        }
        /// Last requests to a provider: success doesn't mean a finished transcript or note yet.
        public struct ProviderCalls: Decodable, Equatable, Sendable {
            public var lastOkAt: String?
            public var lastErrorAt: String?
            public var lastErrorKind: String?
            enum CodingKeys: String, CodingKey {
                case lastOkAt = "last_ok_at"
                case lastErrorAt = "last_error_at"
                case lastErrorKind = "last_error_kind"
            }

            /// The most recent request failed.
            public var lastFailed: Bool {
                guard let e = lastErrorAt.flatMap(ISO8601UTC.parse) else { return false }
                return lastOkAt.flatMap(ISO8601UTC.parse).map { e > $0 } ?? true
            }
        }
        public var running: [Running]?
        public var waiting: Int?
        public var backingOff: Int?
        public var oldestWaitingEndedAt: String?
        public var stt: ProviderCalls?
        public var llm: ProviderCalls?
        enum CodingKeys: String, CodingKey {
            case running, waiting, stt, llm
            case backingOff = "backing_off"
            case oldestWaitingEndedAt = "oldest_waiting_ended_at"
        }
    }
    public struct Worker: Decodable, Equatable, Sendable {
        /// A process holds the worker lock (pipeline or maintenance): present, not proof of progress.
        public var present: Bool?
    }
    public var ok: Bool?
    public var serverVersion: String?
    public var protocolVersion: Int?
    public var serverTime: String?
    public var serverStartedAt: String?
    public var stt: Provider?
    public var llm: Provider?
    public var queue: Queue?
    public var worker: Worker?
    public var activity: Activity?
    public var vaultId: String?
    public var lastNoteAt: String?
    public var notesDir: String?
    /// Why the vault stopped accepting writes (nil: writable, or an older server).
    public var readOnly: String?
    /// Optional capabilities, e.g. `voice_enrollment` (older servers send none).
    public var features: [String]?

    enum CodingKeys: String, CodingKey {
        case ok
        case serverVersion = "server_version"
        case protocolVersion = "protocol_version"
        case serverTime = "server_time"
        case serverStartedAt = "server_started_at"
        case stt, llm, queue, worker, activity
        case vaultId = "vault_id"
        case lastNoteAt = "last_note_at"
        case notesDir = "notes_dir"
        case readOnly = "read_only"
        case features
    }

    /// The server understands `voice_enrollment_start`/`_end` (so a reading is never transcribed).
    public var supportsVoiceEnrollment: Bool { features?.contains("voice_enrollment") == true }
    public var supportsWatchPerformance: Bool { features?.contains("watch_performance") == true }
    public var supportsConversationDetail: Bool { features?.contains("conversation_detail") == true }
    public var supportsIssues: Bool { features?.contains("issues") == true }
    public var supportsRetry: Bool { features?.contains("retry") == true }
    /// `POST /v1/conversations/{id}/keep` (keep a no-speaker result as a transcript).
    public var supportsKeep: Bool { features?.contains("keep") == true }
    /// A failed conversation can be set aside from the phone (`POST /v1/conversations/{id}/dismiss`).
    public var supportsDismiss: Bool { features?.contains("dismiss") == true }
    /// Clip text, suggestion scope, durable "keep unknown" and undo for naming voices.
    public var supportsNameVoice: Bool { features?.contains("name_voice") == true }
    /// A note's recording can be played (`/v1/conversations/{id}/recording`).
    public var supportsRecording: Bool { features?.contains("recording") == true }
    /// Value assessments, highlights and the owner's priority choice.
    public var supportsValueNotes: Bool { features?.contains("value_notes") == true }
    public var supportsRecordingClass: Bool { features?.contains("recording_class") == true }
    /// Short sessions are deferred and `POST /v1/conversations/{id}/transcribe` asks for one now.
    public var supportsDeferredTranscription: Bool { features?.contains("deferred_transcription") == true }
    public var supportsSearch: Bool { features?.contains("search") == true }
    /// Accepts the phone's diagnostic log tail (`PUT /v1/diagnostics/phone-log`).
    public var supportsPhoneLog: Bool { features?.contains("phone_log") == true }
    /// Button code 3: a double tap stars the conversation it belongs to.
    public var supportsPendantStar: Bool { features?.contains("pendant_star") == true }
    public var supportsStats: Bool { features?.contains("stats") == true }
}

public struct CaptureStatusResponse: Decodable, Equatable, Sendable {
    public var captureId: String
    public var source: String?
    public var sealed: Bool?
    public var lastChunkSequence: Int?
    public var processedThrough: Int

    enum CodingKeys: String, CodingKey {
        case captureId = "capture_id"
        case source, sealed
        case lastChunkSequence = "last_chunk_sequence"
        case processedThrough = "processed_through"
    }
}

/// A display state chosen by the server (`state`) or a problem next to readable content (`issues`).
public struct ConversationFlag: Codable, Equatable, Sendable, Hashable {
    public var code: String
    public var message: String
}

/// The owner talking alone (`monologue`), a conversation (`dialogue`) or background (`passive`), as the
/// note was made (capture-format-v1.md, "Recording class").
public struct RecordingClassView: Codable, Equatable, Hashable, Sendable {
    public static let kinds = ["monologue", "dialogue", "passive"]

    /// The kind the current note was made for; never a requested one before the server applies it.
    public var kind: String?
    public var auto: String?
    /// `high`, `medium`, `low`, or `owner` (the owner chose it).
    public var confidence: String?
    public var overridden: Bool?
    public var wearerShare: Double?
    /// The owner's newer choice is waiting for its new summary.
    public var updating: Bool?
    /// That newer choice (`auto` for going back to the automatic kind), while `updating`.
    public var requested: String?
    /// The stored choice can't be read on the server; the note keeps `kind`.
    public var choiceUnreadable: String?
    /// The new summary for `requested` couldn't be written; the note stays as it was and the server tries again later.
    public var updateFailed: String?
    /// No summary yet: a deferred session's provisional kind (`undetermined` without evidence, or the owner's choice).
    public var provisional: Bool?

    enum CodingKeys: String, CodingKey {
        case kind = "class", auto, confidence, overridden, updating, requested
        case wearerShare = "wearer_share"
        case choiceUnreadable = "choice_unreadable"
        case updateFailed = "update_failed"
        case provisional
    }

    public init(kind: String?, auto: String? = nil, confidence: String? = nil, overridden: Bool? = nil,
                wearerShare: Double? = nil, updating: Bool? = nil, requested: String? = nil, choiceUnreadable: String? = nil,
                updateFailed: String? = nil, provisional: Bool? = nil) {
        self.kind = kind; self.auto = auto; self.confidence = confidence
        self.overridden = overridden; self.wearerShare = wearerShare; self.updating = updating
        self.requested = requested; self.choiceUnreadable = choiceUnreadable; self.updateFailed = updateFailed
        self.provisional = provisional
    }

    public var isUpdating: Bool { updating == true }
    /// Nobody can tell yet (a deferred short session without a classifier's verdict).
    public var isUndetermined: Bool { kind == "undetermined" }

    /// Whether a note made for `self` still shows what `newer` describes: the same kind, and no rewrite finished
    /// in between (a pending choice that is no longer pending means the server wrote a new summary).
    public func sameTreatment(as newer: RecordingClassView?) -> Bool {
        guard let newer else { return true }
        return kind == newer.kind && overridden == newer.overridden && !(isUpdating && !newer.isUpdating)
    }

    /// The short name a row shows.
    public static func title(_ kind: String?) -> String? {
        switch kind {
        case "monologue": "Me"
        case "dialogue": "Talk"
        case "passive": "Background"
        case "auto": "Automatic"
        default: nil
        }
    }
}

public struct ConversationSummary: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var status: String
    public var state: ConversationFlag?
    public var issues: [ConversationFlag]?
    public var startedAt: String?
    public var endedAt: String?
    public var durationS: Double?
    public var title: String?
    public var emoji: String?
    public var preview: String?
    public var speakerNames: [String]?
    public var notePath: String?
    public var lateAudio: Bool?
    public var provisional: Bool?
    public var speakersReady: Bool?
    /// What the summary says it's worth, and the owner's own choice (servers with `value_notes`).
    public var value: ConversationValue?
    /// What kind of recording it is (servers with `recording_class`); nil until summarized, or provisional
    /// (`undetermined` until a transcription-free classifier exists) for a deferred short session.
    public var recordingClass: RecordingClassView?
    /// Detected speech in seconds (`duration_s` is the elapsed span); what makes a session short.
    public var speechS: Double?
    /// The server's local day (YYYY-MM-DD) the conversation started on: the key of `RecentConversationsResponse.days`.
    public var day: String?
    /// A deferred short session still without a result (servers with `deferred_transcription`).
    public var deferred: DeferredTranscription?
    /// The note's revision, bumped whenever its content changes; a cached detail with another one is stale.
    public var revision: Int?

    /// A placeholder until the server's answer arrives (e.g. opened from an issue).
    public init(id: String, status: String, startedAt: String? = nil, title: String? = nil) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.title = title
    }

    /// Older servers do not report readiness; only completed notes are safe to open there.
    public var canReviewSpeakers: Bool {
        speakersReady ?? (notePath != nil && (status == "done" || status == "discarded"))
    }

    /// The chip: the server's state, or one derived from `status` for older servers.
    public var displayState: ConversationFlag {
        if let state { return state }
        switch status {
        case "open": return ConversationFlag(code: "listening", message: "Still listening")
        case "closed", "transcribing", "summarizing": return ConversationFlag(code: "processing", message: "Processing")
        case "done": return ConversationFlag(code: "ready", message: "Note ready")
        case "discarded": return ConversationFlag(code: "discarded", message: "Skipped")
        case "failed": return ConversationFlag(code: notePath == nil ? "failed" : "transcript_only",
                                               message: notePath == nil ? "Processing failed" : "Transcript ready; summary unavailable")
        default: return ConversationFlag(code: status, message: status)
        }
    }

    public var startedDate: Date? { startedAt.flatMap(ISO8601UTC.parse) }

    /// From the server, else from the start and end times.
    public var duration: TimeInterval? {
        if let durationS { return durationS }
        guard let s = startedDate, let e = endedAt.flatMap(ISO8601UTC.parse) else { return nil }
        return max(0, e.timeIntervalSince(s))
    }

    enum CodingKeys: String, CodingKey {
        case id, status, state, issues
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationS = "duration_s"
        case title, emoji, preview
        case speakerNames = "speaker_names"
        case notePath = "note_path"
        case lateAudio = "late_audio"
        case provisional
        case speakersReady = "speakers_ready"
        case value
        case recordingClass = "recording_class"
        case speechS = "speech_s"
        case day, deferred, revision
    }

    /// A short session (under `threshold` seconds of detected speech). Older servers don't report speech: there a
    /// finished note under 30 s, or a skipped recording, counts (the earlier fold). Never a recording still open
    /// (it may grow; a short one is never a sign that it ended).
    public func isShort(threshold: Double) -> Bool {
        if status == "open" { return false }
        if let speechS { return speechS < threshold }
        switch (status, displayState.code) {
        case ("discarded", "discarded"): return true
        case ("done", "ready"): return (durationS ?? .infinity) < 30
        default: return false
        }
    }
}

/// A deferred short session: `waiting` (for an idle moment on the server, or the owner's tap) or `requested`.
public struct DeferredTranscription: Codable, Equatable, Hashable, Sendable {
    public var state: String
    public var operationId: String?
    public var thresholdS: Double?
    public var provisionalClass: String?

    public init(state: String, operationId: String? = nil, thresholdS: Double? = nil, provisionalClass: String? = nil) {
        self.state = state; self.operationId = operationId; self.thresholdS = thresholdS; self.provisionalClass = provisionalClass
    }

    public var isWaiting: Bool { state == "waiting" }
    public var isRequested: Bool { state == "requested" }

    enum CodingKeys: String, CodingKey {
        case state
        case operationId = "operation_id"
        case thresholdS = "threshold_s"
        case provisionalClass = "provisional_class"
    }
}

/// One day's short sessions over the whole day (not one page, not one filter): how many, how many wait deferred,
/// how many the owner asked to transcribe, and how many need a look.
public struct ShortDay: Codable, Equatable, Hashable, Sendable {
    public var short: Int
    public var deferred: Int
    public var requested: Int
    public var issues: Int

    public init(short: Int = 0, deferred: Int = 0, requested: Int = 0, issues: Int = 0) {
        self.short = short; self.deferred = deferred; self.requested = requested; self.issues = issues
    }
}

/// The summary's own assessment of a conversation, next to the owner's explicit choice. Separate on
/// purpose: a recommendation never hides anything; only the owner's "less useful" lowers a row.
public struct ConversationValue: Codable, Equatable, Hashable, Sendable {
    public struct Choice: Codable, Equatable, Hashable, Sendable {
        /// `important`, `less_useful`, or `auto` (the owner hasn't chosen).
        public var state: String
        public var revision: Int?
        public var setAt: String?
        /// Where the choice was made: `app`, or `pendant` (a star from a double tap). Nil from
        /// servers before it existed.
        public var source: String?

        public init(state: String, revision: Int? = nil, setAt: String? = nil, source: String? = nil) {
            self.state = state
            self.revision = revision
            self.setAt = setAt
            self.source = source
        }

        enum CodingKeys: String, CodingKey {
            case state, revision, source
            case setAt = "set_at"
        }
    }

    /// `high`, `normal`, `low`, `unknown`, `legacy` (summarized before assessments), `pending`, `failed`.
    public var assessment: String?
    /// `conversation`, `dictation`, `reflection`, `call`, `media`, `mixed`, `unknown`: a hint only.
    public var interaction: String?
    public var recommended: Bool?
    /// The first highlight's title, for recommended conversations.
    public var highlight: String?
    public var user: Choice?

    public init(assessment: String? = nil, interaction: String? = nil, recommended: Bool? = nil, highlight: String? = nil,
                user: Choice? = nil) {
        self.assessment = assessment
        self.interaction = interaction
        self.recommended = recommended
        self.highlight = highlight
        self.user = user
    }
}

/// A span worth revisiting; `target` only when its transcript lines are valid for the summary.
public struct ConversationHighlight: Codable, Equatable, Hashable, Sendable {
    public struct Target: Codable, Equatable, Hashable, Sendable {
        public var firstSegment: Int
        public var lastSegment: Int
        public var startAt: String?
        public var endAt: String?
        /// `coarse`: transcription windows, not word-aligned; `segment`: the segment's own time.
        public var timing: String?

        enum CodingKeys: String, CodingKey {
            case timing
            case firstSegment = "first_segment"
            case lastSegment = "last_segment"
            case startAt = "start_at"
            case endAt = "end_at"
        }
    }

    public var title: String
    public var why: String?
    public var target: Target?
}

public struct RecentConversationsResponse: Decodable, Equatable, Sendable {
    public var conversations: [ConversationSummary]
    /// nil on the last page (and from older servers, which don't paginate).
    public var nextCursor: String?
    /// Per local day of this page's rows, that whole day's short sessions (servers with `deferred_transcription`).
    public var days: [String: ShortDay]?
    /// Detected speech below which a session is short (seconds).
    public var shortS: Double?

    public init(conversations: [ConversationSummary], nextCursor: String? = nil, days: [String: ShortDay]? = nil,
                shortS: Double? = nil) {
        self.conversations = conversations; self.nextCursor = nextCursor; self.days = days; self.shortS = shortS
    }

    enum CodingKeys: String, CodingKey {
        case conversations
        case nextCursor = "next_cursor"
        case days
        case shortS = "short_s"
    }
}

public struct APIErrorBody: Decodable, Equatable, Sendable {
    public var error: String?
    public var detail: String?
}

// MARK: - Time formatting

public enum ISO8601UTC {
    /// `2026-09-26T19:32:05.123Z` (UTC, milliseconds truncated, `Z`).
    public static func format(_ date: Date) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        var secs = time_t(totalMs >= 0 ? totalMs / 1000 : (totalMs - 999) / 1000)
        let ms = Int(totalMs - Int64(secs) * 1000)
        var tmv = tm()
        gmtime_r(&secs, &tmv)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1, Int(tmv.tm_mday),
            Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec), ms)
    }

    /// Parses the contract format (fractional seconds optional).
    public static func parse(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}

/// `PUT /v1/conversations/{id}/priority`.
public struct PriorityAnswer: Decodable, Equatable, Sendable {
    public var state: String
    public var revision: Int?
    public var setAt: String?
    /// False: an older choice than the stored one; the stored (newer) state is returned.
    public var applied: Bool?
}
