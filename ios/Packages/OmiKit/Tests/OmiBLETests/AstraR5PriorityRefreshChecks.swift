// Astra's IT5 check (omi-notes-reviews/nightly-2026-11-21-it5/swift/AstraR5PriorityRefreshChecks.swift), adopted unchanged.
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

extension RetryFlowTests {
    @MainActor @Suite(.serialized) struct AstraR5PriorityRefreshChecks {
        @Test func olderRefreshPriorityRefusalMustNotUndoNewerSuccess() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            AppServerStub.routes["/v1/status"] = [(200, #"{"ok":true,"vault_id":"vault-a","features":["issues","retry","value_notes"],"worker":{"present":true}}"#)]
            await m.refreshServer()
            let key = try #require(m.priorityKey)
            let entry = try m.priorityStore.choose("conv-1", state: "important", server: key)
            let path = "/v1/conversations/conv-1/priority"
            AppServerStub.holdNext.insert(path)
            let older = Task { await m.refreshServer() }
            try await AppServerStub.waitUntilHeld(path)
            AppServerStub.routes[path] = [(200, #"{"state":"important","revision":1,"set_at":"2026-11-21T03:00:00Z","applied":true}"#)]
            await m.refreshServer()
            #expect(m.priorityStore.pending("conv-1", server: key) == nil)
            #expect(m.priorityMessages["conv-1"] == nil)
            AppServerStub.routes[path] = [(404, #"{"error":"not_found","detail":"not found earlier"}"#)]
            AppServerStub.release(path, offline: false)
            await older.value
            #expect(m.priorityStore.entries(server: key).allSatisfy { $0.requestId != entry.requestId })
            #expect(m.priorityMessages["conv-1"] == nil,
                "an obsolete refresh must not say the server refused a choice a newer refresh confirmed")
        }
    }
}
