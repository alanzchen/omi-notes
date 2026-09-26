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
    public private(set) var recent: [ConversationSummary] = []
    public private(set) var recentError: String?
    public var pendingConfigure: ConfigureLink?
    public private(set) var logs: [LogLine] = []

    public let engine: OmiEngine

    public init(engine: OmiEngine) {
        self.engine = engine
        engine.setSnapshotSink { [weak self] s in
            Task { @MainActor [weak self] in self?.snapshot = s }
        }
    }

    public var settings: SettingsStore { engine.settings }
    public var serverURL: URL? { engine.settings.serverURL }
    public var needsOnboarding: Bool { !engine.settings.onboarded }

    public func finishOnboarding() { engine.settings.onboarded = true }

    // MARK: Server

    public func refreshServer() async {
        guard let endpoint = engine.settings.endpoint else {
            server = .notConfigured
            recent = []
            return
        }
        server = .checking
        let api = APIClient(endpoint: endpoint)
        do {
            let st = try await api.status()
            serverStatus = st
            let q = st.queue
            let detail = "STT \(st.stt?.ready == true ? "ready" : "not ready"), LLM \(st.llm?.ready == true ? "ready" : "not ready"), \(q?.chunksPending ?? 0) chunks queued"
            server = .reachable(version: st.serverVersion, detail: detail)
        } catch APIError.unauthorized {
            server = .unauthorized
        } catch {
            server = .unreachable("\(error)")
        }
        do {
            recent = try await api.recentConversations(limit: 20)
            recentError = nil
        } catch {
            recentError = "\(error)"
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
