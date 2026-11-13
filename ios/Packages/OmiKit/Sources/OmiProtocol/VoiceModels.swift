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
    /// A moved sample's copy (`{person_id, sample_id}`).
    public var movedTo: SampleRef?
    /// Where this copy came from (`{person_id, sample_id, import_id?}`).
    public var movedFrom: SampleRef?

    /// One sample of one person.
    public struct SampleRef: Decodable, Equatable, Hashable, Sendable {
        public var personId: String?
        public var sampleId: String?
    }
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
    /// The name of the person asked about (servers from 5410801; null without a person).
    public var personName: String?
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
    /// The conversation's speakers revision and transcript a label item was made against, when the
    /// server sends them (otherwise the revision is read from the id, `reviewedRevision`).
    public var speakersRevision: Int?
    public var transcriptSha: String?

    /// The speakers revision this label item was reviewed against: the server's field, else the
    /// documented id `l.<conversation>.<label>.<speakers revision>.<person>.<evidence>`.
    public var reviewedRevision: Int? {
        if let speakersRevision { return speakersRevision }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.first == "l", parts.count >= 6 else { return nil }
        return Int(parts[parts.count - 3])
    }

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

/// One page of the review queue. A server with paging (`offset`) adds where the next page starts
/// (`next_offset`, null at the end) and the queue's size (`total`); an older one sends items only.
public struct ReviewItemsResponse: Decodable, Sendable {
    public var items: [ReviewItem]
    public var nextOffset: Int?
    public var total: Int?

    public init(items: [ReviewItem], nextOffset: Int? = nil, total: Int? = nil) {
        self.items = items
        self.nextOffset = nextOffset
        self.total = total
    }

    /// The server pages (so a null `next_offset` means the end, not "unknown").
    public var paginated: Bool { total != nil || nextOffset != nil }
}

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

    /// What the review card asks.
    public enum ReviewQuestion: Equatable, Sendable {
        /// "是 Alan 吗？"
        case isThis(personId: String, name: String)
        /// No one to name: "这是谁？" with a person picker, never a placeholder name.
        case whoIsThis
    }

    /// The item's own name first (it never depends on the people list having loaded), then the people list.
    public static func reviewQuestion(_ item: ReviewItem, people: [Person]) -> ReviewQuestion {
        guard let pid = item.personId else { return .whoIsThis }
        let candidates = [item.personName, people.first { $0.id == pid }?.name]
        guard let name = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else {
            return .whoIsThis
        }
        return .isThis(personId: pid, name: name)
    }

    /// Your card first, then everyone else in the server's order.
    public static func cards(_ people: [Person]) -> [Person] {
        people.filter(\.isMe) + people.filter { !$0.isMe }
    }

    /// Flagged samples waiting for an answer, over everyone.
    public static func pendingReview(_ people: [Person]) -> Int {
        people.reduce(0) { $0 + ($1.reviewCount ?? 0) }
    }

    /// Held-out counts and bounds, only from a server that calibrates, only when it counted any, and only
    /// for an active person: an inactive one's measurement is of the gated decision, which names nobody
    /// ("认出 ≥ 0%" would read as a broken model).
    public static func measuredLine(_ person: Person, calibrationSupported: Bool) -> String? {
        calibrationSupported && person.autoActive == true ? person.measured?.compactLine : nil
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

    /// The review card's count: the server's queue total (under the card's 待确认) when it sends one;
    /// otherwise only flagged samples are known, and the badge says so (可疑).
    public static func reviewBadge(total: Int?, flagged: Int) -> String? {
        if let total { return total > 0 ? "\(total)" : nil }
        return flagged > 0 ? "可疑 \(flagged)" : nil
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

/// A 409 from a voices endpoint, by its error code (`"<code>: <detail>"`, as `APIError.http` carries it).
public enum VoiceConflict: Equatable, Sendable {
    /// The item or sample changed since it was listed (`review.py`).
    case staleReview
    /// The person lacks the acknowledgment or their attestation (`review.py`, `imports.py`).
    case consentRequired
    /// An earlier journaled change is still being recovered (`journal.py`, `service.py`).
    case recoveryPending
    /// Forgetting this person hasn't finished (`journal.py`).
    case forgetInProgress
    /// An import of the same audio holds it (`review.py`).
    case superseded
    case other(String)

    public init(_ detail: String) {
        let code = String(detail.prefix { $0 != ":" }).trimmingCharacters(in: .whitespaces)
        switch code {
        case "stale_review": self = .staleReview
        case "consent_required": self = .consentRequired
        case "recovery_pending": self = .recoveryPending
        case "forget_in_progress": self = .forgetInProgress
        case "superseded": self = .superseded
        default: self = .other(code)
        }
    }

    public var message: String {
        switch self {
        case .staleReview: return "刚刚有变化，已重新载入"
        case .consentRequired: return "需要先确认这个人知道声音会被识别"
        case .recoveryPending: return "正在恢复，稍后再试"
        case .forgetInProgress: return "这个人的声音正在忘记，完成后再试"
        case .superseded: return "有一段导入的同一音频占用着它，先移除那一段"
        case .other: return "这个样本刚刚变过，已重新载入"
        }
    }

    /// The list is out of date: fetch it again (the rest wait, or need the owner first).
    public var reloads: Bool {
        switch self {
        case .staleReview, .superseded, .other: return true
        case .consentRequired, .recoveryPending, .forgetInProgress: return false
        }
    }
}

extension UndoNamingResponse {
    /// Why parts of an undo were left as they are, in the backend's words (known ones in Chinese).
    public var skipReasons: [String] {
        let labels = skipped.isEmpty ? [] : ["之后又改过"]
        let samples = (samples?.skipped ?? []).map { s -> String in
            switch s.reason ?? "" {
            case "changed since", "the label changed since", "a moved sample changed since", "a rejected sample changed since",
                 "the moved copy changed since": return "之后又改过"
            case "that person's consent is withdrawn": return "这个人的同意已撤回"
            case "that person was forgotten", "the moved copy was forgotten since": return "已被忘记"
            case "that person's forget hasn't finished": return "正在忘记这个人"
            case "nothing to undo": return "没有可撤销的"
            case "an active import holds overlapping audio from the same source": return "被导入的同一音频占用"
            case let other: return other.isEmpty ? "之后又改过" : other
            }
        }
        var seen = Set<String>()
        return (labels + samples).filter { seen.insert($0).inserted }
    }
}

/// One batch of the review queue.
public enum ReviewBatch {
    public static let size = 10
    /// The most `GET /v1/speakers/review` answers at once. It has no offset or cursor, so the phone
    /// asks for the whole window and pages it in batches of `size`.
    public static let window = 50

    /// The server's order (it puts suspicious items first), without repeats, what was skipped, or anything the server
    /// can't play (an older server's queue, a cached page): nobody is asked to judge a clip they can't hear.
    public static func make(_ items: [ReviewItem], excluding skipped: Set<String>, limit: Int = size) -> [ReviewItem] {
        var seen = skipped
        var out: [ReviewItem] = []
        for item in items where out.count < limit && item.canPlay && seen.insert(item.id).inserted {
            out.append(item)
        }
        return out
    }
}
