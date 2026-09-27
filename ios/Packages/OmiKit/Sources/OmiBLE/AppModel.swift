import Foundation
import Observation
import OmiCapture
import OmiProtocol

public enum ServerReachability: Equatable, Sendable {
    case unknown
    case notConfigured
    case checking
    case reachable(version: String?, detail: String)
    case unauthorized
    case unreachable(String)

    public var label: String {
        switch self {
        case .unknown: return "Not checked"
        case .notConfigured: return "Not configured"
        case .checking: return "Checking…"
        case .reachable(let v, _): return "Reachable\(v.map { " (v\($0))" } ?? "")"
        case .unauthorized: return "Token rejected"
        case .unreachable(let why): return "Unreachable: \(why)"
        }
    }
}

/// SwiftUI-facing state. Engine snapshots arrive from the engine queue and are applied on the main actor.
@MainActor
@Observable
public final class AppModel {
    public private(set) var snapshot = EngineSnapshot()
    public private(set) var server: ServerReachability = .unknown
    public private(set) var serverStatus: ServerStatus?
    /// When `serverStatus` was received (a failed refresh leaves it alone).
    public private(set) var serverStatusAt: Date?
    public private(set) var lastCheckAt: Date?
    public private(set) var issues: [ServerIssue] = []
    public private(set) var recent: [ConversationSummary] = []
    public private(set) var recentError: String?
    /// Cursor for the next older page; nil when everything is loaded.
    public private(set) var recentCursor: String?
    public private(set) var loadingMore = false
    /// Conversations opened this session, shown (marked stale) when the server can't be reached.
    public private(set) var details: [String: ConversationDetail] = [:]
    public var pendingConfigure: ConfigureLink?
    public private(set) var logs: [LogLine] = []

    public let engine: OmiEngine
    public let speakers: SpeakersModel

    /// Every server answer is kept only while this is still the configured server.
    private var answeredFor: ServerEndpoint?

    public static let pageSize = 20

    public init(engine: OmiEngine) {
        self.engine = engine
        speakers = SpeakersModel(engine: engine)
        engine.setSnapshotSink { [weak self] s in
            Task { @MainActor [weak self] in self?.snapshot = s }
        }
    }

    public var settings: SettingsStore { engine.settings }
    public var serverURL: URL? { engine.settings.serverURL }
    public var needsOnboarding: Bool { !engine.settings.onboarded }

    public func finishOnboarding() { engine.settings.onboarded = true }

    public func health(now: Date = Date()) -> SystemHealth {
        SystemHealth.evaluate(snapshot: snapshot, server: server, status: serverStatus, statusAt: serverStatusAt, now: now)
    }

    // MARK: Server

    /// Forgets everything a previous server said (another server, or none).
    private func adopt(_ endpoint: ServerEndpoint?) {
        guard endpoint != answeredFor else { return }
        answeredFor = endpoint
        serverStatus = nil
        serverStatusAt = nil
        issues = []
        recent = []
        recentCursor = nil
        recentError = nil
        details = [:]
    }

    private func isCurrent(_ endpoint: ServerEndpoint) -> Bool { engine.settings.endpoint == endpoint }

    public func refreshServer() async {
        let endpoint = engine.settings.endpoint
        adopt(endpoint)
        guard let endpoint else {
            server = .notConfigured
            return
        }
        server = .checking
        lastCheckAt = Date()
        let api = APIClient(endpoint: endpoint)
        let reach: ServerReachability
        var status: ServerStatus?
        do {
            let st = try await api.status()
            status = st
            let q = st.queue
            let detail = "STT \(st.stt?.ready == true ? "ready" : "not ready"), LLM \(st.llm?.ready == true ? "ready" : "not ready"), \(q?.chunksPending ?? 0) chunks queued"
            reach = .reachable(version: st.serverVersion, detail: detail)
        } catch APIError.unauthorized {
            reach = .unauthorized
        } catch {
            reach = .unreachable(Self.describe(error))
        }
        guard isCurrent(endpoint) else { return }  // the server changed while we were asking
        server = reach
        if let status {
            serverStatus = status
            serverStatusAt = Date()
        }
        guard status != nil else { return }
        async let issuesTask: [ServerIssue]? = status?.supportsIssues == true ? try? api.issues() : []
        async let pageTask = Result { try await api.recentConversations(limit: Self.pageSize) }
        let (newIssues, page) = await (issuesTask, pageTask)
        guard isCurrent(endpoint) else { return }
        if let newIssues { issues = newIssues }
        switch page {
        case .success(let page):
            mergeFirstPage(page)
            recentError = nil
        case .failure(let error):
            recentError = Self.describe(error)  // the list already shown stays, marked stale
        }
    }

    /// Refreshing page one keeps older pages already loaded: rows newer than the page's last one
    /// come from the page; older rows stay (with their cursor) unless the page is the whole list.
    func mergeFirstPage(_ page: RecentConversationsResponse) {
        guard page.nextCursor != nil, let oldest = page.conversations.last?.startedAt, recent.count > page.conversations.count else {
            recent = page.conversations
            recentCursor = page.nextCursor
            return
        }
        let ids = Set(page.conversations.map(\.id))
        let older = recent.filter { !ids.contains($0.id) && ($0.startedAt ?? "") < oldest }
        recent = page.conversations + older
        // recentCursor still points past the older pages
    }

    public func loadMoreConversations() async {
        guard let endpoint = engine.settings.endpoint, let cursor = recentCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await APIClient(endpoint: endpoint).recentConversations(limit: Self.pageSize, before: cursor)
            guard isCurrent(endpoint), recentCursor == cursor else { return }
            let ids = Set(recent.map(\.id))
            recent += page.conversations.filter { !ids.contains($0.id) }
            recentCursor = page.nextCursor
            recentError = nil
        } catch {
            if isCurrent(endpoint) { recentError = Self.describe(error) }
        }
    }

    /// Keeps a transcript page the view appended, so a stale copy shows everything that was read.
    public func remember(_ detail: ConversationDetail) { details[detail.id] = detail }

    /// Detail for one conversation (and later transcript pages with `segmentsFrom`).
    public func conversation(_ id: String, segmentsFrom: Int = 0) async throws -> ConversationDetail {
        guard let endpoint = engine.settings.endpoint else { throw APIError.notConfigured }
        let detail = try await APIClient(endpoint: endpoint).conversation(id, segmentsFrom: segmentsFrom)
        guard isCurrent(endpoint) else { throw APIError.transport("The server changed; reload.") }
        if segmentsFrom == 0 {
            if let i = recent.firstIndex(where: { $0.id == id }) { recent[i] = detail.entry }
            details[id] = detail
        }
        return detail
    }

    public static func describe(_ error: Error) -> String {
        switch error {
        case APIError.transport(let m): return m
        case APIError.http(404, _): return "Not found on the server."
        default: return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Settings "Test connection": probes a URL/token without saving it.
    public func testConnection(url: URL, token: String) async -> String {
        let api = APIClient(endpoint: ServerEndpoint(baseURL: url, token: token))
        do {
            let st = try await api.status()
            return "OK — server \(st.serverVersion ?? "?"), protocol \(st.protocolVersion.map(String.init) ?? "?"), STT \(st.stt?.ready == true ? "ready" : "not ready"), LLM \(st.llm?.ready == true ? "ready" : "not ready")"
        } catch {
            return "Failed: \(error)"
        }
    }

    public func saveServer(url: URL, token: String) throws {
        try engine.configureServer(url: url, token: token)
        Task { await refreshServer() }
    }

    // MARK: URL scheme

    /// `omi-notes://configure?url=…&token=…` → confirmation sheet (never saved silently).
    @discardableResult
    public func handleOpenURL(_ url: URL) -> Bool {
        guard let link = ConfigureLink.parse(url) else {
            OmiLog.shared.log(.warning, "app", "ignored URL \(OmiLog.redact(url.absoluteString))")
            return false
        }
        pendingConfigure = link
        return true
    }

    public func confirmPendingConfigure() throws {
        guard let link = pendingConfigure else { return }
        let (url, verdict) = ServerURLPolicy.evaluate(link.url)
        guard let url, verdict.isAcceptable else {
            if case .rejected(let why) = verdict { throw ConfigureError.rejected(why) }
            throw ConfigureError.rejected("invalid URL")
        }
        try saveServer(url: url, token: link.token)
        pendingConfigure = nil
    }

    public enum ConfigureError: Error, LocalizedError {
        case rejected(String)
        public var errorDescription: String? {
            if case .rejected(let s) = self { return s }
            return nil
        }
    }

    // MARK: Logs

    public func refreshLogs() { logs = OmiLog.shared.recent(limit: 400).reversed() }
}
