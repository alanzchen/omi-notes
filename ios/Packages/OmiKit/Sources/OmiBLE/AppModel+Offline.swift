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

    /// Server search, or the saved copies when the server can't be reached.
    public func search(_ query: String, personId: String?, range: SearchRange, before: String? = nil) async -> Result<SearchResult, Error> {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint else { return .failure(APIError.notConfigured) }
        var from: String?
        if range != .any {
            let days = range == .week ? 6 : 29
            let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            from = Self.day(start)
        }
        do {
            guard serverStatus?.supportsSearch == true else { throw APIError.http(404, "not supported") }
            let r = try await APIClient(endpoint: endpoint, session: session).search(query: query, personId: personId, from: from, before: before)
            return .success(SearchResult(conversations: r.conversations, nextCursor: r.nextCursor, pending: r.pending ?? 0, offline: false))
        } catch {
            guard let scope = cacheScope(config), !query.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(error) }
            let rows = noteCache.search(query, scope: scope).map(\.entry)
            return .success(SearchResult(conversations: rows, nextCursor: nil, pending: 0, offline: true))
        }
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
