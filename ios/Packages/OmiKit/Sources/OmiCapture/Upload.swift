import CryptoKit
import Foundation
import OmiProtocol

// MARK: - Policy (pure)

/// Response classification per capture-format-v1.md "PUT …/chunks" table.
public enum UploadOutcome: Equatable, Sendable {
    case acknowledged(status: Int)   // 200 / 201
    case badRequest                   // 400: checksum / length mismatch
    case unauthorized                 // 401
    case conflict                     // 409
    case tooLarge                     // 413
    case invalid                      // 422
    case transient(status: Int?)      // 5xx (incl. 507), network error, timeout
    case unexpected(status: Int)      // other statuses

    public static func classify(status: Int?, networkError: Bool) -> UploadOutcome {
        guard let status, !networkError else { return .transient(status: status) }
        switch status {
        case 200, 201: return .acknowledged(status: status)
        case 400: return .badRequest
        case 401: return .unauthorized
        case 409: return .conflict
        case 413: return .tooLarge
        case 422: return .invalid
        case 500...599: return .transient(status: status)
        default: return .unexpected(status: status)
        }
    }
}

public enum UploadAction: Equatable, Sendable {
    case markSent
    case retry(after: TimeInterval)
    /// 400: re-verify the local file (SHA-256 + envelope framing) then retry.
    case reverifyAndRetry(after: TimeInterval)
    case quarantine(reason: String)
    /// 401: stop all uploads until the token changes.
    case pauseAll(reason: String)
}

public struct UploadPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval = 30
    public var maxDelay: TimeInterval = 30 * 60
    public var jitter: Double = 0.2
    public var maxBadRequestAttempts = 5
    public var badRequestDelay: TimeInterval = 10

    public init() {}

    /// Exponential backoff with ±`jitter` (random value in 0…1 injected for tests).
    public func backoff(attempt: Int, random: Double) -> TimeInterval {
        let exp = min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        let factor = 1 + jitter * (random * 2 - 1)
        return max(1, exp * factor)
    }

    /// `attempts` = consecutive failed attempts including this one; `badRequests` likewise for 400.
    public func action(for outcome: UploadOutcome, attempts: Int, badRequests: Int, random: Double) -> UploadAction {
        switch outcome {
        case .acknowledged: return .markSent
        case .badRequest:
            if badRequests >= maxBadRequestAttempts { return .quarantine(reason: "400 after \(badRequests) attempts") }
            return .reverifyAndRetry(after: badRequestDelay * Double(badRequests))
        case .unauthorized: return .pauseAll(reason: "Server rejected the token (401)")
        case .conflict: return .quarantine(reason: "409: different content already stored under this identity")
        case .tooLarge: return .quarantine(reason: "413: too large")
        case .invalid: return .quarantine(reason: "422: server rejected the envelope")
        case .transient, .unexpected: return .retry(after: backoff(attempt: attempts, random: random))
        }
    }
}

// MARK: - Per-file attempt state

public struct UploadRecord: Codable, Equatable, Sendable {
    public var attempts = 0
    public var badRequests = 0
    public var nextAttemptAt: Date?
    public var lastStatus: Int?
    public var lastError: String?
    public init() {}
}

public final class UploadStateStore: @unchecked Sendable {
    private struct Stored: Codable {
        var epoch: Int
        var records: [String: UploadRecord]
    }

    private let url: URL
    private var records: [String: UploadRecord]
    /// Upload task epoch (part of every task identity), persisted across relaunches.
    public private(set) var epoch: Int

    public init(url: URL) {
        self.url = url
        let stored = JSONFile.load(Stored.self, from: url)
        records = stored?.records ?? [:]
        epoch = stored?.epoch ?? 1
    }

    public func bumpEpoch() {
        epoch += 1
        persist()
    }

    public func record(_ name: String) -> UploadRecord { records[name] ?? UploadRecord() }

    public func update(_ name: String, _ body: (inout UploadRecord) -> Void) {
        var r = record(name)
        body(&r)
        records[name] = r
        persist()
    }

    public func remove(_ name: String) {
        guard records.removeValue(forKey: name) != nil else { return }
        persist()
    }

    /// Drops records whose files are no longer pending.
    public func prune(keeping names: Set<String>) {
        let before = records.count
        records = records.filter { names.contains($0.key) }
        if records.count != before { persist() }
    }

    private func persist() {
        do { try JSONFile.save(Stored(epoch: epoch, records: records), to: url) } catch {
            log(.error, "upload", "upload state save failed: \(error)")
        }
    }
}

// MARK: - Transport abstraction

public protocol UploadTransport: AnyObject {
    /// Descriptions (`taskDescription`) of upload tasks the system still holds, including tasks
    /// whose cancellation has not completed yet and finished tasks whose completion has not been
    /// delivered yet. The completion may run on any queue.
    func activeTaskIdentifiers(_ completion: @escaping @Sendable (Set<String>) -> Void)
    func startUpload(_ request: URLRequest, fromFile: URL, identifier: String, earliestBeginDate: Date?)
    /// Asynchronous: cancelled tasks later complete with `URLError.cancelled`.
    func cancel(identifiers: Set<String>)
    func cancelAll()
}

/// Immutable server configuration snapshot. `generation` changes whenever URL or token change and
/// is persisted, so tasks that survive a relaunch are still recognized.
public struct UploadConfig: Equatable, Sendable {
    public var endpoint: ServerEndpoint?
    public var generation: Int
    public init(endpoint: ServerEndpoint?, generation: Int) {
        self.endpoint = endpoint
        self.generation = generation
    }
}

/// Task identity: `"<generation>.<epoch>|<file name>"`. Only tasks of the current identity count
/// as in flight, and only their completions can acknowledge a file.
public enum UploadTaskID {
    public static func make(key: String, name: String) -> String { "\(key)|\(name)" }
    public static func parse(_ s: String) -> (key: String, name: String)? {
        guard let bar = s.firstIndex(of: "|") else { return nil }
        return (String(s[..<bar]), String(s[s.index(after: bar)...]))
    }
}

public struct UploadResultSummary: Equatable, Sendable {
    public var name: String
    public var status: Int?
    public var message: String
    public var date: Date
    public var success: Bool
}

public struct UploaderStatus: Equatable, Sendable {
    public var configured = false
    public var pausedReason: String?
    public var inFlight = 0
    /// Items waiting for a dependency (ring `sync_complete` seals behind earlier captures).
    public var held = 0
    public var lastResult: UploadResultSummary?
    public var lastSuccessAt: Date?
    public var attention: [String] = []
    public init() {}
}

// MARK: - Coordinator

/// Owns the upload loop: pending file → PUT task → classify → sent / retry / quarantine.
/// Confined to the engine queue (`queue`).
///
/// Every task carries the key `"<config generation>.<upload epoch>"`. A server change bumps the
/// generation, "Retry now" bumps the epoch; tasks with any other key are obsolete: they are
/// cancelled, never counted as in flight, and their completions (even 2xx from the old server)
/// never acknowledge a file. Cancellation completes asynchronously, so every cancelled callback
/// triggers another reconcile.
public final class Uploader: @unchecked Sendable {
    public let outbox: Outbox
    public let state: UploadStateStore
    public let transport: UploadTransport
    public let queue: DispatchQueue
    public var policy = UploadPolicy()
    public var maxInFlight = 32
    public var config: () -> UploadConfig
    public var gate: UploadGate?
    /// False until launch recovery has finished (uploads are gated on it).
    public var enabled = true
    public var now: () -> Date = Date.init
    public var random: () -> Double = { Double.random(in: 0...1) }
    public var onStatusChange: (() -> Void)?

    public private(set) var status = UploaderStatus()
    /// Files with a task in flight: those this uploader started (until their completion arrives,
    /// since a new task may not be listed yet) plus those the system's listing says it owns.
    private var started: Set<String> = []
    /// The ones this uploader started. Files adopted from the listing are owned only while it still
    /// lists them, so a task the transport stops counting (never delivered) can't hold its file.
    private var launched: Set<String> = []
    private var startedKey: String?
    private var reconcileInProgress = false
    private var reconcileAgain = false

    public init(outbox: Outbox, state: UploadStateStore, transport: UploadTransport, queue: DispatchQueue, config: @escaping () -> UploadConfig) {
        self.outbox = outbox
        self.state = state
        self.transport = transport
        self.queue = queue
        self.config = config
    }

    /// Current task key for a configuration.
    public func key(for cfg: UploadConfig) -> String { "\(cfg.generation).\(state.epoch)" }

    /// Compare pending files with the system's tasks and start whatever is missing.
    /// Run on launch, foreground, BLE connect, after each new outbox item, and after completions.
    public func reconcile() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard enabled else { return }
        let cfg = config()
        guard cfg.endpoint != nil else {
            status.configured = false
            onStatusChange?()
            return
        }
        status.configured = true
        if status.pausedReason != nil { onStatusChange?(); return }
        if reconcileInProgress { reconcileAgain = true; return }
        reconcileInProgress = true
        let requestedKey = key(for: cfg)
        transport.activeTaskIdentifiers { [weak self] active in
            guard let self else { return }
            self.queue.async {
                self.reconcileInProgress = false
                let current = self.config()
                if self.key(for: current) != requestedKey || current.endpoint == nil {
                    // Configuration changed while enumerating: these results describe the old one.
                    self.reconcileAgain = false
                    self.reconcile()
                    return
                }
                self.startMissing(active: active, cfg: current)
                if self.reconcileAgain {
                    self.reconcileAgain = false
                    self.reconcile()
                }
            }
        }
    }

    private func startMissing(active: Set<String>, cfg: UploadConfig) {
        guard let endpoint = cfg.endpoint, status.pausedReason == nil else { return }
        let currentKey = key(for: cfg)
        if startedKey != currentKey {
            started.removeAll()
            launched.removeAll()
            startedKey = currentKey
        }
        let pending = outbox.pending()
        let pendingNames = Set(pending.map(\.name))
        state.prune(keeping: pendingNames)
        var obsolete: Set<String> = []
        var activeNames: Set<String> = []
        for desc in active {
            guard let (k, name) = UploadTaskID.parse(desc), k == currentKey else { obsolete.insert(desc); continue }
            activeNames.insert(name)
        }
        if !obsolete.isEmpty { transport.cancel(identifiers: obsolete) }
        launched.formIntersection(pendingNames)
        started = launched.union(activeNames.intersection(pendingNames))
        var inFlight = started.count
        var held = 0
        // Small side events first (timely), then chunks, then seals.
        let ordered = pending.sorted { rank($0.kind) < rank($1.kind) }
        for item in ordered where !started.contains(item.name) {
            if let gate, !gate.mayUpload(item) { held += 1; continue }
            guard inFlight < maxInFlight else { break }
            if start(item, endpoint: endpoint, key: currentKey) { inFlight += 1 }
        }
        status.inFlight = started.count
        status.held = held
        onStatusChange?()
    }

    private func rank(_ k: OutboxKind) -> Int {
        switch k {
        case .event: return 0
        case .chunk: return 1
        case .seal: return 2
        }
    }

    @discardableResult
    private func start(_ item: OutboxItem, endpoint: ServerEndpoint, key: String) -> Bool {
        guard let data = try? Data(contentsOf: item.url) else { return false }
        guard let url = endpoint.url(item.kind.path) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        req.setValue(item.kind.contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(Self.sha256Hex(data), forHTTPHeaderField: "X-Content-SHA256")
        let rec = state.record(item.name)
        let begin = rec.nextAttemptAt.flatMap { $0 > now() ? $0 : nil }
        transport.startUpload(req, fromFile: item.url, identifier: UploadTaskID.make(key: key, name: item.name), earliestBeginDate: begin)
        started.insert(item.name)
        launched.insert(item.name)
        return true
    }

    /// Called (on `queue`) when a task finishes. `identifier` is the task description.
    public func handleCompletion(identifier: String, statusCode: Int?, body: Data?, error: Error?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let (taskKey, name) = UploadTaskID.parse(identifier) else { return }
        let currentKey = key(for: config())
        guard taskKey == currentKey else {
            // Obsolete configuration / epoch: never acknowledges; the file goes to the current server.
            if error == nil, let statusCode { log(.info, "upload", "ignoring \(statusCode) for \(name) from an obsolete configuration") }
            reconcile()
            return
        }
        started.remove(name)
        launched.remove(name)
        if let e = error as? URLError, e.code == .cancelled {
            status.inFlight = started.count
            onStatusChange?()
            reconcile()
            return
        }
        guard outbox.pendingItem(named: name) != nil else {
            status.inFlight = started.count
            return
        }
        let outcome = UploadOutcome.classify(status: statusCode, networkError: error != nil)
        let rec = state.record(name)
        let attempts = rec.attempts + 1
        let badRequests = rec.badRequests + (outcome == .badRequest ? 1 : 0)
        let detail = Self.detail(body: body, error: error, status: statusCode)
        let action = policy.action(for: outcome, attempts: attempts, badRequests: badRequests, random: random())
        var summary = UploadResultSummary(name: name, status: statusCode, message: detail, date: now(), success: false)

        switch action {
        case .markSent:
            do {
                let item = outbox.pendingItem(named: name)
                try outbox.markSent(name, now: now())
                state.remove(name)
                summary.success = true
                summary.message = statusCode == 200 ? "already stored" : "stored"
                status.lastSuccessAt = now()
                status.attention.removeAll { $0.hasPrefix("Upload error") }
                log(.info, "upload", "\(name) → \(statusCode ?? 0)")
                if let item { gate?.didAcknowledge(item) }
            } catch {
                log(.error, "upload", "could not move \(name) to sent: \(error)")
            }
        case .retry(let delay):
            state.update(name) {
                $0.attempts = attempts
                $0.nextAttemptAt = now().addingTimeInterval(delay)
                $0.lastStatus = statusCode
                $0.lastError = detail
            }
            if case .unexpected = outcome { addAttention("Upload error \(statusCode ?? 0) for \(name): \(detail)") }
            log(.warning, "upload", "\(name) failed (\(statusCode.map(String.init) ?? "network")): \(detail); retry in \(Int(delay)) s")
        case .reverifyAndRetry(let delay):
            if let problem = verifyLocalFile(name) {
                quarantine(name, reason: "400 and local file invalid: \(problem)")
            } else {
                state.update(name) {
                    $0.attempts = attempts
                    $0.badRequests = badRequests
                    $0.nextAttemptAt = now().addingTimeInterval(delay)
                    $0.lastStatus = statusCode
                    $0.lastError = detail
                }
                log(.warning, "upload", "\(name) got 400 (\(badRequests)/\(policy.maxBadRequestAttempts)); local file verified, retrying")
            }
        case .quarantine(let reason):
            quarantine(name, reason: "\(reason) — \(detail)")
        case .pauseAll(let reason):
            status.pausedReason = reason
            state.update(name) { $0.lastStatus = statusCode; $0.lastError = detail }
            addAttention(reason)
            log(.error, "upload", "uploads paused: \(reason)")
        }
        status.lastResult = summary
        status.inFlight = started.count
        onStatusChange?()
        if status.pausedReason == nil { reconcile() }
    }

    /// Token or URL changed (the configuration generation was bumped by the settings store):
    /// cancel everything and start over with the new identity.
    public func serverConfigurationChanged() {
        dispatchPrecondition(condition: .onQueue(queue))
        transport.cancelAll()
        started.removeAll()
        launched.removeAll()
        status.pausedReason = nil
        status.attention.removeAll()
        reconcile()
    }

    /// User tapped "Retry now": clear backoff and pauses, and move to a new task epoch so that
    /// slow-to-cancel old tasks can neither block nor acknowledge anything.
    public func retryNow() {
        dispatchPrecondition(condition: .onQueue(queue))
        for item in outbox.pending() { state.update(item.name) { $0.nextAttemptAt = nil } }
        state.bumpEpoch()
        status.pausedReason = nil
        transport.cancelAll()
        started.removeAll()
        launched.removeAll()
        reconcile()
    }

    public func clearAttention() {
        status.attention.removeAll()
        onStatusChange?()
    }

    private func quarantine(_ name: String, reason: String) {
        do {
            try outbox.quarantine(name, reason: reason)
            state.remove(name)
            addAttention("Kept but not uploaded: \(name) (\(reason))")
            log(.error, "upload", "quarantined \(name): \(reason)")
        } catch {
            log(.error, "upload", "quarantine of \(name) failed: \(error)")
        }
    }

    private func addAttention(_ message: String) {
        if !status.attention.contains(message) { status.attention.append(message) }
        if status.attention.count > 20 { status.attention.removeFirst(status.attention.count - 20) }
    }

    /// Re-reads the local file and checks what the server could have objected to.
    private func verifyLocalFile(_ name: String) -> String? {
        guard let item = outbox.pendingItem(named: name), let data = try? Data(contentsOf: item.url) else {
            return "unreadable"
        }
        switch item.kind {
        case .chunk(let cid, let seq):
            do {
                let parsed = try Envelope.parse(data)
                if parsed.header.captureId != cid || parsed.header.chunkSequence != seq { return "identity mismatch" }
            } catch {
                return "\(error)"
            }
        case .seal, .event:
            if (try? JSONSerialization.jsonObject(with: data)) == nil { return "not JSON" }
        }
        return nil
    }

    static func detail(body: Data?, error: Error?, status: Int?) -> String {
        if let error { return (error as NSError).localizedDescription }
        if let body, let e = try? JSONDecoder().decode(APIErrorBody.self, from: body) {
            return [e.error, e.detail].compactMap { $0 }.joined(separator: ": ")
        }
        return status.map { HTTPURLResponse.localizedString(forStatusCode: $0) } ?? "no response"
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Background session completion handler

/// Pairs UIKit's `handleEventsForBackgroundURLSession` completion handler with the session's
/// `urlSessionDidFinishEvents`, in either order, and calls the handler exactly once on main.
public final class BackgroundEventsLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var finishedAt: Date?
    public var validity: TimeInterval = 30
    public var now: () -> Date = Date.init
    public var deliver: (@escaping @Sendable () -> Void) -> Void = { h in DispatchQueue.main.async { h() } }

    public init() {}

    public func register(_ h: @escaping @Sendable () -> Void) {
        lock.lock()
        if let f = finishedAt, now().timeIntervalSince(f) <= validity {
            finishedAt = nil
            lock.unlock()
            deliver(h)
            return
        }
        finishedAt = nil
        let previous = handler
        handler = h
        lock.unlock()
        if let previous { deliver(previous) }  // never leave an older handler uncalled
    }

    public func eventsFinished() {
        lock.lock()
        if let h = handler {
            handler = nil
            lock.unlock()
            deliver(h)
            return
        }
        finishedAt = now()
        lock.unlock()
    }
}

// MARK: - Background URLSession transport

/// Which of the tasks a session lists still own their file.
///
/// A background session relaunched for a task that finished while the app wasn't running lists
/// that task as `.completed` before delivering its completion (observed with a real session on the
/// iOS Simulator). Until the completion arrives the file is still that task's: treating it as free
/// made a relaunch PUT a chunk the server had already stored. Once delivered the task owns nothing
/// (a retry is never held back by a stale listing), and a finished task that is never delivered
/// stops owning its file after `grace`, so it can't block a retry either.
public struct UploadTaskOwnership: Sendable {
    public struct Listed: Sendable {
        public var id: Int
        public var description: String?
        public var completed: Bool
        public init(id: Int, description: String?, completed: Bool) {
            self.id = id
            self.description = description
            self.completed = completed
        }
    }

    /// How long a finished task that is never delivered keeps its file.
    public var grace: TimeInterval = 120

    private var deliveredIds: Set<Int> = []
    private var finishedSince: [Int: Date] = [:]

    public init() {}

    /// The task's completion has been handed to the app.
    public mutating func delivered(_ id: Int) { deliveredIds.insert(id) }

    public mutating func owners(_ listed: [Listed], now: Date) -> Set<String> {
        let ids = Set(listed.map(\.id))
        deliveredIds.formIntersection(ids)  // forgotten once the session stops listing them
        finishedSince = finishedSince.filter { ids.contains($0.key) }
        var owners: Set<String> = []
        for task in listed {
            guard let description = task.description, !deliveredIds.contains(task.id) else { continue }
            if task.completed {
                let since = finishedSince[task.id] ?? now
                finishedSince[task.id] = since
                if now.timeIntervalSince(since) > grace { continue }
            }
            owners.insert(description)
        }
        return owners
    }
}

/// Real transport: one background `URLSession` (survives suspension and relaunches the app for
/// completions). Delegate callbacks are delivered on the engine queue.
public final class BackgroundSessionTransport: NSObject, UploadTransport, URLSessionDataDelegate, @unchecked Sendable {
    public static let sessionIdentifier = "omi-notes.upload"

    private var session: URLSession!
    private let delegateQueue: OperationQueue
    private var bodies: [Int: Data] = [:]
    private let ownershipLock = NSLock()
    private var ownership = UploadTaskOwnership()
    public var onCompletion: ((String, Int?, Data?, Error?) -> Void)?
    public let eventsLatch = BackgroundEventsLatch()

    public init(queue: DispatchQueue, identifier: String = BackgroundSessionTransport.sessionIdentifier) {
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    public func activeTaskIdentifiers(_ completion: @escaping @Sendable (Set<String>) -> Void) {
        session.getAllTasks { [self] tasks in
            let listed = tasks.map { UploadTaskOwnership.Listed(id: $0.taskIdentifier, description: $0.taskDescription, completed: $0.state == .completed) }
            ownershipLock.lock()
            let ids = ownership.owners(listed, now: Date())
            ownershipLock.unlock()
            completion(ids)
        }
    }

    public func startUpload(_ request: URLRequest, fromFile: URL, identifier: String, earliestBeginDate: Date?) {
        let task = session.uploadTask(with: request, fromFile: fromFile)
        task.taskDescription = identifier
        if let earliestBeginDate { task.earliestBeginDate = earliestBeginDate }
        task.countOfBytesClientExpectsToSend = FileIO.fileSize(fromFile) + 1024
        task.countOfBytesClientExpectsToReceive = 2048
        task.resume()
    }

    public func cancel(identifiers: Set<String>) {
        session.getAllTasks { tasks in
            for t in tasks where t.taskDescription.map(identifiers.contains) == true { t.cancel() }
        }
    }

    public func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodies[dataTask.taskIdentifier, default: Data()].append(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = bodies.removeValue(forKey: task.taskIdentifier)
        let status = (task.response as? HTTPURLResponse)?.statusCode
        ownershipLock.lock()
        ownership.delivered(task.taskIdentifier)
        ownershipLock.unlock()
        guard let id = task.taskDescription else { return }
        onCompletion?(id, status, body, error)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        eventsLatch.eventsFinished()
    }
}

// MARK: - Foreground API client

public enum APIError: Error, Equatable, CustomStringConvertible {
    case notConfigured
    case unauthorized
    case http(Int, String)
    case transport(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .notConfigured: return "Server not configured"
        case .unauthorized: return "Token rejected (401)"
        case .http(let s, let d): return "HTTP \(s): \(d)"
        case .transport(let m): return m
        case .decoding(let m): return "Unexpected response: \(m)"
        }
    }
}

/// Small async client for the read-only endpoints (status, recent conversations, capture status).
public struct APIClient: Sendable {
    public var endpoint: ServerEndpoint
    public var session: URLSession

    public init(endpoint: ServerEndpoint, session: URLSession = APIClient.defaultSession) {
        self.endpoint = endpoint
        self.session = session
    }

    public static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    public func status() async throws -> ServerStatus { try await get("/v1/status") }

    /// One page, newest first; pass the returned cursor as `before` for the next one.
    public func recentConversations(limit: Int = 20, before: String? = nil) async throws -> RecentConversationsResponse {
        var query = "limit=\(limit)"
        if let before { query += "&before=\(Self.queryValue(before))" }
        return try await get("/v1/conversations/recent", query: query)
    }

    public func conversation(_ id: String, segmentsFrom: Int = 0) async throws -> ConversationDetail {
        try await get("/v1/conversations/\(Self.queryValue(id))", query: segmentsFrom > 0 ? "segments_from=\(segmentsFrom)" : nil)
    }

    public func issues(limit: Int = 20) async throws -> [ServerIssue] {
        let r: ServerIssuesResponse = try await get("/v1/issues", query: "limit=\(limit)")
        return r.issues
    }

    /// `202` for a new retry, `200` for a repeated request id; both return the operation.
    public func retry(conversationId: String, requestId: String) async throws -> RetryOperation {
        let body = try JSONSerialization.data(withJSONObject: ["request_id": requestId])
        let r: RetryOperationResponse = try await send("POST", "/v1/conversations/\(Self.queryValue(conversationId))/retry", body: body)
        return r.operation
    }

    /// Keep a no-speaker result as a transcript with the speaker unknown; answered like `retry`.
    public func keep(conversationId: String, requestId: String) async throws -> RetryOperation {
        let body = try JSONSerialization.data(withJSONObject: ["request_id": requestId])
        let r: RetryOperationResponse = try await send("POST", "/v1/conversations/\(Self.queryValue(conversationId))/keep", body: body)
        return r.operation
    }

    public func operation(_ id: String) async throws -> RetryOperation {
        let r: RetryOperationResponse = try await get("/v1/operations/\(Self.queryValue(id))")
        return r.operation
    }

    public func watchPerformance(days: Int = 14) async throws -> WatchPerformance {
        try await get("/v1/watch/performance", query: "days=\(days)")
    }

    public func stats(days: Int = 7) async throws -> ServerStats {
        try await get("/v1/stats", query: "days=\(days)")
    }

    public func retryFailedChunks() async throws -> Int {
        let r: ChunkRetryResponse = try await send("POST", "/v1/chunks/retry", body: nil)
        return r.chunksQueued
    }

    public func search(query: String, personId: String? = nil, from: String? = nil, to: String? = nil,
                       before: String? = nil, limit: Int = 20) async throws -> SearchResponse {
        var q = ["q=\(Self.queryValue(query))", "limit=\(limit)"]
        if let personId { q.append("person_id=\(Self.queryValue(personId))") }
        if let from { q.append("date_from=\(from)") }
        if let to { q.append("date_to=\(to)") }
        if let before { q.append("before=\(Self.queryValue(before))") }
        return try await get("/v1/conversations/search", query: q.joined(separator: "&"))
    }

    static func queryValue(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    /// nil for 404 (unknown capture).
    public func captureStatus(_ captureId: String) async throws -> CaptureStatusResponse? {
        do {
            return try await get("/v1/captures/\(captureId)")
        } catch APIError.http(404, _) {
            return nil
        }
    }

    public func healthz() async throws -> Bool {
        guard let url = endpoint.url("/healthz") else { throw APIError.notConfigured }
        let (_, resp) = try await session.data(from: url)
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func get<T: Decodable>(_ path: String, query: String? = nil) async throws -> T {
        try await send("GET", path, query: query, body: nil)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: String? = nil, body: Data?) async throws -> T {
        guard let url = endpoint.url(path, query: query) else { throw APIError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.transport((error as NSError).localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(code) else {
            throw APIError.http(code, Uploader.detail(body: data, error: nil, status: code))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }
}
