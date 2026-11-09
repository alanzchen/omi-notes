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
        reconcileShortDays(with: page.conversations)
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

    /// Every page of a filtered list, following `next_cursor` (at most `maxPages`).
    static func collectPages(maxPages: Int = 50,
                              fetch: (String?) async throws -> RecentConversationsResponse) async throws -> [ConversationSummary] {
        var rows: [ConversationSummary] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try await fetch(cursor)
            let seen = Set(rows.map(\.id))
            rows += page.conversations.filter { !seen.contains($0.id) }
            guard let next = page.nextCursor, next != cursor else { break }
            cursor = next
        }
        return rows
    }

    /// The whole day's short sessions from the server, every page (when the folded row opens, and on each refresh
    /// while it has been opened). Kept apart from the main list: they never enter `recent`.
    public func loadShortSessions(day: String) async {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint, serverStatus?.supportsDeferredTranscription == true, !day.isEmpty else { return }
        let data = dataEpoch
        let api = APIClient(endpoint: endpoint, session: session)
        guard let rows = try? await Self.collectPages(fetch: { cursor in
            try await api.recentConversations(limit: 200, before: cursor, day: day, short: true)
        }), isCurrent(config), data == dataEpoch else { return }
        shortDayRows[day] = rows
    }

    /// Reload every day whose fold has been opened (after a list refresh or a finished request).
    func reloadOpenedShortDays() async {
        for day in shortDayRows.keys.sorted() { await loadShortSessions(day: day) }
    }

    /// A fresher copy of rows (a list page, a loaded note) replaces the loaded day rows with the same id.
    func reconcileShortDays(with fresh: [ConversationSummary]) {
        guard !shortDayRows.isEmpty, !fresh.isEmpty else { return }
        let byId = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (day, rows) in shortDayRows {
            shortDayRows[day] = rows.map { byId[$0.id] ?? $0 }
        }
    }

    /// Edit a conversation's row wherever it is shown: the main list and any loaded day.
    func updateRow(_ id: String, _ change: (inout ConversationSummary) -> Void) {
        if let i = recent.firstIndex(where: { $0.id == id }) { change(&recent[i]) }
        for (day, rows) in shortDayRows {
            if let i = rows.firstIndex(where: { $0.id == id }) { change(&shortDayRows[day]![i]) }
        }
    }

    /// The freshest row for a conversation: the main list's, else a loaded day's, else the one given.
    public func row(of c: ConversationSummary) -> ConversationSummary {
        recent.first { $0.id == c.id } ?? shortDayRows.values.joined().first { $0.id == c.id } ?? c
    }

    public enum TranscribeState: Equatable, Sendable {
        /// Nothing to ask (it has its result) or the server can't be asked.
        case none, unavailable
        /// 转写 can be tapped; the message is why the last request failed, shown beside it.
        case offer(String?)
        /// Asked: waiting for the server.
        case asked
    }

    /// What a short session's row offers: 转写, a spinner while asked, the refusal beside 转写 again, or nothing
    /// once it has a note (a finished request whose refreshed row still says deferred stays "asked" until then).
    public func transcribeState(of c: ConversationSummary) -> TranscribeState {
        let fresh = row(of: c)
        guard let deferred = fresh.deferred else { return .none }
        let op = retries[c.id].flatMap { $0.kind == "transcribe" ? $0 : nil }
        if let op, !op.isFinished { return .asked }
        if let op, op.state == "failed" { return .offer(op.message ?? "Transcription failed") }
        if let message = retryMessages[c.id] { return .offer(message) }
        if deferred.isRequested || op?.state == "done" { return .asked }
        return canTranscribeDeferred ? .offer(nil) : .unavailable
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
