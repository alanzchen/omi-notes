import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture

/// Nightly 2026-11-21: Alan's server resolved but timed out for ~38 h. Every minute the re-check set the server to
/// `.checking` for up to 15 s (the request timeout), and every surface reads `.checking` as calm: Home "Uploading audio",
/// a bare Transfers card, the Live Activity "Waiting to send". A re-check of the same server keeps the last verdict on
/// screen until its own answer; only a new or changed server starts from "checking".
extension RetryFlowTests {
@MainActor @Suite(.serialized) struct ServerVerdictTests {
    @Test func aRecheckKeepsUnreachableUntilItsAnswer() async throws {
        let (m, root) = try RetryFlowTests().model()
        defer { try? FileManager.default.removeItem(at: root) }
        AppServerStub.offline = true
        await m.refreshServer()
        guard case .unreachable = m.server else { Issue.record("not unreachable: \(m.server)"); return }
        AppServerStub.holdNext.insert("/v1/status")
        let again = Task { await m.refreshServer() }
        try await AppServerStub.waitUntilHeld("/v1/status")
        if case .unreachable = m.server {} else { Issue.record("a re-check showed \(m.server) while its answer was pending") }
        AppServerStub.release("/v1/status", offline: true)
        await again.value
        if case .unreachable = m.server {} else { Issue.record("\(m.server)") }
    }

    @Test func aChangedServerStartsFromChecking() async throws {
        let (m, root) = try RetryFlowTests().model()
        defer { try? FileManager.default.removeItem(at: root) }
        AppServerStub.offline = true
        await m.refreshServer()
        try m.engine.settings.setServer(url: URL(string: "https://second.invalid")!, token: "synthetic")
        AppServerStub.holdNext.insert("/v1/status")
        let next = Task { await m.refreshServer() }
        try await AppServerStub.waitUntilHeld("/v1/status")
        #expect(m.server == .checking, "the old server's verdict says nothing about the new one")
        AppServerStub.release("/v1/status", offline: true)
        await next.value
    }
}
}
