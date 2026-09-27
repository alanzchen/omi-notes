import Foundation

// Speaker-learning API models (docs/speaker-learning.md, "API"). JSON is snake_case; the client
// decodes with `.convertFromSnakeCase` and encodes with `.convertToSnakeCase`.

public struct Person: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var me: Bool?
    public var notePath: String?
    public var samples: Int?
    public var sessions: Int?
    /// Automatic naming is active for this person (activation gate passed).
    public var autoActive: Bool?
    public var voiceReady: Bool?

    public init(id: String, name: String, me: Bool? = nil, notePath: String? = nil, samples: Int? = nil,
                sessions: Int? = nil, autoActive: Bool? = nil, voiceReady: Bool? = nil) {
        self.id = id
        self.name = name
        self.me = me
        self.notePath = notePath
        self.samples = samples
        self.sessions = sessions
        self.autoActive = autoActive
        self.voiceReady = voiceReady
    }

    public var isMe: Bool { me == true }
}

public struct PeopleResponse: Decodable, Sendable { public var people: [Person] }

public struct PutPersonRequest: Encodable, Sendable {
    public var name: String
    public var me: Bool?
    /// The user attests this person knows their voice is recognized.
    public var attestKnows: Bool?
    public init(name: String, me: Bool? = nil, attestKnows: Bool? = nil) {
        self.name = name
        self.me = me
        self.attestKnows = attestKnows
    }
}

public struct SpeakerLabel: Decodable, Identifiable, Equatable, Sendable {
    public var label: String
    public var personId: String?
    public var name: String?
    /// `auto`, `user`, `enrollment`, `llm`, or nil (unknown).
    public var source: String?
    public var distance: Double?
    public var margin: Double?
    public var evidenceS: Double?
    public var clipId: String?
    public var excerpt: String?
    public var id: String { label }
    public var isAuto: Bool { source == "auto" }
}

public struct ConversationSpeakers: Decodable, Equatable, Sendable {
    public var revision: Int
    public var transcriptSha: String?
    public var labels: [SpeakerLabel]
    public var audioAvailable: Bool?
}

public struct AssignSpeakerRequest: Encodable, Sendable {
    /// nil unassigns the label (encoded as an explicit `null`).
    public var personId: String?
    public var notPersonId: String?
    public var expectedRevision: Int
    /// Client-minted; the server dedupes sample creation on it.
    public var requestId: String

    public init(personId: String?, notPersonId: String? = nil, expectedRevision: Int, requestId: String = UUID().uuidString.lowercased()) {
        self.personId = personId
        self.notPersonId = notPersonId
        self.expectedRevision = expectedRevision
        self.requestId = requestId
    }

    enum CodingKeys: String, CodingKey { case personId, notPersonId, expectedRevision, requestId }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let personId { try c.encode(personId, forKey: .personId) } else { try c.encodeNil(forKey: .personId) }
        try c.encodeIfPresent(notPersonId, forKey: .notPersonId)
        try c.encode(expectedRevision, forKey: .expectedRevision)
        try c.encode(requestId, forKey: .requestId)
    }
}

public struct SpeakerSuggestion: Decodable, Identifiable, Equatable, Sendable {
    public var id: String
    /// `is_this_you`, `who_is_this`, `is_this_person`.
    public var kind: String
    public var personId: String?
    public var clipId: String?
    public var seconds: Double?
    public var excerpt: String?
    public var conversations: Int?
    public var days: Int?
}

public struct SuggestionsResponse: Decodable, Sendable { public var suggestions: [SpeakerSuggestion] }

public struct SpeakerSettings: Codable, Equatable, Sendable {
    public var acknowledgedAt: String?
    public var unknownVoicesEnabled: Bool
    public var autoAssign: Bool

    public init(acknowledgedAt: String? = nil, unknownVoicesEnabled: Bool = false, autoAssign: Bool = true) {
        self.acknowledgedAt = acknowledgedAt
        self.unknownVoicesEnabled = unknownVoicesEnabled
        self.autoAssign = autoAssign
    }

    public var acknowledged: Bool { acknowledgedAt != nil }
}

public struct EnrollmentStatus: Decodable, Equatable, Sendable {
    /// `waiting_audio` and `processing` while the server works; then `accepted`,
    /// `needs_another_sample`, `cancelled`, or `interrupted`.
    public var state: String
    public var speechS: Double?
    public var reason: String?

    public init(state: String, speechS: Double? = nil, reason: String? = nil) {
        self.state = state
        self.speechS = speechS
        self.reason = reason
    }

    public var isFinal: Bool { state != "waiting_audio" && state != "processing" }
}
