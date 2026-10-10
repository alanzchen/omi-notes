import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

@Suite struct UploadPolicyTests {
    let policy = UploadPolicy()

    @Test func classification() {
        #expect(UploadOutcome.classify(status: 201, networkError: false) == .acknowledged(status: 201))
        #expect(UploadOutcome.classify(status: 200, networkError: false) == .acknowledged(status: 200))
        #expect(UploadOutcome.classify(status: 400, networkError: false) == .badRequest)
        #expect(UploadOutcome.classify(status: 401, networkError: false) == .unauthorized)
        #expect(UploadOutcome.classify(status: 409, networkError: false) == .conflict)
        #expect(UploadOutcome.classify(status: 413, networkError: false) == .tooLarge)
        #expect(UploadOutcome.classify(status: 422, networkError: false) == .invalid)
        #expect(UploadOutcome.classify(status: 507, networkError: false) == .transient(status: 507))
        #expect(UploadOutcome.classify(status: 503, networkError: false) == .transient(status: 503))
        #expect(UploadOutcome.classify(status: nil, networkError: true) == .transient(status: nil))
        #expect(UploadOutcome.classify(status: 404, networkError: false) == .unexpected(status: 404))
    }

    @Test func actions() {
        #expect(policy.action(for: .acknowledged(status: 201), attempts: 1, badRequests: 0, random: 0.5) == .markSent)
        #expect(policy.action(for: .unauthorized, attempts: 1, badRequests: 0, random: 0.5) == .pauseAll(reason: "Server rejected the token (401)"))
        if case .quarantine = policy.action(for: .conflict, attempts: 1, badRequests: 0, random: 0.5) {} else { Issue.record("409 must quarantine") }
        if case .quarantine = policy.action(for: .tooLarge, attempts: 1, badRequests: 0, random: 0.5) {} else { Issue.record("413 must quarantine") }
        if case .quarantine = policy.action(for: .invalid, attempts: 1, badRequests: 0, random: 0.5) {} else { Issue.record("422 must quarantine") }
        for n in 1...4 {
            if case .reverifyAndRetry = policy.action(for: .badRequest, attempts: n, badRequests: n, random: 0.5) {} else { Issue.record("400 #\(n) should retry") }
        }
        if case .quarantine = policy.action(for: .badRequest, attempts: 5, badRequests: 5, random: 0.5) {} else { Issue.record("5th 400 must quarantine") }
        #expect(policy.action(for: .transient(status: 503), attempts: 1, badRequests: 0, random: 0.5) == .retry(after: 30))
    }

    @Test func backoffGrowsCapsAndJitters() {
        #expect(policy.backoff(attempt: 1, random: 0.5) == 30)
        #expect(policy.backoff(attempt: 2, random: 0.5) == 60)
        #expect(policy.backoff(attempt: 4, random: 0.5) == 240)
        #expect(policy.backoff(attempt: 20, random: 0.5) == 1800)
        #expect(policy.backoff(attempt: 1, random: 0) == 24)
        #expect(policy.backoff(attempt: 1, random: 1) == 36)
        #expect(policy.backoff(attempt: 30, random: 1) == 2160)
    }
}

/// Models a background URLSession closely enough to expose ordering bugs (review #19): every task
/// is a distinct instance; enumeration can return a stale snapshot later; cancellation can be
/// asynchronous (cancelled tasks stay listed until they complete with `URLError.cancelled`).
final class FakeUploadTransport: UploadTransport, @unchecked Sendable {
    final class Task {
        let id: Int
        let description: String
        let request: URLRequest
        let file: URL
        let earliest: Date?
        var cancelling = false
        var done = false
        init(id: Int, description: String, request: URLRequest, file: URL, earliest: Date?) {
            self.id = id
            self.description = description
            self.request = request
            self.file = file
            self.earliest = earliest
        }
        var name: String { UploadTaskID.parse(description)?.name ?? description }
        var key: String { UploadTaskID.parse(description)?.key ?? "" }
    }

    var tasks: [Task] = []
    var cancelCalls = 0
    var asyncEnumeration = false
    var asyncCancellation = false
    private var pendingEnumerations: [(Set<String>, @Sendable (Set<String>) -> Void)] = []
    private var nextId = 1

    var active: [Task] { tasks.filter { !$0.done } }
    /// Set to list tasks as the system's background session does: a finished task stays listed
    /// (completed) until it is `unlisted`, and the listing goes through the production filter.
    var systemListing: UploadTaskOwnership?
    var unlisted: Set<Int> = []
    var now = Date()

    func activeTaskIdentifiers(_ completion: @escaping @Sendable (Set<String>) -> Void) {
        var snapshot = Set(active.map(\.description))
        if var o = systemListing {
            let listed = tasks.filter { !unlisted.contains($0.id) }
                .map { UploadTaskOwnership.Listed(id: $0.id, description: $0.description, completed: $0.done) }
            snapshot = o.owners(listed, now: now)
            systemListing = o
        }
        if asyncEnumeration { pendingEnumerations.append((snapshot, completion)) } else { completion(snapshot) }
    }

    /// Delivers queued enumerations with the snapshot taken when they were requested.
    func flushEnumerations() {
        let p = pendingEnumerations
        pendingEnumerations.removeAll()
        for (snap, cb) in p { cb(snap) }
    }

    func startUpload(_ request: URLRequest, fromFile: URL, identifier: String, earliestBeginDate: Date?) {
        tasks.append(Task(id: nextId, description: identifier, request: request, file: fromFile, earliest: earliestBeginDate))
        nextId += 1
    }

    func cancel(identifiers: Set<String>) {
        cancelCalls += 1
        for t in active where identifiers.contains(t.description) { markCancelling(t) }
    }

    func cancelAll() {
        cancelCalls += 1
        for t in active { markCancelling(t) }
    }

    private func markCancelling(_ t: Task) {
        t.cancelling = true
        if !asyncCancellation { t.done = true }
    }

    /// Async cancellation: finish cancelling; the caller delivers `URLError.cancelled` for each.
    func takeCancelled() -> [Task] {
        let c = active.filter(\.cancelling)
        c.forEach { $0.done = true }
        return c
    }

    func preexisting(_ description: String) {
        tasks.append(Task(id: nextId, description: description, request: URLRequest(url: URL(string: "https://x")!), file: URL(fileURLWithPath: "/dev/null"), earliest: nil))
        nextId += 1
    }
}

final class UploaderHarness: @unchecked Sendable {
    let t = TestEnv()
    let queue = DispatchQueue(label: "test.uploader")
    let transport = FakeUploadTransport()
    var uploader: Uploader!
    var now = Date(timeIntervalSince1970: 1_790_451_125)
    var cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: URL(string: "https://mac.tailnet.ts.net/")!, token: "secret-token-123"), generation: 1)

    init() {
        uploader = Uploader(
            outbox: t.outbox, state: UploadStateStore(url: t.dirs.state.appendingPathComponent("upload-state.json")),
            transport: transport, queue: queue, config: { [unowned self] in self.cfg })
        uploader.now = { [unowned self] in self.now }
        uploader.random = { 0.5 }
    }

    func sync(_ body: () -> Void) {
        queue.sync(execute: body)
        queue.sync {}  // drain reconcile hops
    }

    func reconcile() { sync { uploader.reconcile() } }

    var started: [FakeUploadTransport.Task] { transport.tasks }

    func task(for name: String) -> FakeUploadTransport.Task? { transport.active.last { $0.name == name } }

    func complete(_ name: String, status: Int?, body: String? = nil, error: Error? = nil) {
        guard let task = task(for: name) else { Issue.record("no active task for \(name)"); return }
        complete(task: task, status: status, body: body, error: error)
    }

    func complete(task: FakeUploadTransport.Task, status: Int?, body: String? = nil, error: Error? = nil) {
        task.done = true
        transport.systemListing?.delivered(task.id)
        sync { uploader.handleCompletion(identifier: task.description, statusCode: status, body: body.map { Data($0.utf8) }, error: error) }
    }

    func deliverCancellations() {
        for task in transport.takeCancelled() {
            sync { uploader.handleCompletion(identifier: task.description, statusCode: nil, body: nil, error: URLError(.cancelled)) }
        }
    }

    func changeServer(token: String) {
        cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: URL(string: "https://new.tailnet.ts.net")!, token: token), generation: cfg.generation + 1)
        sync { uploader.serverConfigurationChanged() }
    }

    func writeChunk(seq: Int, capture: String = "cap-1") throws -> OutboxItem {
        let payload = BLERecord(tOffsetUs: 0, flags: 1, bytes: notification(seq: 1)).encoded()
        let h = EnvelopeHeader(
            captureId: capture, chunkSequence: seq, deviceId: "dev", deviceName: nil, modelNumber: nil, firmwareRevision: nil,
            hardwareRevision: nil, source: .liveBLE, payloadFormat: .bleNotificationsV1, codecId: 21,
            captureStartedAt: "2026-09-26T19:32:05.123Z", chunkStartOffsetUs: 0, chunkEndOffsetUs: 1000, clockQuality: .phoneAnchored,
            timezone: nil, recordCount: 1, payloadBytes: payload.count, offlineStorage: nil, ring: nil, appVersion: nil)
        return try t.outbox.write(try Envelope.build(header: h, payload: payload), kind: .chunk(captureId: capture, sequence: seq))
    }
}

@Suite struct UploaderTests {
    @Test func startsPutWithChecksumAndAuth() throws {
        let h = UploaderHarness()
        let item = try h.writeChunk(seq: 0)
        let seal = try h.t.outbox.write(Data(#"{"a":1}"#.utf8), kind: .seal(captureId: "cap-1"))
        h.reconcile()
        #expect(h.started.count == 2)
        let chunkReq = try #require(h.task(for: item.name))
        #expect(chunkReq.request.httpMethod == "PUT")
        #expect(chunkReq.request.url?.absoluteString == "https://mac.tailnet.ts.net/v1/captures/cap-1/chunks/0")
        #expect(chunkReq.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token-123")
        #expect(chunkReq.request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(chunkReq.request.value(forHTTPHeaderField: "X-Content-SHA256") == Uploader.sha256Hex(try Data(contentsOf: item.url)))
        #expect(chunkReq.earliest == nil)
        #expect(chunkReq.key == h.uploader.key(for: h.cfg))
        let sealReq = try #require(h.task(for: seal.name))
        #expect(sealReq.request.url?.path == "/v1/captures/cap-1/seal")
        #expect(sealReq.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(h.started.first?.name == item.name)  // chunks before seals
        h.reconcile()
        #expect(h.started.count == 2)  // still active: nothing new
    }

    @Test func knownSHA256() {
        #expect(Uploader.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func successMovesToSent() throws {
        let h = UploaderHarness()
        let item = try h.writeChunk(seq: 0)
        h.reconcile()
        h.complete(item.name, status: 201, body: #"{"stored":true}"#)
        #expect(h.t.outbox.pending().isEmpty)
        #expect(h.t.outbox.sent().map(\.name) == [item.name])
        #expect(h.uploader.status.lastResult?.success == true)
        #expect(FileIO.modificationDate(h.t.outbox.sent()[0].url).timeIntervalSince1970 == h.now.timeIntervalSince1970)
    }

    @Test func duplicateIsAlsoAcknowledged() throws {
        let h = UploaderHarness()
        let item = try h.writeChunk(seq: 0)
        h.reconcile()
        h.complete(item.name, status: 200)
        #expect(h.t.outbox.sent().count == 1)
    }

    @Test func transientRetriesWithBackoff() throws {
        let h = UploaderHarness()
        let item = try h.writeChunk(seq: 0)
        h.reconcile()
        h.complete(item.name, status: 503, body: #"{"error":"busy","detail":"try later"}"#)
        #expect(h.t.outbox.pending().count == 1)
        let retry = try #require(h.task(for: item.name))
        #expect(h.started.count == 2)
        #expect(retry.earliest == h.now.addingTimeInterval(30))
        #expect(h.uploader.state.record(item.name).attempts == 1)
        #expect(h.uploader.status.lastResult?.message == "busy: try later")
        h.complete(item.name, status: nil, error: URLError(.notConnectedToInternet))
        #expect(h.task(for: item.name)?.earliest == h.now.addingTimeInterval(60))
    }

    @Test func conflictAndInvalidAreQuarantinedNotRetried() throws {
        let h = UploaderHarness()
        let a = try h.writeChunk(seq: 0)
        let b = try h.writeChunk(seq: 1)
        let c = try h.writeChunk(seq: 2)
        h.reconcile()
        h.complete(a.name, status: 409)
        h.complete(b.name, status: 422)
        h.complete(c.name, status: 413)
        #expect(h.t.outbox.pending().isEmpty)
        #expect(Set(h.t.outbox.quarantined().map(\.name)) == [a.name, b.name, c.name])
        #expect(h.started.count == 3)
        #expect(h.uploader.status.attention.count == 3)
    }

    @Test func unauthorizedPausesEverything() throws {
        let h = UploaderHarness()
        let a = try h.writeChunk(seq: 0)
        h.reconcile()
        h.complete(a.name, status: 401)
        #expect(h.uploader.status.pausedReason != nil)
        _ = try h.writeChunk(seq: 1)
        h.reconcile()
        #expect(h.started.count == 1)
        #expect(h.t.outbox.pending().count == 2)
        h.changeServer(token: "new-token")
        #expect(h.uploader.status.pausedReason == nil)
        #expect(h.started.count == 3)
        #expect(h.started.last?.request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
    }

    @Test func badRequestRetriesFiveTimesThenQuarantines() throws {
        let h = UploaderHarness()
        let a = try h.writeChunk(seq: 0)
        h.reconcile()
        for _ in 0..<4 {
            h.complete(a.name, status: 400)
            #expect(h.t.outbox.pending().count == 1)
        }
        h.complete(a.name, status: 400)
        #expect(h.t.outbox.pending().isEmpty)
        #expect(h.t.outbox.quarantined().map(\.name) == [a.name])
    }

    @Test func badRequestWithCorruptLocalFileQuarantinesImmediately() throws {
        let h = UploaderHarness()
        let a = try h.writeChunk(seq: 0)
        h.reconcile()
        try Data("garbage".utf8).write(to: a.url)
        h.complete(a.name, status: 400)
        #expect(h.t.outbox.quarantined().map(\.name) == [a.name])
    }

    @Test func notConfiguredDoesNothing() throws {
        let h = UploaderHarness()
        h.cfg = UploadConfig(endpoint: nil, generation: 1)
        _ = try h.writeChunk(seq: 0)
        h.reconcile()
        #expect(h.started.isEmpty)
        #expect(h.uploader.status.configured == false)
    }

    @Test func reconcileSkipsTasksTheSystemStillHolds() throws {
        let h = UploaderHarness()
        let a = try h.writeChunk(seq: 0)
        let b = try h.writeChunk(seq: 1)
        h.transport.preexisting(UploadTaskID.make(key: h.uploader.key(for: h.cfg), name: a.name))  // survived a relaunch
        h.reconcile()
        #expect(h.started.filter { $0.name == b.name }.count == 1)
        #expect(h.started.filter { $0.name == a.name }.count == 1)
    }

    @Test func respectsMaxInFlight() throws {
        let h = UploaderHarness()
        h.uploader.maxInFlight = 2
        for i in 0..<5 { _ = try h.writeChunk(seq: i) }
        h.reconcile()
        #expect(h.started.count == 2)
        h.complete(h.started[0].name, status: 201)
        #expect(h.started.count == 3)
    }

    @Test func disabledUntilRecoveryCompletes() throws {
        let h = UploaderHarness()
        h.uploader.enabled = false
        _ = try h.writeChunk(seq: 0)
        h.reconcile()
        #expect(h.started.isEmpty)
        h.uploader.enabled = true
        h.reconcile()
        #expect(h.started.count == 1)
    }

    // MARK: Review #10 / #13 / #19 regressions

    /// #10: a 2xx from the old server arriving after a server change must not acknowledge the file.
    @Test func obsoleteServerCompletionNeverAcknowledges() throws {
        let h = UploaderHarness()
        h.transport.asyncCancellation = true
        let a = try h.writeChunk(seq: 0)
        h.reconcile()
        let oldTask = try #require(h.task(for: a.name))
        h.changeServer(token: "new-token")
        let newTask = try #require(h.transport.active.last { $0.name == a.name && $0.id != oldTask.id })
        #expect(newTask.request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
        // The old request completes successfully after the switch (its cancel lost the race).
        h.complete(task: oldTask, status: 201)
        #expect(h.t.outbox.pending().map(\.name) == [a.name], "old-server 201 must not move the file to sent/")
        #expect(h.t.outbox.sent().isEmpty)
        h.complete(task: newTask, status: 201)
        #expect(h.t.outbox.sent().map(\.name) == [a.name])
    }

    /// #10: a reconciliation that started before the server change must not start old-endpoint tasks.
    @Test func reconcileInFlightDuringServerChangeUsesNewEndpoint() throws {
        let h = UploaderHarness()
        h.transport.asyncEnumeration = true
        _ = try h.writeChunk(seq: 0)
        h.reconcile()  // enumeration pending
        h.cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: URL(string: "https://new.tailnet.ts.net")!, token: "new-token"), generation: 2)
        h.sync { h.transport.flushEnumerations() }
        h.sync { h.transport.flushEnumerations() }
        #expect(!h.started.isEmpty)
        #expect(h.started.allSatisfy { $0.request.url?.host == "new.tailnet.ts.net" && $0.key == h.uploader.key(for: h.cfg) })
    }

    /// #13: "Retry now" with slow cancellation must not strand the pending file.
    @Test func retryNowWithDelayedCancellationDoesNotStrand() throws {
        let h = UploaderHarness()
        h.transport.asyncCancellation = true
        let a = try h.writeChunk(seq: 0)
        h.reconcile()
        let first = try #require(h.task(for: a.name))
        h.sync { h.uploader.retryNow() }
        // Old task still listed (cancellation not finished) yet a replacement is already running.
        let replacement = h.transport.active.filter { $0.name == a.name && $0.id != first.id && !$0.cancelling }
        #expect(replacement.count == 1)
        h.deliverCancellations()  // old task reports cancelled later
        #expect(h.transport.active.filter { $0.name == a.name }.count == 1)
        h.complete(task: try #require(replacement.first), status: 201)
        #expect(h.t.outbox.sent().map(\.name) == [a.name])
    }

    /// #13: a cancelled callback of the current identity triggers another reconcile.
    @Test func cancelledCallbackReconciles() throws {
        let h = UploaderHarness()
        let a = try h.writeChunk(seq: 0)
        h.reconcile()
        let task = try #require(h.task(for: a.name))
        h.complete(task: task, status: nil, error: URLError(.cancelled))  // e.g. cancelled by the system
        #expect(h.transport.active.filter { $0.name == a.name }.count == 1, "the file is re-enqueued")
    }

    /// #19: obsolete tasks found during enumeration (e.g. after relaunch with a new server) are cancelled.
    @Test func obsoleteTasksFromEnumerationAreCancelled() throws {
        let h = UploaderHarness()
        let a = try h.writeChunk(seq: 0)
        h.transport.preexisting(UploadTaskID.make(key: "0.1", name: a.name))
        h.reconcile()
        #expect(h.transport.tasks.first?.cancelling == true)
        #expect(h.transport.active.filter { $0.name == a.name && $0.key == h.uploader.key(for: h.cfg) }.count == 1)
    }

    @Test func epochSurvivesRelaunch() throws {
        let t = TestEnv()
        let url = t.dirs.state.appendingPathComponent("upload-state.json")
        let s1 = UploadStateStore(url: url)
        s1.bumpEpoch()
        s1.update("x") { $0.attempts = 2 }
        let s2 = UploadStateStore(url: url)
        #expect(s2.epoch == s1.epoch)
        #expect(s2.record("x").attempts == 2)
    }
}

// MARK: - Review #3: ring sync_complete seals wait for earlier ring captures

@Suite struct RingSealOrderingTests {
    /// A: interrupted ring capture with a chunk; B: later empty sync_complete capture.
    func setUp(_ h: UploaderHarness, generationB: Int = 1) throws -> (ledger: RingCaptureLedger, aChunk: OutboxItem, aSeal: OutboxItem, bSeal: OutboxItem) {
        let ledger = RingCaptureLedger(dirs: h.t.dirs, outbox: h.t.outbox)
        h.uploader.gate = ledger
        try ledger.register(captureId: "ring-a", deviceId: "dev", generation: 1)
        try ledger.register(captureId: "ring-b", deviceId: "dev", generation: generationB)
        let aChunk = try h.writeChunk(seq: 0, capture: "ring-a")
        let aSeal = try h.t.outbox.write(try ContractJSON.encode(SealBody(lastChunkSequence: 0, reason: .syncInterrupted, endedAt: "x", endOffsetUs: 1, deviceId: "dev", source: .deviceRing)), kind: .seal(captureId: "ring-a"))
        let bSeal = try h.t.outbox.write(try ContractJSON.encode(SealBody(
            lastChunkSequence: -1, reason: .syncComplete, endedAt: "x", endOffsetUs: 1, deviceId: "dev", source: .deviceRing,
            ring: RingSealEvidence(generation: generationB, infoReadSeq: 106, infoWriteSeq: 106, doneNextSeq: 106, dropped: 0, rtcValid: true, coversUntil: "x"))),
            kind: .seal(captureId: "ring-b"))
        return (ledger, aChunk, aSeal, bSeal)
    }

    @Test func laterSyncCompleteWaitsUntilEarlierCaptureFullyAcknowledged() throws {
        let h = UploaderHarness()
        let s = try setUp(h)
        h.reconcile()
        #expect(h.task(for: s.bSeal.name) == nil, "B's sync_complete must be held")
        #expect(h.task(for: s.aChunk.name) != nil)
        #expect(h.task(for: s.aSeal.name) != nil)
        #expect(h.uploader.status.held == 1)
        h.complete(s.aChunk.name, status: 201)
        #expect(h.task(for: s.bSeal.name) == nil, "A's seal not yet acknowledged")
        h.complete(s.aSeal.name, status: 200)
        #expect(h.task(for: s.bSeal.name) != nil, "released once A is fully acknowledged")
        #expect(s.ledger.snapshot.map(\.captureId) == ["ring-b"], "A pruned from the ledger")
    }

    @Test func quarantinedEarlierChunkKeepsHolding() throws {
        let h = UploaderHarness()
        let s = try setUp(h)
        h.reconcile()
        h.complete(s.aChunk.name, status: 422)
        h.complete(s.aSeal.name, status: 200)
        #expect(h.task(for: s.bSeal.name) == nil)
        #expect(s.ledger.heldReason(try #require(h.t.outbox.pendingItem(named: s.bSeal.name))) != nil)
    }

    @Test func differentGenerationDoesNotBlock() throws {
        let h = UploaderHarness()
        let s = try setUp(h, generationB: 2)
        h.reconcile()
        #expect(h.task(for: s.bSeal.name) != nil)
    }

    @Test func interruptedSealsAndChunksAreNeverHeld() throws {
        let h = UploaderHarness()
        let ledger = RingCaptureLedger(dirs: h.t.dirs, outbox: h.t.outbox)
        h.uploader.gate = ledger
        try ledger.register(captureId: "ring-a", deviceId: "dev", generation: 1)
        try ledger.register(captureId: "ring-b", deviceId: "dev", generation: 1)
        _ = try h.writeChunk(seq: 0, capture: "ring-a")
        let bChunk = try h.writeChunk(seq: 0, capture: "ring-b")
        let bSeal = try h.t.outbox.write(try ContractJSON.encode(SealBody(lastChunkSequence: 0, reason: .syncInterrupted, endedAt: "x", endOffsetUs: 1, deviceId: "dev", source: .deviceRing)), kind: .seal(captureId: "ring-b"))
        h.reconcile()
        #expect(h.task(for: bChunk.name) != nil)
        #expect(h.task(for: bSeal.name) != nil)
    }

    @Test func unsealedEarlierCaptureInJournalBlocks() throws {
        let h = UploaderHarness()
        let ledger = RingCaptureLedger(dirs: h.t.dirs, outbox: h.t.outbox)
        try ledger.register(captureId: "ring-a", deviceId: "dev", generation: 1)
        try ledger.register(captureId: "ring-b", deviceId: "dev", generation: 1)
        try FileManager.default.createDirectory(at: h.t.dirs.journalRing.appendingPathComponent("ring-a"), withIntermediateDirectories: true)
        #expect(ledger.blockers(of: "ring-b") == ["ring-a"])
        try FileManager.default.removeItem(at: h.t.dirs.journalRing.appendingPathComponent("ring-a"))
        #expect(ledger.blockers(of: "ring-b").isEmpty)
    }
}

// MARK: - Review #14: background completion handler latch

@Suite struct BackgroundEventsLatchTests {
    final class Counter: @unchecked Sendable {
        var n = 0
    }

    func latch() -> BackgroundEventsLatch {
        let l = BackgroundEventsLatch()
        l.deliver = { $0() }
        return l
    }

    @Test func handlerRegisteredBeforeEventsFinish() {
        let l = latch()
        let c = Counter()
        l.register { c.n += 1 }
        #expect(c.n == 0)
        l.eventsFinished()
        #expect(c.n == 1)
        l.eventsFinished()
        #expect(c.n == 1)
    }

    @Test func eventsFinishBeforeHandlerIsRegistered() {
        let l = latch()
        let c = Counter()
        l.eventsFinished()  // session drained its events before UIKit handed over the handler
        l.register { c.n += 1 }
        #expect(c.n == 1, "a late handler is still called")
        l.eventsFinished()
        #expect(c.n == 1, "exactly once")
    }

    @Test func staleFinishIsNotReused() {
        let l = latch()
        var clock = Date(timeIntervalSince1970: 0)
        l.now = { clock }
        let c = Counter()
        l.eventsFinished()
        clock = clock.addingTimeInterval(120)
        l.register { c.n += 1 }
        #expect(c.n == 0)
        l.eventsFinished()
        #expect(c.n == 1)
    }
}
