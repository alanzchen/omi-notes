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
    public internal(set) var recent: [ConversationSummary] = []
    public private(set) var recentError: String?
    /// When the list last came from the server (nil: never, for this server).
    public private(set) var recentLoadedAt: Date?
    /// Cursor for the next older page; nil when everything is loaded.
    public internal(set) var recentCursor: String?
    public private(set) var loadingMore = false
    /// Conversations opened this session, shown (marked stale) when the server can't be reached.
    public internal(set) var details: [String: ConversationDetail] = [:]
    public var pendingConfigure: ConfigureLink?
    public private(set) var logs: [LogLine] = []

    public let engine: OmiEngine
    public let speakers: SpeakersModel
    /// Retries by conversation id: the server's latest answer, for the current server only.
    public internal(set) var retries: [String: RetryOperation] = [:]
    /// A short outcome to show next to a retry button (by conversation id; "chunks" for audio files).
    public internal(set) var retryMessages: [String: String] = [:]
    /// Pause between the few status checks right after a Retry tap (shortened in tests).
    var retryFollowUpInterval: Duration = .seconds(2)
    let retryStore: RetryStore
    /// Opt-in alerts for problems this phone observes (Settings).
    public let problemAlerts = ProblemAlerts()
    public let noteCache: NoteCache
    /// Bumped when the cache is cleared or the server changes: an answer that started before then
    /// is not saved (it would bring cleared notes back).
    var cacheEpoch = 0
    /// Set while the list shown is the saved copy (the server couldn't be reached).
    public internal(set) var recentSavedAt: Date?
    /// Conversations shown from the saved copy, with when it was saved.
    public internal(set) var detailSavedAt: [String: Date] = [:]

    /// Every server answer is kept only while this is still the configured server. The
    /// configuration generation changes on every save, so A → B → A is a new server too.
    private var answeredFor: UploadConfig?
    var answeredForConfig: UploadConfig? { answeredFor }
    /// The vault the current server last said it serves: a different one at the same address is
    /// another server as far as everything shown here is concerned.
    private var answeredVault: String?
    /// Bumped whenever the server (configuration or vault) changes: an answer that was asked for
    /// before then is dropped.
    var dataEpoch = 0

    /// Identifies what the shown data belongs to (views reset their own state when it changes).
    public var serverIdentity: String { "\(answeredFor?.generation ?? -1)|\(answeredVault ?? "")" }

    public static let pageSize = 20
    /// Injectable for tests (no network).
    public var session: URLSession = APIClient.defaultSession

    public init(engine: OmiEngine, noteCache: NoteCache = .appDefault()) {
        self.engine = engine
        self.noteCache = noteCache
        speakers = SpeakersModel(engine: engine)
        retryStore = RetryStore(url: engine.config.dirs.root.appendingPathComponent("app-retries.json"))
        engine.setSnapshotSink { [weak self] s in
            Task { @MainActor [weak self] in
                self?.snapshot = s
                self?.problemAlerts.update(s)
            }
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

    /// Forgets everything a previous server said (another server, or none), people included.
    private func adopt(_ config: UploadConfig) {
        guard config != answeredFor else { return }
        answeredVault = nil
        // Notes saved for another server (or an earlier pairing) are removed, not just hidden.
        if answeredFor != nil {
            noteCache.clear()
        } else if let last = noteCache.lastScope,
                  last.serverURL != config.endpoint?.baseURL.absoluteString || last.generation != config.generation {
            noteCache.clear()
        }
        answeredFor = config
        forgetServerData()
    }

    /// Everything a server said, people included (a new server, or a new vault behind the same one).
    private func forgetServerData() {
        dataEpoch += 1
        speakers.serverChanged()
        serverStatus = nil
        serverStatusAt = nil
        issues = []
        recent = []
        recentCursor = nil
        recentError = nil
        recentLoadedAt = nil
        details = [:]
        retries = [:]
        retryMessages = [:]
        recentSavedAt = nil
        detailSavedAt = [:]
        cacheEpoch += 1
    }

    func isCurrent(_ config: UploadConfig) -> Bool { engine.settings.serverConfig() == config }

    public func refreshServer() async {
        let config = engine.settings.serverConfig()
        adopt(config)
        guard let endpoint = config.endpoint else {
            server = .notConfigured
            return
        }
        server = .checking
        lastCheckAt = Date()
        let data = dataEpoch  // before any await: a reset while we wait makes this answer stale
        let api = APIClient(endpoint: endpoint, session: session)
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
        guard isCurrent(config), data == dataEpoch else { return }  // the server changed while we were asking
        server = reach
        guard let status else {
            // Shown conversations (if any) are now of unknown freshness; an empty list isn't "none yet".
            recentError = Self.describeReach(reach)
            if recent.isEmpty { showSavedList(config) }
            return
        }
        if let vault = status.vaultId {
            if let previous = answeredVault ?? noteCache.lastScope?.vaultId, previous != vault {
                // same address, another vault: nothing shown or saved so far belongs to it
                forgetServerData()
                noteCache.clear()
            }
            answeredVault = vault
        }
        serverStatus = status
        serverStatusAt = Date()
        let epoch = cacheEpoch
        guard data == dataEpoch else { return }  // a vault change just reset everything
        async let issuesTask: [ServerIssue]? = status.supportsIssues ? try? api.issues() : []
        async let pageTask = Result { try await api.recentConversations(limit: Self.pageSize) }
        let (newIssues, page) = await (issuesTask, pageTask)
        guard isCurrent(config), data == dataEpoch else { return }
        if let newIssues { issues = newIssues }
        await settleRetries(api: api, config: config, data: data)
        guard isCurrent(config), data == dataEpoch else { return }
        switch page {
        case .success(let page):
            mergeFirstPage(page)
            recentError = nil
            recentLoadedAt = Date()
            recentSavedAt = nil
            if epoch == cacheEpoch, let scope = cacheScope(config) { noteCache.saveRecent(page.conversations, scope: scope) }
        case .failure(let error):
            recentError = Self.describe(error)  // the list already shown stays, marked stale
            if recent.isEmpty { showSavedList(config) }
        }
    }

    /// Refreshing page one keeps older pages already loaded: rows newer than the page's last one
    /// come from the page; older rows stay (with their cursor) unless the page is the whole list.
    func mergeFirstPage(_ page: RecentConversationsResponse) {
        guard page.nextCursor != nil, let last = page.conversations.last, recent.count > page.conversations.count else {
            recent = page.conversations
            recentCursor = page.nextCursor
            return
        }
        // The server's order is (start, id) descending: keep exactly the rows after the page's last one.
        func key(_ c: ConversationSummary) -> (Date, String) { (c.startedDate ?? .distantPast, c.id) }
        let ids = Set(page.conversations.map(\.id))
        let older = recent.filter { !ids.contains($0.id) && key($0) < key(last) }
        recent = page.conversations + older
        // recentCursor still points past the older pages
    }

    public func loadMoreConversations() async {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint, config == answeredFor, let cursor = recentCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let data = dataEpoch
        do {
            let page = try await APIClient(endpoint: endpoint, session: session).recentConversations(limit: Self.pageSize, before: cursor)
            guard isCurrent(config), data == dataEpoch, recentCursor == cursor else { return }
            let ids = Set(recent.map(\.id))
            recent += page.conversations.filter { !ids.contains($0.id) }
            recentCursor = page.nextCursor
            recentError = nil
        } catch {
            if isCurrent(config) { recentError = Self.describe(error) }
        }
    }

    /// Appends the next transcript page to the cached detail. The page must belong to the same
    /// transcript *and* speaker assignments as what is shown, and the cached copy must not have
    /// changed meanwhile; otherwise the whole detail is reloaded from the first page.
    public func loadMoreTranscript(_ id: String) async throws {
        guard let shown = details[id], let from = shown.transcript?.nextFrom else { return }
        let epoch = cacheEpoch
        let page = try await conversation(id, segmentsFrom: from)
        guard var current = details[id], current.transcript?.segments.count == shown.transcript?.segments.count,
              current.transcriptSha == shown.transcriptSha, current.speakersRevision == shown.speakersRevision,
              page.transcriptSha == current.transcriptSha, page.speakersRevision == current.speakersRevision,
              let next = page.transcript, next.from == from
        else {
            _ = try await conversation(id)
            return
        }
        current.append(next)
        details[id] = current
        if epoch == cacheEpoch { saveForOffline(current, engine.settings.serverConfig()) }
    }

    /// Detail for one conversation (and later transcript pages with `segmentsFrom`).
    public func conversation(_ id: String, segmentsFrom: Int = 0) async throws -> ConversationDetail {
        let config = engine.settings.serverConfig()
        guard let endpoint = config.endpoint else { throw APIError.notConfigured }
        let epoch = cacheEpoch, data = dataEpoch
        let detail: ConversationDetail
        do {
            detail = try await APIClient(endpoint: endpoint, session: session).conversation(id, segmentsFrom: segmentsFrom)
        } catch {
            if segmentsFrom == 0, isCurrent(config), details[id] == nil { showSavedDetail(id, config) }
            throw error
        }
        guard isCurrent(config), config == answeredFor, data == dataEpoch else { throw APIError.transport("The server changed; reload.") }
        if segmentsFrom == 0 {
            if let i = recent.firstIndex(where: { $0.id == id }) { recent[i] = detail.entry }
            details[id] = detail
            detailSavedAt[id] = nil
            if epoch == cacheEpoch { saveForOffline(detail, config) }
        }
        return detail
    }

    static func describeReach(_ reach: ServerReachability) -> String {
        switch reach {
        case .unauthorized: return "The server rejected this phone"
        case .unreachable(let why): return "Can't reach the server (\(why))"
        default: return "Couldn't check the server"
        }
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
