import Foundation

// Read-only app views (capture-format-v1.md, "App views"). Every field the server may add later is
// optional, and an unknown state string is kept as-is rather than failing the decode.

/// `GET /v1/conversations/{id}`: the list entry plus the note's content.
public struct ConversationDetail: Decodable, Equatable, Sendable, Identifiable {
    public struct Summary: Decodable, Equatable, Sendable {
        public struct Section: Decodable, Equatable, Sendable, Hashable {
            public var heading: String
            public var bullets: [String]
        }
        public struct ActionItem: Decodable, Equatable, Sendable, Hashable {
            public var description: String
            /// `me`, `other` or `unknown`.
            public var owner: String?
            public var ownerName: String?
            public var dueDate: String?

            enum CodingKeys: String, CodingKey {
                case description, owner
                case ownerName = "owner_name"
                case dueDate = "due_date"
            }
        }
        public var overview: String
        public var sections: [Section]
        public var actionItems: [ActionItem]
        public var decisions: [String]
        public var openQuestions: [String]

        enum CodingKeys: String, CodingKey {
            case overview, sections, decisions
            case actionItems = "action_items"
            case openQuestions = "open_questions"
        }
    }

    public struct Speaker: Decodable, Equatable, Sendable, Hashable {
        public var label: String
        public var name: String?
    }

    public struct Segment: Decodable, Equatable, Sendable, Hashable {
        public var start: String
        public var end: String
        public var speaker: String
        public var name: String?
        public var text: String
    }

    public struct Transcript: Decodable, Equatable, Sendable {
        public var total: Int
        public var from: Int
        /// `segments_from` of the next page; nil on the last one.
        public var nextFrom: Int?
        public var segments: [Segment]

        enum CodingKeys: String, CodingKey {
            case total, from, segments
            case nextFrom = "next_from"
        }
    }

    public var entry: ConversationSummary
    public var speechS: Double?
    public var lostS: Double?
    /// `none`, `matches`, `differs` (edited elsewhere) or `missing`.
    public var noteState: String?
    public var noteFrozen: Bool?
    public var myNotes: String?
    public var myNotesUnreadable: Bool?
    public var discardReason: String?
    public var transcriptSha: String?
    public var speakersRevision: Int?
    public var revision: Int?
    /// `ready`, `pending`, `disabled`, `failed`, `not_applicable`, `updating`, `unavailable`.
    public var summaryState: String
    public var summaryError: String?
    public var summary: Summary?
    /// `ready`, `pending`, `updating`, `unavailable`.
    public var transcriptState: String
    public var speakers: [Speaker]
    public var transcript: Transcript?

    public var id: String { entry.id }

    enum CodingKeys: String, CodingKey {
        case speechS = "speech_s"
        case lostS = "lost_s"
        case noteState = "note_state"
        case noteFrozen = "note_frozen"
        case myNotes = "my_notes"
        case myNotesUnreadable = "my_notes_unreadable"
        case discardReason = "discard_reason"
        case transcriptSha = "transcript_sha"
        case speakersRevision = "speakers_revision"
        case revision
        case summaryState = "summary_state"
        case summaryError = "summary_error"
        case summary
        case transcriptState = "transcript_state"
        case speakers, transcript
    }

    public init(from decoder: Decoder) throws {
        entry = try ConversationSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speechS = try c.decodeIfPresent(Double.self, forKey: .speechS)
        lostS = try c.decodeIfPresent(Double.self, forKey: .lostS)
        noteState = try c.decodeIfPresent(String.self, forKey: .noteState)
        noteFrozen = try c.decodeIfPresent(Bool.self, forKey: .noteFrozen)
        myNotes = try c.decodeIfPresent(String.self, forKey: .myNotes)
        myNotesUnreadable = try c.decodeIfPresent(Bool.self, forKey: .myNotesUnreadable)
        discardReason = try c.decodeIfPresent(String.self, forKey: .discardReason)
        transcriptSha = try c.decodeIfPresent(String.self, forKey: .transcriptSha)
        speakersRevision = try c.decodeIfPresent(Int.self, forKey: .speakersRevision)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        summaryState = try c.decodeIfPresent(String.self, forKey: .summaryState) ?? "unavailable"
        summaryError = try c.decodeIfPresent(String.self, forKey: .summaryError)
        summary = try c.decodeIfPresent(Summary.self, forKey: .summary)
        transcriptState = try c.decodeIfPresent(String.self, forKey: .transcriptState) ?? "unavailable"
        speakers = try c.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        transcript = try c.decodeIfPresent(Transcript.self, forKey: .transcript)
    }

    /// The display name of a speaker label: the person, else "Speaker N".
    public func speakerName(_ label: String) -> String {
        speakers.first { $0.label == label }?.name ?? Self.anonymous(label)
    }

    public static func anonymous(_ label: String) -> String {
        label.hasPrefix("S") && Int(label.dropFirst()) != nil ? "Speaker \(label.dropFirst())" : label
    }

    /// Appends the next transcript page (ignored unless it continues this one).
    public mutating func append(_ page: Transcript) {
        guard var current = transcript, page.from == current.from + current.segments.count else { return }
        current.segments += page.segments
        current.nextFrom = page.nextFrom
        current.total = page.total
        transcript = current
    }
}

/// `GET /v1/issues`: what needs attention on the server, most urgent first.
public struct ServerIssue: Decodable, Equatable, Sendable, Identifiable, Hashable {
    public var code: String
    /// `action` (someone must act) or `delayed` (the server retries on its own).
    public var severity: String
    public var message: String
    public var detail: String?
    public var nextStep: String?
    public var count: Int?
    public var conversationId: String?
    public var startedAt: String?
    public var title: String?

    public var id: String { "\(code):\(conversationId ?? "")" }
    public var needsAction: Bool { severity != "delayed" }

    enum CodingKeys: String, CodingKey {
        case code, severity, message, detail, count, title
        case nextStep = "next_step"
        case conversationId = "conversation_id"
        case startedAt = "started_at"
    }
}

public struct ServerIssuesResponse: Decodable, Equatable, Sendable {
    public var issues: [ServerIssue]
}
