import Foundation
import OmiProtocol

/// Home's three views of the list: conversations (the default, which also holds anything not yet known: an
/// undetermined, missing or future kind), the owner talking alone (monologue, dictation) and background.
public enum HomeFilter: String, CaseIterable, Sendable {
    case talk, me, background

    /// Where a row belongs by its recording kind.
    public static func of(_ c: ConversationSummary) -> HomeFilter {
        switch c.recordingClass?.kind {
        case "monologue": .me
        case "passive": .background
        default: .talk
        }
    }
}

/// One day of Home's conversations. Short sessions (under a minute of detected speech) never reach the main list:
/// they fold into one "短片段" row whatever the filter, split by kind when opened. The owner's "less useful" folds
/// into another. Nothing is hidden or deleted: each group opens to the same rows.
public struct HomeDay: Equatable, Sendable {
    public var rows: [ConversationSummary] = []
    public var shortClips: [ConversationSummary] = []
    public var lessUseful: [ConversationSummary] = []

    public static let shortSeconds: Double = 60

    /// `priority` is the owner's choice for a row ("auto", "important", "less_useful"); `filter` picks the main
    /// list's kind (nil: every kind). Short sessions are collected whatever the filter.
    public init(_ all: [ConversationSummary], filter: HomeFilter? = nil, shortSeconds: Double = HomeDay.shortSeconds,
                priority: (ConversationSummary) -> String) {
        for c in all {
            if c.isShort(threshold: shortSeconds) { shortClips.append(c); continue }
            if let filter, HomeFilter.of(c) != filter { continue }
            if priority(c) == "less_useful" { lessUseful.append(c) } else { rows.append(c) }
        }
    }

    /// The folded row's short sessions by kind, in a fixed order, only kinds that occur: 对话, 我, 背景, 未确定.
    public static func byKind(_ clips: [ConversationSummary]) -> [(kind: String, rows: [ConversationSummary])] {
        let order = ["dialogue", "monologue", "passive", "undetermined"]
        func kind(_ c: ConversationSummary) -> String {
            switch c.recordingClass?.kind {
            case "monologue": "monologue"
            case "passive": "passive"
            case "dialogue": "dialogue"
            default: "undetermined"  // undetermined, not classified yet, or a kind this app doesn't know
            }
        }
        return order.compactMap { k in
            let rows = clips.filter { kind($0) == k }
            return rows.isEmpty ? nil : (k, rows)
        }
    }

    /// The folded row's totals: the server's count for the whole day when it has one (independent of what is
    /// loaded and of the filter), never fewer than the rows at hand.
    public static func totals(_ clips: [ConversationSummary], server: ShortDay?) -> ShortDay {
        let local = ShortDay(short: clips.count,
                             deferred: clips.filter { $0.deferred?.isWaiting == true }.count,
                             requested: clips.filter { $0.deferred?.isRequested == true }.count,
                             issues: clips.filter { !($0.issues ?? []).isEmpty || $0.displayState.code == "failed" }.count)
        guard let server else { return local }
        return ShortDay(short: max(server.short, local.short), deferred: max(server.deferred, local.deferred),
                        requested: max(server.requested, local.requested), issues: max(server.issues, local.issues))
    }
}
