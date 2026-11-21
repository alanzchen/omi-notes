// Astra's IT3 refresh check (omi-notes-reviews/nightly-2026-11-21-it3/swift/AstraNovember21R3Checks.swift), adopted unchanged.
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

extension RetryFlowTests {
    @MainActor @Suite(.serialized) struct AstraNovember21R3RefreshChecks {
        @Test func olderOperationAnswerMustNotUndoNewerDone() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            await m.refreshServer()
            let entry = try m.retryStore.begin(conversationId: "conv-1", server: "https://mac.ts.net|vault-a")
            let op = try JSONDecoder().decode(RetryOperation.self, from: Data(#"{"id":"op-1","kind":"retry","conversation_id":"conv-1","stage":"summarizing","state":"running"}"#.utf8))
            m.retryStore.record(op, for: entry.requestId)
            let path = "/v1/operations/op-1"
            AppServerStub.holdNext.insert(path)
            let older = Task { await m.refreshServer() }
            try await AppServerStub.waitUntilHeld(path)
            AppServerStub.routes[path] = [(200, RetryFlowTests.opJSON("op-1", "done"))]
            await m.refreshServer()
            #expect(m.retries["conv-1"]?.state == "done")
            AppServerStub.routes[path] = [(200, RetryFlowTests.opJSON("op-1", "running"))]
            AppServerStub.release(path, offline: false)
            await older.value
            #expect(m.retries["conv-1"]?.state == "done", "older refresh must not change an operation already shown as done")
        }
    }
}
