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

    /// Skipped by the server, or a finished recording under 30 s. Still listening, processing or failed
    /// stays in view (it may grow, or needs attention), and so does anything marked important.
    public static func isShortClip(_ c: ConversationSummary, priority: String = "auto") -> Bool {
        guard priority != "important" else { return false }
        switch c.displayState.code {
        case "discarded": return true
        case "ready", "transcript_only": return (c.durationS ?? .infinity) < shortSeconds
        default: return false
        }
    }
}
