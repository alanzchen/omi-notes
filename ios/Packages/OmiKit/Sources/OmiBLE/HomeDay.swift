import Foundation
import OmiProtocol

/// One day of Home's conversations: short clips (under 30 s) and skipped recordings fold into one
/// collapsed "Short clips (N)" row, and the owner's "less useful" into another. Nothing is hidden or
/// deleted: each group opens to the same rows.
public struct HomeDay: Equatable, Sendable {
    public var rows: [ConversationSummary] = []
    public var shortClips: [ConversationSummary] = []
    public var lessUseful: [ConversationSummary] = []

    public static let shortSeconds: Double = 30

    /// `priority` is the owner's choice for a row ("auto", "important", "less_useful").
    public init(_ all: [ConversationSummary], priority: (ConversationSummary) -> String) {
        for c in all {
            let choice = priority(c)
            if choice == "less_useful" { lessUseful.append(c) }
            else if Self.isShortClip(c, priority: choice) { shortClips.append(c) }
            else { rows.append(c) }
        }
    }

    /// Skipped by the server, or a finished note under 30 s, with nothing wrong. Anything still listening
    /// or processing (it may grow), failed (transcript only, or a failed reprocess beside an older note),
    /// carrying any issue (a note conflict, a render retrying…), or marked important stays in view.
    public static func isShortClip(_ c: ConversationSummary, priority: String = "auto") -> Bool {
        guard priority != "important", (c.issues ?? []).isEmpty else { return false }
        switch (c.status, c.displayState.code) {
        case ("discarded", "discarded"): return true
        case ("done", "ready"): return (c.durationS ?? .infinity) < shortSeconds
        default: return false
        }
    }
}
