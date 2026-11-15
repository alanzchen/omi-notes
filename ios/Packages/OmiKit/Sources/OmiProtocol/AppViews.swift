import Foundation

// Read-only app views (capture-format-v1.md, "App views"). Every field the server may add later is
// optional, and an unknown state string is kept as-is rather than failing the decode.

/// `GET /v1/conversations/{id}`: the list entry plus the note's content.
public struct ConversationDetail: Codable, Equatable, Sendable, Identifiable {
    public struct Summary: Codable, Equatable, Sendable {
        public struct Section: Codable, Equatable, Sendable, Hashable {
            public var heading: String
            public var bullets: [String]
        }
        public struct ActionItem: Codable, Equatable, Sendable, Hashable {
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
        /// Something dictated to an AI assistant: a proposal for it, never one of the owner's tasks.
        public struct AssistantRequest: Codable, Equatable, Sendable, Hashable {
            public var description: String
        }
        public var overview: String
        public var sections: [Section]
        public var actionItems: [ActionItem]
        /// Nil from servers before assistant requests were listed apart.
        public var assistantRequests: [AssistantRequest]?
        public var decisions: [String]
        public var openQuestions: [String]

        enum CodingKeys: String, CodingKey {
            case overview, sections, decisions
            case actionItems = "action_items"
            case assistantRequests = "assistant_requests"
            case openQuestions = "open_questions"
        }
    }

    public struct Speaker: Codable, Equatable, Sendable, Hashable {
        public var label: String
        public var name: String?
    }

    public struct Segment: Codable, Equatable, Sendable, Hashable {
        public var start: String
        public var end: String
        public var speaker: String
        public var name: String?
        public var text: String
    }

    /// A stretch of speech neither transcription model had words for (`partial_transcript`), where it was.
    public struct Gap: Codable, Equatable, Sendable, Hashable {
        public var start: String
        public var end: String
        public var speechS: Double
        enum CodingKeys: String, CodingKey {
            case start, end
            case speechS = "speech_s"
        }
    }

    /// One line of the transcript as shown: a segment (by index), or a gap where it falls between them.
    public enum TranscriptRow: Equatable, Sendable {
        case segment(Int)
        case gap(Gap)
    }

    public struct Transcript: Codable, Equatable, Sendable {
        public var total: Int
        public var from: Int
        /// `segments_from` of the next page; nil on the last one.
        public var nextFrom: Int?
        public var segments: [Segment]
        /// Speech without words received so far (each page carries the stretches it owns; absent: none known).
        public var untranscribed: [Gap]?
        /// The server didn't list every stretch (unreadable, or more than a page carries).
        public var untranscribedIncomplete: Bool?

        enum CodingKeys: String, CodingKey {
            case total, from, segments, untranscribed
            case nextFrom = "next_from"
            case untranscribedIncomplete = "untranscribed_incomplete"
        }

        /// The lines as shown: the segments, each gap before the first segment that starts after it; a gap after the
        /// last segment loaded appears once every page is in. Prepared when the transcript arrives or grows
        /// (`prepare`), never while a view draws (ASTRA-20261115-IT2-01).
        public private(set) var rows: [TranscriptRow] = []
        /// Some gap metadata on this phone couldn't be used (malformed, impossible): not every stretch is shown.
        public private(set) var droppedGaps = false

        public init(total: Int, from: Int, nextFrom: Int?, segments: [Segment], untranscribed: [Gap]? = nil,
                    untranscribedIncomplete: Bool? = nil) {  // fmt: skip
            self.total = total
            self.from = from
            self.nextFrom = nextFrom
            self.segments = segments
            self.untranscribed = untranscribed
            self.untranscribedIncomplete = untranscribedIncomplete
            prepare()
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = try c.decode(Int.self, forKey: .total)
            from = try c.decode(Int.self, forKey: .from)
            nextFrom = try c.decodeIfPresent(Int.self, forKey: .nextFrom)
            segments = try c.decode([Segment].self, forKey: .segments)
            untranscribed = try c.decodeIfPresent([Gap].self, forKey: .untranscribed)
            untranscribedIncomplete = try c.decodeIfPresent(Bool.self, forKey: .untranscribedIncomplete)
            prepare()
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(total, forKey: .total)
            try c.encode(from, forKey: .from)
            try c.encode(nextFrom, forKey: .nextFrom)
            try c.encode(segments, forKey: .segments)
            try c.encodeIfPresent(untranscribed, forKey: .untranscribed)
            try c.encodeIfPresent(untranscribedIncomplete, forKey: .untranscribedIncomplete)
        }

        /// The next page added: its segments, and its stretches merged with those already here (once each).
        public mutating func append(_ page: Transcript) {
            segments += page.segments
            nextFrom = page.nextFrom
            total = page.total
            if let more = page.untranscribed {  // a stretch already here (a repeated page) isn't kept twice
                var known = untranscribed ?? []
                var seen = Set(known)
                known += more.filter { seen.insert($0).inserted }
                untranscribed = known
            }
            if page.untranscribedIncomplete == true { untranscribedIncomplete = true }
            prepare()
        }

        /// Rows from segments and gaps. No gaps: the segments as they are (no date read). Gaps: each read once, the
        /// impossible ones left out (not finite, reversed, empty, speech of zero or less or more than the stretch),
        /// exact repeats once, overlapping ones as one stretch (its speech never more than its length), then merged
        /// with the segments by index (ASTRA-20261115-IT2-03).
        mutating func prepare() {
            guard let gaps = untranscribed, !gaps.isEmpty else {
                rows = segments.indices.map(TranscriptRow.segment)
                droppedGaps = false
                return
            }
            var valid: [(a: Double, b: Double, gap: Gap)] = []
            var dropped = false
            for g in gaps {
                guard let a = ISO8601UTC.parse(g.start)?.timeIntervalSince1970, let b = ISO8601UTC.parse(g.end)?.timeIntervalSince1970,
                      a.isFinite, b.isFinite, b > a, g.speechS.isFinite, g.speechS > 0, g.speechS <= (b - a) + 0.5 else {
                    dropped = true
                    continue
                }
                valid.append((a, b, g))
            }
            valid.sort { ($0.a, $0.b) < ($1.a, $1.b) }
            var merged: [(a: Double, b: Double, gap: Gap)] = []
            for v in valid {
                if let last = merged.last, v.a < last.b || (v.a == last.a && v.b == last.b) {
                    let b = max(last.b, v.b)
                    var gap = last.gap
                    if b > last.b { gap.end = v.gap.end }
                    let repeated = v.a == last.a && v.b == last.b  // the same stretch twice: the same speech
                    gap.speechS = min(repeated ? max(last.gap.speechS, v.gap.speechS) : last.gap.speechS + v.gap.speechS, b - last.a)
                    merged[merged.count - 1] = (last.a, b, gap)
                } else {
                    merged.append(v)
                }
            }
            var out: [TranscriptRow] = []
            out.reserveCapacity(segments.count + merged.count)
            var next = 0
            for (i, seg) in segments.enumerated() {
                let at = ISO8601UTC.parse(seg.start)?.timeIntervalSince1970 ?? -.infinity
                while next < merged.count, merged[next].a < at { out.append(.gap(merged[next].gap)); next += 1 }
                out.append(.segment(i))
            }
            if nextFrom == nil { out += merged[next...].map { TranscriptRow.gap($0.gap) } }
            rows = out
            droppedGaps = dropped
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
    /// How the owner resolved it from the phone, with the condition it resolved (kept as history).
    public var resolution: Resolution?
    /// Why the summary thinks it's worth revisiting, and the spans to revisit (`value_notes`).
    public var valueReasons: [String]?
    public var highlights: [ConversationHighlight]?

    /// `resolution`: e.g. kept as a transcript with the speaker unknown.
    public struct Resolution: Codable, Equatable, Sendable {
        public struct Original: Codable, Equatable, Sendable {
            public var code: String?
            public var stage: String?
            public var message: String?
        }
        public var kind: String
        public var resolvedAt: String?
        public var message: String?
        public var original: Original?

        enum CodingKeys: String, CodingKey {
            case kind, message, original
            case resolvedAt = "resolved_at"
        }
    }

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
        case speakers, transcript, resolution
        case valueReasons = "value_reasons"
        case highlights
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
        resolution = try? c.decodeIfPresent(Resolution.self, forKey: .resolution)
        valueReasons = try? c.decodeIfPresent([String].self, forKey: .valueReasons)
        highlights = try? c.decodeIfPresent([ConversationHighlight].self, forKey: .highlights)
    }

    /// The same flat shape the server sends (so a saved copy decodes like a fresh one).
    public func encode(to encoder: Encoder) throws {
        try entry.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(speechS, forKey: .speechS)
        try c.encodeIfPresent(lostS, forKey: .lostS)
        try c.encodeIfPresent(noteState, forKey: .noteState)
        try c.encodeIfPresent(noteFrozen, forKey: .noteFrozen)
        try c.encodeIfPresent(myNotes, forKey: .myNotes)
        try c.encodeIfPresent(myNotesUnreadable, forKey: .myNotesUnreadable)
        try c.encodeIfPresent(discardReason, forKey: .discardReason)
        try c.encodeIfPresent(transcriptSha, forKey: .transcriptSha)
        try c.encodeIfPresent(speakersRevision, forKey: .speakersRevision)
        try c.encodeIfPresent(revision, forKey: .revision)
        try c.encode(summaryState, forKey: .summaryState)
        try c.encodeIfPresent(summaryError, forKey: .summaryError)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(transcriptState, forKey: .transcriptState)
        try c.encode(speakers, forKey: .speakers)
        try c.encodeIfPresent(transcript, forKey: .transcript)
        try c.encodeIfPresent(resolution, forKey: .resolution)
        try c.encodeIfPresent(valueReasons, forKey: .valueReasons)
        try c.encodeIfPresent(highlights, forKey: .highlights)
    }

    /// Everything the server has is loaded (a saved copy may hold only the first transcript pages).
    public var transcriptComplete: Bool { transcript.map { $0.nextFrom == nil } ?? true }

    /// The display name of a speaker label: the person, else "Speaker N".
    public func speakerName(_ label: String) -> String {
        speakers.first { $0.label == label }?.name ?? Self.anonymous(label)
    }

    public static func anonymous(_ label: String) -> String {
        if label == "unknown" { return "Speaker unknown" }  // no speaker was separated
        return label.hasPrefix("S") && Int(label.dropFirst()) != nil ? "Speaker \(label.dropFirst())" : label
    }

    /// Appends the next transcript page (ignored unless it continues this one).
    public mutating func append(_ page: Transcript) {
        guard var current = transcript, page.from == current.from + current.segments.count else { return }
        current.append(page)
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
    /// The server operator's step, with this deployment's commands (shown under Diagnostics).
    public var serverStep: String?
    /// False when a retry from the phone can't help until the server changes; missing means true.
    public var retryable: Bool?
    /// The phone can keep it as is (a no-speaker result kept as a transcript); missing means false.
    public var canKeep: Bool?
    /// The phone can set this failure aside (servers with `dismiss`); missing means false.
    public var canDismiss: Bool?
    /// The failure this issue is about (sent with a dismissal, so it can't act on a later failure).
    public var failureId: String?

    public var id: String { "\(code):\(conversationId ?? "")" }
    public var needsAction: Bool { severity != "delayed" }
    public var canRetryFromPhone: Bool { retryable != false }
    public var canKeepFromPhone: Bool { canKeep == true }
    public var canDismissFromPhone: Bool { canDismiss == true }
    /// Plain guidance for the main screens; an older server's command-bearing step is left to Diagnostics.
    public var phoneStep: String? { nextStep.flatMap { $0.contains("`") ? nil : $0 } }
    /// What the server's operator does (Diagnostics).
    public var technicalStep: String? { serverStep ?? nextStep.flatMap { $0.contains("`") ? $0 : nil } }

    enum CodingKeys: String, CodingKey {
        case code, severity, message, detail, count, title, retryable
        case canKeep = "can_keep"
        case canDismiss = "can_dismiss"
        case failureId = "failure_id"
        case serverStep = "server_step"
        case nextStep = "next_step"
        case conversationId = "conversation_id"
        case startedAt = "started_at"
    }
}

public struct ServerIssuesResponse: Decodable, Equatable, Sendable {
    public var issues: [ServerIssue]
}

/// A durable app retry or keep (`POST /v1/conversations/{id}/retry` or `/keep`, `GET /v1/operations/{id}`).
public struct RetryOperation: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: String?
    public var conversationId: String?
    public var stage: String?
    /// `accepted`, `queued`, `running`, `backing_off`, `blocked`, `done`, `failed`, `superseded`.
    public var state: String
    public var requestedAt: String?
    public var finishedAt: String?
    public var message: String?

    public var isFinished: Bool { ["done", "failed", "superseded"].contains(state) }

    public init(id: String, kind: String? = nil, conversationId: String? = nil, stage: String? = nil, state: String,
                requestedAt: String? = nil, finishedAt: String? = nil, message: String? = nil) {
        self.id = id; self.kind = kind; self.conversationId = conversationId; self.stage = stage; self.state = state
        self.requestedAt = requestedAt; self.finishedAt = finishedAt; self.message = message
    }

    /// Worded from the state (an older server said "Waiting for the server to start" for queued work).
    public var displayMessage: String {
        switch state {
        case "accepted", "queued": return "Queued on the server"
        case "running": return kind == "keep" ? "Keeping it now" : kind == "transcribe" ? "Transcribing now" : "Retrying now"
        default: return message ?? state
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, stage, state, message
        case conversationId = "conversation_id"
        case requestedAt = "requested_at"
        case finishedAt = "finished_at"
    }
}

public struct RetryOperationResponse: Decodable, Equatable, Sendable {
    public var operation: RetryOperation
}

public struct ChunkRetryResponse: Decodable, Equatable, Sendable {
    public var chunksQueued: Int
    enum CodingKeys: String, CodingKey { case chunksQueued = "chunks_queued" }
}

/// `GET /v1/conversations/search`: a page like `/recent`, plus how many aren't searchable yet.
public struct SearchResponse: Decodable, Equatable, Sendable {
    public var conversations: [ConversationSummary]
    public var nextCursor: String?
    public var pending: Int?

    enum CodingKeys: String, CodingKey {
        case conversations, pending
        case nextCursor = "next_cursor"
    }
}

/// `GET /v1/stats?days=7`: kept conversations per local day on the server.
public struct ServerStats: Decodable, Equatable, Sendable {
    public struct Day: Decodable, Equatable, Sendable, Identifiable {
        public var date: String
        public var conversations: Int
        /// Start to end of each conversation, summed.
        public var conversationS: Double
        /// Detected speech only.
        public var speechS: Double
        public var people: Int
        public var id: String { date }

        enum CodingKeys: String, CodingKey {
            case date, conversations, people
            case conversationS = "conversation_s"
            case speechS = "speech_s"
        }
    }
    public struct Totals: Decodable, Equatable, Sendable {
        public var conversations: Int
        public var conversationS: Double
        public var speechS: Double
        public var people: Int
        enum CodingKeys: String, CodingKey {
            case conversations, people
            case conversationS = "conversation_s"
            case speechS = "speech_s"
        }
    }
    public var days: [Day]
    public var totals: Totals
}
