import Foundation

// The 声纹 hub's API models (docs/speaker-learning.md, "Voices hub" and "API"). Everything the server
// added for it is optional here: the phone may meet a server that doesn't send it yet.

/// How well a person's voice is recognized on held-out conversations (`people[].measured`). The server
/// gives it only when it counted something; there is no pooled accuracy.
public struct MeasuredPerformance: Codable, Equatable, Hashable, Sendable {
    /// Held-out conversations where the person was named (a miss is an error).
    public var conversations: Int?
    /// Lower bound of the share found there (0…1), nil without positives.
    public var foundAtLeast: Double?
    /// Held-out conversations naming only other people (naming this person is an error).
    public var negativeConversations: Int?
    /// Upper bound of the share wrongly named there (0…1).
    public var wrongAtMost: Double?
    public var targetAbsentConversations: Int?
    public var confidence: Double?

    public init(conversations: Int? = nil, foundAtLeast: Double? = nil, negativeConversations: Int? = nil,
                wrongAtMost: Double? = nil, targetAbsentConversations: Int? = nil, confidence: Double? = nil) {
        self.conversations = conversations
        self.foundAtLeast = foundAtLeast
        self.negativeConversations = negativeConversations
        self.wrongAtMost = wrongAtMost
        self.targetAbsentConversations = targetAbsentConversations
        self.confidence = confidence
    }

    /// "35 段 · 认出 ≥ 71% · 误认 ≤ 8%": the held-out conversations and only the bounds they support,
    /// each rounded the conservative way. nil when nothing was counted or no bound exists.
    public var compactLine: String? {
        let found = (conversations ?? 0) > 0 ? foundAtLeast : nil
        let wrong = (negativeConversations ?? 0) > 0 ? wrongAtMost : nil
        guard found != nil || wrong != nil else { return nil }
        let held = (found != nil ? conversations ?? 0 : 0) + (wrong != nil ? negativeConversations ?? 0 : 0)
        var parts = ["\(held) 段"]
        if let found { parts.append("认出 ≥ \(Int((found * 100 + 1e-9).rounded(.down)))%") }
        if let wrong { parts.append("误认 ≤ \(Int((wrong * 100 - 1e-9).rounded(.up)))%") }
        return parts.joined(separator: " · ")
    }
}

/// Why the server doubts a sample (`flag`). A flag only orders the review queue.
public struct SampleFlag: Decodable, Equatable, Hashable, Sendable {
    public var reasons: [String]?
    /// Still waiting for an answer (a confirmed flag stays with `open: false`).
    public var open: Bool?
}

/// One voice sample of a person (`GET /v1/people/{id}/samples`).
public struct VoiceSample: Decodable, Identifiable, Equatable, Hashable, Sendable {
    public enum State: Equatable, Sendable { case active, removed, moved, other(String) }

    public var id: String
    public var personId: String?
    public var state: String?
    public var revision: Int?
    /// `enrollment`, `user`, `import`, …
    public var source: String?
    public var seconds: Double?
    public var createdAt: String?
    public var day: String?
    public var label: String?
    public var flag: SampleFlag?
    public var movedTo: String?
    public var movedFrom: String?
    /// The server can cut this sample's clip from raw audio; false keeps only the caption.
    public var playable: Bool?
    public var clip: SpeakerClip?
    /// The transcript phrase the sample overlaps (empty when nothing does).
    public var text: String?
    public var conversation: ConversationContext?
    public var device: String?
    /// The review item that answers this sample (`POST /v1/speakers/review/{id}`).
    public var reviewId: String?

    public init(id: String, personId: String? = nil, state: String? = nil, revision: Int? = nil, seconds: Double? = nil,
                createdAt: String? = nil, flag: SampleFlag? = nil, playable: Bool? = nil, clip: SpeakerClip? = nil,
                text: String? = nil, conversation: ConversationContext? = nil, reviewId: String? = nil) {
        self.id = id
        self.personId = personId
        self.state = state
        self.revision = revision
        self.seconds = seconds
        self.createdAt = createdAt
        self.flag = flag
        self.playable = playable
        self.clip = clip
        self.text = text
        self.conversation = conversation
        self.reviewId = reviewId
    }

    /// An absent state is active (the vault's default).
    public var sampleState: State {
        switch state ?? "active" {
        case "active": return .active
        case "removed": return .removed
        case "moved": return .moved
        case let other: return .other(other)
        }
    }

    public var isFlagged: Bool { flag.map { $0.open ?? !($0.reasons ?? []).isEmpty } ?? false }
    /// Only what the server says it can play; audio is never made up.
    public var canPlay: Bool { playable == true && clip != nil }
    public var flagReasons: [String] { isFlagged ? flag?.reasons ?? [] : [] }
}

public struct VoiceSamplesResponse: Decodable, Sendable { public var samples: [VoiceSample] }

/// One question of the review queue (`GET /v1/speakers/review`): a sample, or a conversation's
/// speaker the server named (or thinks may be) this person. The id is opaque and bound to a revision.
public struct ReviewItem: Decodable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    /// `sample` or `label`.
    public var kind: String?
    public var personId: String?
    public var sampleId: String?
    public var label: String?
    public var reasons: [String]?
    public var playable: Bool?
    public var clip: SpeakerClip?
    /// The transcript phrase the clip overlaps.
    public var text: String?
    public var conversation: ConversationContext?
    public var device: String?
    public var source: String?

    public init(id: String, kind: String? = nil, personId: String? = nil, sampleId: String? = nil, label: String? = nil,
                reasons: [String]? = nil, playable: Bool? = nil, clip: SpeakerClip? = nil, text: String? = nil,
                conversation: ConversationContext? = nil) {
        self.id = id
        self.kind = kind
        self.personId = personId
        self.sampleId = sampleId
        self.label = label
        self.reasons = reasons
        self.playable = playable
        self.clip = clip
        self.text = text
        self.conversation = conversation
    }

    public var canPlay: Bool { playable == true && clip != nil }
    /// Flagged by the calibration (pitch, score, enrollment), as opposed to a recent automatic name.
    public var isSuspicious: Bool { (reasons ?? []).contains { !VoicesHub.namingReasons.contains($0) } }
}

public struct ReviewItemsResponse: Decodable, Sendable { public var items: [ReviewItem] }

/// `POST /v1/speakers/review/{id}`.
public struct ReviewDecisionAnswer: Decodable, Equatable, Sendable {
    public var itemId: String?
    public var decision: String?
    public var requestId: String?
    /// What `POST /v1/speakers/undo` takes as `request_id`.
    public var undoToken: String?
}

/// `POST /v1/samples/{id}/remove|restore|move`.
public struct SampleActionAnswer: Decodable, Equatable, Sendable {
    public var sample: VoiceSample?
    public var requestId: String?
    public var undoToken: String?
}

/// The hub's display rules.
public enum VoicesHub {
    /// Reasons a label item carries because of naming, not doubt.
    static let namingReasons: Set<String> = ["auto", "possible"]

    /// Your card first, then everyone else in the server's order.
    public static func cards(_ people: [Person]) -> [Person] {
        people.filter(\.isMe) + people.filter { !$0.isMe }
    }

    /// Flagged samples waiting for an answer, over everyone.
    public static func pendingReview(_ people: [Person]) -> Int {
        people.reduce(0) { $0 + ($1.reviewCount ?? 0) }
    }

    /// Held-out counts and bounds, only from a server that calibrates and only when it counted any.
    public static func measuredLine(_ person: Person, calibrationSupported: Bool) -> String? {
        calibrationSupported ? person.measured?.compactLine : nil
    }

    /// "今天 03:10", "昨天 03:10", "11-02", or "2025-11-02" in the phone's time zone.
    public static func shortTime(_ iso: String?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let iso, let date = ISO8601UTC.parse(iso) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let two = { (n: Int?) in String(format: "%02d", n ?? 0) }
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(two(c.hour)):\(two(c.minute))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(two(c.hour)):\(two(c.minute))"
        }
        if c.year == calendar.component(.year, from: now) { return "\(two(c.month))-\(two(c.day))" }
        return "\(c.year ?? 0)-\(two(c.month))-\(two(c.day))"
    }

    /// A flag or review reason in a word or two.
    public static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "pitch": return "音高不同"
        case "score": return "不太像"
        case "enrollment": return "不像录入"
        case "auto": return "自动命名"
        case "possible": return "可能是"
        default: return "可疑"
        }
    }
}

/// One batch of the review queue.
public enum ReviewBatch {
    public static let size = 10

    /// The server's order (it puts suspicious items first), without repeats or what was skipped.
    public static func make(_ items: [ReviewItem], excluding skipped: Set<String>, limit: Int = size) -> [ReviewItem] {
        var seen = skipped
        var out: [ReviewItem] = []
        for item in items where out.count < limit && seen.insert(item.id).inserted {
            out.append(item)
        }
        return out
    }
}
