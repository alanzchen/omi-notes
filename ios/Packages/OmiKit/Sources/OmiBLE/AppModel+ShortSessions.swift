import Foundation
import OmiCapture
import OmiProtocol

/// Short sessions (under a minute of detected speech): deferred on the server, folded into one row per day on Home
/// (capture-format-v1.md, "Deferred short sessions"). The row's counts come from the server's per-day totals, so
/// short failures and requested transcriptions stay visible whatever is loaded or filtered.
extension AppModel {
    public var canTranscribeDeferred: Bool { serverStatus?.supportsDeferredTranscription == true && canRetry }

    func noteShortDays(_ page: RecentConversationsResponse) {
        if let s = page.shortS, s > 0 { shortSeconds = s }
        for (day, counts) in page.days ?? [:] { shortDays[day] = counts }
    }

    /// The server's day for a row (older servers: the phone's local day of its start).
    public func day(of c: ConversationSummary) -> String {
        if let day = c.day { return day }
        guard let start = c.startedDate else { return "" }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: start)
    }

    /// The whole day's short sessions from the server (when the folded row opens), else nothing new.
    public func loadShortSessions(day: String) async {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint, serverStatus?.supportsDeferredTranscription == true, !day.isEmpty else { return }
        let data = dataEpoch
        guard let page = try? await APIClient(endpoint: endpoint, session: session)
            .recentConversations(limit: 200, day: day, short: true),
              isCurrent(config), data == dataEpoch else { return }
        shortDayRows[day] = page.conversations
        noteShortDays(page)
    }

    /// What a list refresh says about a conversation's artifacts (note revision, deferral, state, applied kind): an
    /// open detail checks `detailNeedsReload` whenever this changes.
    public func artifactKey(_ id: String) -> String? {
        guard let row = recent.first(where: { $0.id == id }) ?? shortDayRows.values.joined().first(where: { $0.id == id })
        else { return nil }
        let kind = row.recordingClass
        return [row.revision.map(String.init) ?? "-", row.deferred?.state ?? "-", row.displayState.code, kind?.kind ?? "-",
                kind?.overridden == true ? "o" : "a", kind?.isUpdating == true ? "u" : "s"].joined(separator: "|")
    }

    /// Whether the server rewrote a note since its detail was cached: another note revision (a provisional session
    /// finished, possibly as an entirely new body of the same kind), a deferred session that now has a result, or a
    /// rewrite for the owner's class choice.
    public func detailNeedsReload(_ id: String) -> Bool {
        guard let shown = details[id], let row = recent.first(where: { $0.id == id }) ?? shortDayRows.values.joined().first(where: { $0.id == id })
        else { return false }
        if let revision = row.revision, revision != shown.revision { return true }
        if shown.entry.deferred != nil, row.deferred == nil { return true }
        if shown.entry.displayState.code != row.displayState.code, row.displayState.code == "ready" { return true }
        guard let kind = shown.entry.recordingClass else { return false }
        return !kind.sameTreatment(as: row.recordingClass)
    }
}
