import Foundation

/// A conversation's speakers for the note screen: every named person as a chip, then a few unnamed
/// voices by talk time, the rest folded behind "+N more". Unnamed voices with very little talk time are
/// folded even when there is room, so a recording split into dozens of labels doesn't read as dozens of people.
/// Talk time comes from the transcript segments loaded so far.
public struct SpeakerRoster: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var label: String
        public var name: String?
        /// Seconds of transcript attributed to this label (loaded segments only).
        public var seconds: Double
        public var id: String { label }
        public var displayName: String { name ?? ConversationDetail.anonymous(label) }
    }

    /// Every speaker the conversation lists (and any other label its transcript uses).
    public var count: Int { top.count + rest.count }
    public var top: [Entry]
    public var rest: [Entry]

    /// - Parameters:
    ///   - maxShown: chips at most, unless more people are named (named people are never folded).
    ///   - minShare, minSeconds: an unnamed voice with less talk than `max(minSeconds, minShare × total)` is folded.
    public static func make(speakers: [ConversationDetail.Speaker], segments: [ConversationDetail.Segment],
                            maxShown: Int = 3, minShare: Double = 0.05, minSeconds: Double = 10) -> SpeakerRoster {
        var talk: [String: Double] = [:], names: [String: String] = [:], order: [String] = speakers.map(\.label)
        for s in speakers { if let n = s.name { names[s.label] = n } }
        let iso = ISO8601DateFormatter()  // one for all segments (the view recomputes this)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func parse(_ s: String) -> Date? { iso.date(from: s) ?? ISO8601UTC.parse(s) }
        for seg in segments {
            if !order.contains(seg.speaker) { order.append(seg.speaker) }
            if names[seg.speaker] == nil, let n = seg.name { names[seg.speaker] = n }
            guard let a = parse(seg.start), let b = parse(seg.end) else { continue }
            talk[seg.speaker, default: 0] += max(0, b.timeIntervalSince(a))
        }
        var seen = Set<String>()
        let entries = order.filter { seen.insert($0).inserted }.map { Entry(label: $0, name: names[$0], seconds: talk[$0] ?? 0) }
            .sorted { a, b in
                if (a.name != nil) != (b.name != nil) { return a.name != nil }
                if a.seconds != b.seconds { return a.seconds > b.seconds }
                return labelOrder(a.label, b.label)
            }
        let total = entries.reduce(0) { $0 + $1.seconds }
        let tiny = total > 0 ? max(minSeconds, minShare * total) : 0
        // Named people are always chips; the budget and the low-talk threshold fold unnamed voices only.
        var top = entries.filter { $0.name != nil }, rest: [Entry] = []
        for e in entries where e.name == nil {
            if top.count < maxShown, e.seconds >= tiny { top.append(e) } else { rest.append(e) }
        }
        if top.isEmpty { top = Array(rest.prefix(maxShown)); rest.removeFirst(top.count) }
        if rest.count == 1 { top += rest; rest = [] }  // a chip, not "+1 more"
        return SpeakerRoster(top: top, rest: rest)
    }

    /// "S2" before "S10"; other labels by text.
    static func labelOrder(_ a: String, _ b: String) -> Bool {
        func n(_ s: String) -> Int? { s.hasPrefix("S") ? Int(s.dropFirst()) : nil }
        if let x = n(a), let y = n(b) { return x < y }
        return a < b
    }

    /// "<1s", "45s", "10m", "1h 5m", "2h".
    public static func talkText(_ seconds: Double) -> String {
        if seconds < 1 { return "<1s" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
}
