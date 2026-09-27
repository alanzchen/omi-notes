import Foundation
import OmiCapture
import OmiProtocol

/// Reading saved notes while the server can't be reached, and searching.
extension AppModel {
    /// The cache scope of the current server: its vault from the last answer, else the scope the
    /// cache was last written for when it is this same server configuration.
    func cacheScope(_ config: UploadConfig) -> NoteCache.Scope? {
        guard let url = config.endpoint?.baseURL.absoluteString else { return nil }
        if let vault = serverStatus?.vaultId {
            return NoteCache.Scope(serverURL: url, generation: config.generation, vaultId: vault)
        }
        if let last = noteCache.lastScope, last.serverURL == url, last.generation == config.generation { return last }
        return nil
    }

    func saveForOffline(_ detail: ConversationDetail, _ config: UploadConfig) {
        guard isCurrent(config), let scope = cacheScope(config) else { return }
        noteCache.saveDetail(detail, scope: scope)
    }

    func showSavedList(_ config: UploadConfig) {
        guard let scope = cacheScope(config), let saved = noteCache.recent(scope: scope) else { return }
        recent = saved.value
        recentCursor = nil
        recentSavedAt = saved.savedAt
    }

    func showSavedDetail(_ id: String, _ config: UploadConfig) {
        guard let scope = cacheScope(config), let saved = noteCache.detail(id, scope: scope) else { return }
        details[id] = saved.value
        detailSavedAt[id] = saved.savedAt
    }

    /// Conversations saved on this phone for the current server, newest first.
    public func savedConversations() -> [ConversationDetail] {
        guard let scope = cacheScope(engine.settings.serverConfig()) else { return [] }
        return noteCache.details(scope: scope).map(\.value)
    }

    /// Opens a saved copy (from the offline library).
    public func openSaved(_ detail: ConversationDetail) {
        guard details[detail.id] == nil else { return }
        details[detail.id] = detail
        if let scope = cacheScope(engine.settings.serverConfig()) {
            detailSavedAt[detail.id] = noteCache.detail(detail.id, scope: scope)?.savedAt
        }
    }

    public func clearSavedNotes() {
        cacheEpoch += 1
        noteCache.clear()
        recentSavedAt = nil
        detailSavedAt = [:]
    }

    public struct SearchResult: Sendable {
        public var conversations: [ConversationSummary]
        public var nextCursor: String?
        /// Conversations the server hasn't indexed yet.
        public var pending: Int
        /// Only notes saved on this phone were searched (the server couldn't be reached).
        public var offline: Bool
    }

    public enum SearchRange: String, CaseIterable, Sendable {
        case any, week, month
        public var title: String {
            switch self {
            case .any: return "Any time"
            case .week: return "Past 7 days"
            case .month: return "Past 30 days"
            }
        }
    }

    public enum SearchError: Error, LocalizedError {
        case personNeedsServer
        public var errorDescription: String? {
            "The server can't be reached, and filtering by person needs it. Choose Anyone to search the notes saved on this phone."
        }
    }

    /// Server search, or the saved copies when the server can't be reached. Answers for a server
    /// that is no longer configured, or for a cancelled search, come back as `CancellationError`.
    public func search(_ query: String, personId: String?, range: SearchRange, before: String? = nil) async -> Result<SearchResult, Error> {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint else { return .failure(APIError.notConfigured) }
        var fromDate: Date?
        if range != .any {
            let days = range == .week ? 6 : 29
            fromDate = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date())
        }
        let answer: Result<SearchResponse, Error>
        if serverStatus?.supportsSearch == true || serverStatus == nil {
            answer = await Result {
                try await APIClient(endpoint: endpoint, session: session)
                    .search(query: query, personId: personId, from: fromDate.map(Self.day), before: before)
            }
        } else {
            answer = .failure(APIError.transport("this server doesn't support search"))
        }
        guard !Task.isCancelled, isCurrent(config) else { return .failure(CancellationError()) }
        switch answer {
        case .success(let r):
            return .success(SearchResult(conversations: r.conversations, nextCursor: r.nextCursor, pending: r.pending ?? 0, offline: false))
        case .failure(let error):
            // Only an unreachable server falls back to the saved copies; a refusal is an answer.
            guard case APIError.transport = error, !query.trimmingCharacters(in: .whitespaces).isEmpty,
                  let scope = cacheScope(config) else { return .failure(error) }
            if personId != nil { return .failure(SearchError.personNeedsServer) }
            let rows = noteCache.search(query, scope: scope).map(\.entry)
                .filter { c in fromDate.map { (c.startedDate ?? .distantPast) >= $0 } ?? true }
            return .success(SearchResult(conversations: rows, nextCursor: nil, pending: 0, offline: true))
        }
    }

    /// The server's last 7 days (nil when it doesn't report them).
    public func weekStats() async -> ServerStats? {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint, serverStatus?.supportsStats == true else { return nil }
        let stats = try? await APIClient(endpoint: endpoint, session: session).stats(days: 7)
        return isCurrent(config) ? stats : nil
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
