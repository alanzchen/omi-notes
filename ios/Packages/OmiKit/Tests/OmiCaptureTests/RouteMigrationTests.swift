import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol

/// 2026-11-22: the same server (same token, same vault) moves from the tailnet Mac address to a new
/// host. Every queued part must survive the switch and go to the new address; late answers from the
/// old address must neither acknowledge nor double-count anything; nothing leaves the outbox before
/// a receipt from the new address.
@Suite struct RouteMigrationTests {
    final class RecordingGate: UploadGate {
        var acknowledged: [String] = []
        func mayUpload(_ item: OutboxItem) -> Bool { true }
        func didAcknowledge(_ item: OutboxItem) { acknowledged.append(item.name) }
        func heldReason(_ item: OutboxItem) -> String? { nil }
    }

    static let oldBase = URL(string: "https://alan-mac-studio.tailcd4f.ts.net:9443")!
    static let newBase = URL(string: "https://oracle.tailcd4f.ts.net:8446/")!

    func moveSameServer(_ h: UploaderHarness) {
        h.cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: Self.newBase, token: "secret-token-123"), generation: h.cfg.generation + 1)
        h.sync { h.uploader.serverConfigurationChanged() }
    }

    @Test func everyQueuedPartSurvivesAndGoesToTheNewAddressOnce() throws {
        let h = UploaderHarness()
        h.cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: Self.oldBase, token: "secret-token-123"), generation: 1)
        h.transport.asyncCancellation = true
        let gate = RecordingGate()
        h.uploader.gate = gate
        var delivered: [String] = []
        h.uploader.onFinished = { id, outcome, _ in if outcome == .delivered { delivered.append(id) } }
        let parts = try (0..<6).map { try h.writeChunk(seq: $0) }
        let seal = try h.t.outbox.write(Data(#"{"a":1}"#.utf8), kind: .seal(captureId: "cap-1"))
        let names = Set(parts.map(\.name) + [seal.name])
        h.reconcile()
        let oldTasks = h.transport.active
        #expect(oldTasks.count == names.count)
        moveSameServer(h)
        #expect(Set(h.t.outbox.pending().map(\.name)) == names, "a server change keeps every queued part")
        let fresh = h.transport.active.filter { t in !oldTasks.contains { $0 === t } }
        #expect(Set(fresh.map(\.name)) == names)
        for t in fresh {
            #expect(t.request.url?.host == "oracle.tailcd4f.ts.net" && t.request.url?.port == 8446)
            #expect(t.request.url?.path.hasPrefix("/v1/captures/cap-1/") == true && t.request.url?.path.contains("//") == false)
            #expect(t.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token-123")
        }
        // the old address answers late (its cancel lost the race): no receipt, no count
        for t in oldTasks.prefix(3) { h.complete(task: t, status: 201) }
        h.deliverCancellations()
        #expect(Set(h.t.outbox.pending().map(\.name)) == names, "nothing leaves the outbox on an old-address answer")
        #expect(gate.acknowledged.isEmpty && delivered.isEmpty)
        // the new address has some already (the old address stored them before the switch): 200 already stored
        for (i, t) in fresh.enumerated() { h.complete(task: t, status: i < 3 ? 200 : 201) }
        #expect(h.t.outbox.pending().isEmpty)
        #expect(Set(h.t.outbox.sent().map(\.name)) == names)
        #expect(gate.acknowledged.count == names.count && Set(gate.acknowledged) == names, "each part acknowledged once, by the new address")
        #expect(delivered.count == names.count)
    }

    /// 2.5 days of "can't reach" leave each part backing off for up to 30 min. That backoff was earned against the
    /// old address: the new address is tried at once, as "Retry now" does.
    @Test func backoffFromTheOldAddressDoesNotDelayTheNewOne() throws {
        let h = UploaderHarness()
        h.cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: Self.oldBase, token: "secret-token-123"), generation: 1)
        let a = try h.writeChunk(seq: 0)
        h.reconcile()
        for _ in 0..<12 { h.complete(a.name, status: nil, error: URLError(.timedOut)) }
        #expect(h.task(for: a.name)?.earliest.map { $0 > h.now.addingTimeInterval(20 * 60) } == true)
        moveSameServer(h)
        let t = try #require(h.task(for: a.name))
        #expect(t.request.url?.host == "oracle.tailcd4f.ts.net")
        #expect(t.earliest == nil, "the first try at the new address starts now, not after the old address's backoff")
        #expect(h.t.outbox.pending().map(\.name) == [a.name])
    }

    /// (c) relaunch mid-change: the new configuration is persisted before the uploader hears of it; a fresh uploader
    /// with an empty session starts every part against the new address, and an old-generation task the system still
    /// lists is cancelled, not trusted.
    @Test func relaunchAfterTheChangeStartsEverythingAtTheNewAddress() throws {
        let h = UploaderHarness()
        h.cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: Self.oldBase, token: "secret-token-123"), generation: 1)
        let parts = try (0..<3).map { try h.writeChunk(seq: $0) }
        h.reconcile()
        let oldDescriptions = h.transport.active.map(\.description)
        let relaunched = UploaderHarness(reusing: h)
        relaunched.cfg = UploadConfig(endpoint: ServerEndpoint(baseURL: Self.newBase, token: "secret-token-123"), generation: 2)
        oldDescriptions.forEach { relaunched.transport.preexisting($0) }
        relaunched.reconcile()
        let fresh = relaunched.transport.active.filter { $0.key == relaunched.uploader.key(for: relaunched.cfg) }
        #expect(Set(fresh.map(\.name)) == Set(parts.map(\.name)))
        #expect(fresh.allSatisfy { $0.request.url?.host == "oracle.tailcd4f.ts.net" })
        #expect(relaunched.transport.active.allSatisfy { $0.key == relaunched.uploader.key(for: relaunched.cfg) }, "old-generation tasks are cancelled")
        #expect(Set(relaunched.t.outbox.pending().map(\.name)) == Set(parts.map(\.name)))
    }

    /// (b) the address typed with or without a trailing slash, with a port: the same request URLs.
    @Test func trailingSlashAndPortGiveTheSameRequestURL() {
        for raw in ["https://oracle.tailcd4f.ts.net:8446", "https://oracle.tailcd4f.ts.net:8446/", "https://oracle.tailcd4f.ts.net:8446//"] {
            let e = ServerEndpoint(baseURL: URL(string: raw)!, token: "t")
            #expect(e.url("/v1/status")?.absoluteString == "https://oracle.tailcd4f.ts.net:8446/v1/status")
        }
    }
}
