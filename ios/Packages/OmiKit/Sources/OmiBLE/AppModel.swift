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
    /// The last completed refresh got no status answer (unreachable, refused, or no server). A refresh
    /// still in flight doesn't change it; only a successful answer clears it, and a change of server forgets it.
    public private(set) var lastRefreshFailed = false
    public private(set) var issues: [ServerIssue] = []
    /// Dismiss request ids sent without a settled answer, reused on the next tap (per conversation).
    var dismissRequestIds: [String: String] = [:]
    /// A conversation's issues leave the list at once (the next refresh confirms it).
    func dropIssues(for conversationId: String) { issues.removeAll { $0.conversationId == conversationId } }
    public internal(set) var recent: [ConversationSummary] = []
    public private(set) var recentError: String?
    /// When the list last came from the server (nil: never, for this server).
    public private(set) var recentLoadedAt: Date?
    /// Cursor for the next older page; nil when everything is loaded.
    public internal(set) var recentCursor: String?
    /// Each loaded day's short sessions, counted by the server over the whole day (whatever is loaded or filtered).
    public internal(set) var shortDays: [String: ShortDay] = [:]
    /// Detected speech below which a session is short (the server's, else 60 s).
    public internal(set) var shortSeconds: Double = 60
    /// A day's short sessions as the server lists them (loaded when the folded row opens), by day.
    public internal(set) var shortDayRows: [String: [ConversationSummary]] = [:]
    /// Where each day's short-session load stands (ASTRA-20261119-IT2-01): one state per day, set to loading the moment a
    /// load starts (so Retry can't be pressed twice) and finished only by the newest request for that day.
    public enum ShortDayLoad: Equatable, Sendable { case loading, loaded, failed }
    public internal(set) var shortDayLoad: [String: ShortDayLoad] = [:]
    var shortDayRequest: [String: Int] = [:]
    /// The totals the day's own answer carried for it (nil: it sent none, as an empty page does).
    var shortDayAnswered: [String: ShortDay] = [:]
    /// Days whose short sessions couldn't be loaded (the fold says so rather than loading forever).
    public var shortDayFailed: Set<String> { Set(shortDayLoad.filter { $0.value == .failed }.keys) }
    /// Deferred sessions whose opening already asked for their transcription (once per opening state; a refusal is
    /// retried from 转写, never by opening again).
    var transcribedOnOpen: Set<String> = []
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
    /// Why a priority choice couldn't be saved, per conversation.
    public internal(set) var priorityMessages: [String: String] = [:]
    /// Why the owner's last recording-class change didn't go through, per conversation.
    public internal(set) var classMessages: [String: String] = [:]
    /// Bumped when a priority choice changes, so views showing it update.
    public internal(set) var priorityRevision = 0
    /// The latest choice made in this session, per conversation (its answer is the one shown).
    var priorityLatest: [String: String] = [:]
    #if DEBUG
    /// Set by `debugUseServerFixture` (simulator screenshots only).
    var debugServerFixture = false
    #endif
    /// Pause between the few status checks right after a Retry tap (shortened in tests).
    var retryFollowUpInterval: Duration = .seconds(2)
    let retryStore: RetryStore
    let priorityStore: PriorityStore
    /// Opt-in alerts for problems this phone observes (Settings).
    public let problemAlerts = ProblemAlerts()
    /// Incremented when something (a tapped Watch alert) asks to show Devices ▸ Apple Watch.
    public var watchPageRequests = 0
    /// Devices → Transfers was asked for (the sync Live Activity's `omi-notes://transfers`).
    public var transferPageRequests = 0
    public let noteCache: NoteCache
    /// Bumped when the cache is cleared or the server changes: an answer that started before then
    /// is not saved (it would bring cleared notes back).
    var cacheEpoch = 0
    /// Bumped whenever the notes a search can find may have changed: a list refresh the server answered, a note saved
    /// for offline reading, the saved notes cleared, a server or vault change. A search view asks again when it changes (2026-11-19 R5,
    /// ASTRA-20261119-IT3-02: a kept error or empty answer stayed after the server recovered or a note was saved).
    public internal(set) var notesRevision = 0
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
    /// The last "Test connection" that found the connected server's vault at an address (cleared by any save).
    /// A same-server proof from the latest "Test connection" (ASTRA-20261122-IT3-01): the exact destination URL and
    /// token, the configuration and offline-cache scope it was taken against, a valid vault identity seen on both sides,
    /// and the probe it came from. Any newer probe, a failed one, or a configuration change revokes it; Save consumes
    /// it only when every field still matches.
    struct MoveProof: Equatable {
        var url: URL
        var token: String
        var source: UploadConfig
        var sourceScope: NoteCache.Scope
        var vault: String
        var probe: Int
    }
    private var provenMove: MoveProof?
    private var probeGeneration = 0
    /// The address/vault key saved decisions were last moved to.
    private var decisionsMovedFor: String?
    /// The refresh a save starts (tests wait for it).
    var saveRefresh: Task<Void, Never>?
    /// Bumped whenever the server (configuration or vault) changes: an answer that was asked for
    /// before then is dropped.
    var dataEpoch = 0
    /// Bumped by each refreshServer: what an older one heard after a newer one started is dropped.
    var refreshGeneration = 0
    /// The latest /issues request failed: `issues` is the earlier list (last-known).
    public internal(set) var issuesStale = false
    /// When /issues last answered: the list's own time, never renewed by a status answer (ASTRA-20261121-IT4-01).
    public internal(set) var issuesAt: Date?

    /// Identifies what the shown data belongs to (views reset their own state when it changes).
    public var serverIdentity: String { "\(answeredFor?.generation ?? -1)|\(answeredVault ?? "")" }

    public static let pageSize = 20
    /// Injectable for tests (no network).
    public var session: URLSession = APIClient.defaultSession
    /// How firmware metadata and packages are fetched (a local feed in simulator automation).
    public var firmwareFetch: FirmwareModel.Fetch = FirmwareModel.urlSessionFetch

    public init(engine: OmiEngine, noteCache: NoteCache = .appDefault()) {
        self.engine = engine
        self.noteCache = noteCache
        speakers = SpeakersModel(engine: engine)
        retryStore = RetryStore(url: engine.config.dirs.root.appendingPathComponent("app-retries.json"))
        priorityStore = PriorityStore(url: engine.config.dirs.root.appendingPathComponent("app-priorities.json"))
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

    /// Omi Notes is installed on a paired Apple Watch (WatchConnectivity; nil until it has activated).
    public var watchAppInstalled: Bool?

    /// The engine's monotonic clock, for evaluating live transfer rates on screen.
    public func monotonicNow() -> UInt64 { engine.config.clock.monotonicNanoseconds() }

    /// The three transfer stages as of now (Watch → iPhone, iPhone → server, server).
    public func transfers(watchInstalled: Bool?, now: Date = Date()) -> TransferSummary {
        TransferSummary.evaluate(snapshot: snapshot, server: server, status: serverStatus, statusAt: serverStatusAt,
                                 watchInstalled: watchInstalled, nowMono: monotonicNow(), now: now)
    }

    public func health(now: Date = Date()) -> SystemHealth {
        SystemHealth.evaluate(snapshot: snapshot, server: server, status: serverStatus, statusAt: serverStatusAt, now: now, issues: issues,
                              watchAppInstalled: watchAppInstalled)
    }

    /// Whether the server's last answer describes now: the latest request worked and the answer is recent. Otherwise
    /// what it said (issues, activity, queue counts) is as of `serverStatusAt`, not current (2026-11-21).
    public func serverAnswerIsCurrent(now: Date = Date()) -> Bool {
        guard let at = serverStatusAt, !lastRefreshFailed else { return false }
        return ServiceLabel.isCurrent(age: now.timeIntervalSince(at))  // the rule the service rows use (ASTRA-20261121-IT2-01)
    }

    /// The issues list is as of now: the status answer is current and the latest /issues request answered too (a failed
    /// one keeps the old list, which is then last-known, ASTRA-20261121-IT2-02).
    public func issuesAreCurrent(now: Date = Date()) -> Bool {
        guard serverAnswerIsCurrent(now: now), !issuesStale, let at = issuesAt else { return false }
        return ServiceLabel.isCurrent(age: now.timeIntervalSince(at))
    }

    /// The Server page's service rows as of now: the last answer's names, with a health only while that
    /// answer is current (a failed latest request or an old answer makes it last-known). nil before any answer.
    public func serviceLabels(now: Date = Date()) -> (transcription: ServiceLabel, summaries: ServiceLabel)? {
        guard let serverStatus else { return nil }
        return serverStatus.serviceLabels(answeredAt: serverStatusAt, latestRequestFailed: lastRefreshFailed, now: now)
    }

    // MARK: Server

    /// Forgets everything a previous server said (another server, or none), people included.
    private func adopt(_ config: UploadConfig) {
        guard config != answeredFor else { return }
        provenMove = nil  // a proof taken against another configuration proves nothing now
        answeredVault = nil
        // Notes saved for another server (or an earlier pairing) are removed, not just hidden. Those already moved to
        // exactly this configuration (a proven same-server move, `saveServer`) stay.
        var savedForThis = noteCache.lastScope.map {
            $0.serverURL == config.endpoint?.baseURL.absoluteString && $0.generation == config.generation
        } ?? false
        if !savedForThis, let url = config.endpoint?.baseURL.absoluteString, let last = noteCache.lastScope {
            // a proven move interrupted between its rename and its pointer: completed, not deleted (IT3-02)
            savedForThis = noteCache.completeMove(to: NoteCache.Scope(serverURL: url, generation: config.generation, vaultId: last.vaultId))
        }
        if !savedForThis { noteCache.clear() }
        answeredFor = config
        forgetServerData()
    }

    /// Everything a server said, people included (a new server, or a new vault behind the same one).
    private func forgetServerData() {
        dataEpoch += 1
        speakers.serverChanged()
        serverStatus = nil
        serverStatusAt = nil
        lastRefreshFailed = false
        issues = []
        issuesStale = false
        issuesAt = nil
        recent = []
        recentCursor = nil
        shortDays = [:]
        shortDayRows = [:]
        shortDayLoad = [:]
        shortDayAnswered = [:]
        transcribedOnOpen = []
        recentError = nil
        recentLoadedAt = nil
        details = [:]
        retries = [:]
        retryMessages = [:]
        recentSavedAt = nil
        detailSavedAt = [:]
        cacheEpoch += 1
        notesRevision += 1
    }

    func isCurrent(_ config: UploadConfig) -> Bool { engine.settings.serverConfig() == config }

    // MARK: Phone log

    static let phoneLogInterval: TimeInterval = 300
    private var phoneLogSentAt: Date?
    private var phoneLogSending = false

    /// Sends the diagnostic lines logged since the last upload (at most every 5 minutes, at most 400
    /// lines / ~48 KB) to a server that advertises `phone_log`, so a stall can be read on the server.
    /// Best effort: any failure just waits for the next refresh; an older server is never asked.
    func uploadPhoneLogIfDue(api: APIClient, now: Date = Date()) {
        guard !phoneLogSending, let url = engine.config.diagnosticLogURL, let device = engine.settings.phoneInstallId else { return }
        if let at = phoneLogSentAt, now.timeIntervalSince(at) < Self.phoneLogInterval { return }
        let settings = engine.settings
        let lines = PhoneLogTail.lines(at: url, after: settings.phoneLogCursor)
        guard !lines.isEmpty else { return }
        phoneLogSending = true
        phoneLogSentAt = now
        let version = engine.config.appVersion
        Task {
            // A batch the server refuses as too large is halved, oldest half first (the rest goes next
            // time); a single line it still refuses is skipped rather than resent forever.
            var batch = lines
            while let first = batch.first {
                do {
                    let sent = try await api.putPhoneLog(deviceId: "phone-\(device)", appVersion: version, lines: batch)
                    if let at = sent.last?.at { settings.phoneLogCursor = at }
                    break
                } catch APIError.http(413, _) {
                    if batch.count == 1 {
                        settings.phoneLogCursor = first.at
                        OmiLog.shared.log(.warning, "app", "skipped a diagnostic line the server refused as too large")
                        break
                    }
                    batch = Array(batch.prefix(batch.count / 2))
                } catch {
                    break
                }
            }
            phoneLogSending = false
        }
    }

    public func refreshServer() async {
        #if DEBUG
        if debugServerFixture { serverStatusAt = Date(); return }
        #endif
        let config = engine.settings.serverConfig()
        let sameServer = config == answeredForConfig
        adopt(config)
        guard let endpoint = config.endpoint else {
            server = .notConfigured
            lastRefreshFailed = true
            return
        }
        // A re-check of the same server keeps its last verdict on screen until this answer: a server that times out
        // spent up to 15 s of every minute as "checking", which every surface read as calm or uploading (2026-11-21).
        switch server {
        case .reachable, .unreachable, .unauthorized: if !sameServer { server = .checking }
        default: server = .checking
        }
        let data = dataEpoch  // before any await: a reset while we wait makes this answer stale
        // only the newest refresh applies what it heard: an older one finishing later (a slow timeout after a newer
        // answer, a Retry overlapping the minute's refresh) changes nothing (ASTRA-20261121-IT1-04)
        refreshGeneration += 1
        let mine = refreshGeneration
        let api = APIClient(endpoint: endpoint, session: session)
        let reach: ServerReachability
        var status: ServerStatus?
        do {
            let st = try await api.status()
            status = st
            let q = st.queue
            // `ready` is configured, not answering now (a down local engine is configured too)
            let detail = "STT \(st.stt?.ready == true ? "configured" : "not configured"), LLM \(st.llm?.ready == true ? "configured" : "not configured"), \(q?.chunksPending ?? 0) chunks queued"
            reach = .reachable(version: st.serverVersion, detail: detail)
        } catch APIError.unauthorized {
            reach = .unauthorized
        } catch {
            reach = .unreachable(Self.describe(error))
        }
        guard isCurrent(config), data == dataEpoch, mine == refreshGeneration else { return }  // the server changed while we were asking
        server = reach
        lastRefreshFailed = status == nil
        guard let status else {
            issuesStale = true  // the issues list is last-known until /issues itself answers again (IT4-01)
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
            // decisions saved for this vault at an earlier address are this address's now (2026-11-22)
            if let url = config.endpoint?.baseURL {
                let key = RetryStore.serverKey(baseURL: url, vaultId: vault)
                // once per address/vault, not on every refresh (IT2-04); a failed save is tried at the next refresh
                if decisionsMovedFor != key {
                    let moved = retryStore.move(vaultId: vault, to: key)
                    if priorityStore.move(vaultId: vault, to: key), moved { decisionsMovedFor = key }
                }
            }
        }
        serverStatus = status
        serverStatusAt = Date()
        engine.noteServerWatchAAC(status.features?.contains("watch_aac") == true, generation: config.generation)
        engine.noteServerSameAudioResend(status.features?.contains("same_audio_resend") == true)
        rememberValueNotesScope(config)
        if status.supportsPhoneLog { uploadPhoneLogIfDue(api: api) }
        let epoch = cacheEpoch
        guard data == dataEpoch, mine == refreshGeneration else { return }  // a vault change just reset everything
        // in parallel; each applies its own answer when it arrives (the issues list doesn't wait for the page, IT6-01)
        async let issuesApplied: Void = applyIssues(api: api, supported: status.supportsIssues, config: config, data: data, refresh: mine)
        async let pageTask = Result { try await api.recentConversations(limit: Self.pageSize) }
        let page = await pageTask
        await issuesApplied
        guard isCurrent(config), data == dataEpoch, mine == refreshGeneration else { return }
        await settleRetries(api: api, config: config, data: data, refresh: mine)
        guard isCurrent(config), data == dataEpoch, mine == refreshGeneration else { return }
        switch page {
        case .success(let page):
            mergeFirstPage(page)
            await reloadOpenedShortDays()  // an opened fold follows refreshes: no stale "waiting" or spinner
            guard isCurrent(config), data == dataEpoch, mine == refreshGeneration else { return }
            await settlePriorities(api: api, data: data, refresh: mine)
            guard isCurrent(config), data == dataEpoch, mine == refreshGeneration else { return }
            recentError = nil
            recentLoadedAt = Date()
            recentSavedAt = nil
            if epoch == cacheEpoch, let scope = cacheScope(config) { noteCache.saveRecent(page.conversations, scope: scope) }
            notesRevision += 1
        case .failure(let error):
            recentError = Self.describe(error)  // the list already shown stays, marked stale
            if recent.isEmpty { showSavedList(config) }
        }
    }

    /// `/issues`' outcome, applied the moment it answers, with that time, under the refresh's own guards: a failure
    /// marks the kept list last-known at once, not after the unrelated page answers (ASTRA-20261121-IT6-01).
    private func applyIssues(api: APIClient, supported: Bool, config: UploadConfig, data: Int, refresh: Int) async {
        let answer: [ServerIssue]? = supported ? try? await api.issues() : []
        guard isCurrent(config), data == dataEpoch, refresh == refreshGeneration else { return }
        if let answer {
            issues = answer
            issuesStale = false
            issuesAt = Date()
        } else {
            issuesStale = true  // kept, but not renewed by this status answer
        }
    }

    /// Refreshing page one keeps older pages already loaded: rows newer than the page's last one
    /// come from the page; older rows stay (with their cursor) unless the page is the whole list.
    func mergeFirstPage(_ page: RecentConversationsResponse) {
        noteShortDays(page)
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
            noteShortDays(page)
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
            reconcileShortDays(with: [detail.entry])
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

    /// A "Test connection" answer: whether it worked, what to show, and whether the address answers as the server
    /// connected now (same vault; nil when either side is unknown: no claim).
    public struct ConnectionCheck: Equatable, Sendable {
        public var ok: Bool
        public var message: String
        public var sameServer: Bool?
    }

    /// Settings "Test connection": probes a URL/token without saving it.
    public func testConnection(url: URL, token: String) async -> String {
        await checkConnection(url: url, token: token).message
    }

    /// The probe behind "Test connection". Compares the answer's vault with the connected server's, so moving the same
    /// server to a new address can be told from pointing the phone at another one (2026-11-22).
    public func checkConnection(url: URL, token: String) async -> ConnectionCheck {
        let api = APIClient(endpoint: ServerEndpoint(baseURL: url, token: token), session: session)
        probeGeneration += 1
        let probe = probeGeneration
        provenMove = nil  // a new probe revokes any earlier proof, whatever it answers
        let source = engine.settings.serverConfig()
        let sourceScope = cacheScope(source)
        // an empty or malformed identity says nothing: no same/different claim from it (IT2-03)
        let known = currentVaultId.flatMap { VaultIdentity.valid($0) }
        do {
            let st = try await api.status()
            let theirs = st.vaultId.flatMap { VaultIdentity.valid($0) }
            let same = known.flatMap { k in theirs.map { $0 == k } }
            // only the latest probe, against the configuration and cache it started from, may leave a proof
            if probe == probeGeneration, same == true, let vault = theirs, let sourceScope, sourceScope.vaultId == vault,
               isCurrent(source), noteCache.lastScope == sourceScope {
                provenMove = MoveProof(url: url, token: token, source: source, sourceScope: sourceScope, vault: vault, probe: probe)
            }
            let what = same.map { $0 ? " Same server as now." : " A different server from the one connected now." } ?? ""
            return ConnectionCheck(ok: true, message: "Connected to server \(st.serverVersion ?? "?"). Transcription \(st.stt?.ready == true ? "configured" : "not configured")"
                + (st.stt?.engine?.healthy == false ? " (not answering now)" : "") + "; "
                + "summaries \(st.llm?.ready == true ? "configured" : "not configured")." + what, sameServer: same)
        } catch APIError.http(401, _) {
            return ConnectionCheck(ok: false, message: "Couldn't connect: the server rejected this token.", sameServer: nil)
        } catch {
            return ConnectionCheck(ok: false, message: "Couldn't connect: \(Self.describe(error))", sameServer: nil)
        }
    }

    public func saveServer(url: URL, token: String) throws {
        // the proof counts only for exactly this destination and token, taken against the configuration and cache that
        // are still current, from the latest probe; anything else clears the old notes as before (IT3-01)
        let proven = provenMove.flatMap { p in
            p.url == url && p.token == token && p.probe == probeGeneration && isCurrent(p.source)
                && noteCache.lastScope == p.sourceScope ? p.vault : nil
        }
        provenMove = nil
        try engine.configureServer(url: url, token: token)
        // a passing test found this address to be the same vault: its saved notes stay readable there (R2 2026-11-22)
        if let proven, let base = engine.settings.serverConfig().endpoint?.baseURL {
            if !noteCache.move(to: NoteCache.Scope(serverURL: base.absoluteString, generation: engine.settings.serverConfig().generation, vaultId: proven)) {
                OmiLog.shared.log(.warning, "cache", "the saved notes couldn't be kept for the new address yet; the next refresh retries")
            }
        }
        saveRefresh = Task { await refreshServer() }
    }

    // MARK: URL scheme

    /// `omi-notes://configure?url=…&token=…` → confirmation sheet (never saved silently).
    @discardableResult
    public func handleOpenURL(_ url: URL) -> Bool {
        if url.scheme == "omi-notes", url.host == "transfers" {
            transferPageRequests += 1
            return true
        }
        guard let link = ConfigureLink.parse(url) else {
            // a reason only: the link may carry a pairing token, encoded in ways no redactor foresees
            let reason = url.scheme != "omi-notes" ? "not an omi-notes link"
                : url.host == "configure" ? "a configure link without a valid server and token" : "an unknown omi-notes link"
            OmiLog.shared.log(.warning, "app", "ignored a link: \(reason)")
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

#if DEBUG
extension AppModel {
    /// Simulator screenshots only (debug builds): show a synthetic server answer; refreshes keep it.
    public func debugUseServerFixture(status: ServerStatus, issues: [ServerIssue]) {
        debugServerFixture = true
        server = .reachable(version: "fixture", detail: "")
        serverStatus = status
        serverStatusAt = Date()
        self.issues = issues
    }
}
#endif
