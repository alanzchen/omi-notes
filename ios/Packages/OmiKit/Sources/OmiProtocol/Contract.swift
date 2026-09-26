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

    public init(battery: Int? = nil, charging: Bool? = nil, firmwareRevision: String? = nil, modelNumber: String? = nil, rtcValid: Bool? = nil, offlineUnread: Int? = nil, outboxChunks: Int? = nil, outboxBytes: Int64? = nil, appState: String? = nil, coverage: CoverageWatermark? = nil) {
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
    }
}

public struct ButtonData: Codable, Equatable, Sendable {
    public var code: Int
    public init(code: Int) { self.code = code }
}

/// `PUT /v1/events/{event_id}` body.
public struct EventBody: Encodable, Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        case button(ButtonData)
        case heartbeat(HeartbeatData)
    }

    public var deviceId: String
    public var at: String
    public var payload: Payload
    /// Button events: the live capture and monotonic offset they belong to.
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
        public var ready: Bool?
    }
    public struct Queue: Decodable, Equatable, Sendable {
        public var chunksPending: Int?
        public var conversationsOpen: Int?
        public var conversationsPending: Int?
        public var failed: Int?
        enum CodingKeys: String, CodingKey {
            case chunksPending = "chunks_pending"
            case conversationsOpen = "conversations_open"
            case conversationsPending = "conversations_pending"
            case failed
        }
    }
    public var ok: Bool?
    public var serverVersion: String?
    public var protocolVersion: Int?
    public var serverTime: String?
    public var stt: Provider?
    public var llm: Provider?
    public var queue: Queue?
    public var notesDir: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case serverVersion = "server_version"
        case protocolVersion = "protocol_version"
        case serverTime = "server_time"
        case stt, llm, queue
        case notesDir = "notes_dir"
    }
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

public struct ConversationSummary: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var status: String
    public var startedAt: String?
    public var endedAt: String?
    public var title: String?
    public var notePath: String?
    public var lateAudio: Bool?
    public var provisional: Bool?

    enum CodingKeys: String, CodingKey {
        case id, status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case title
        case notePath = "note_path"
        case lateAudio = "late_audio"
        case provisional
    }
}

public struct RecentConversationsResponse: Decodable, Equatable, Sendable {
    public var conversations: [ConversationSummary]
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
