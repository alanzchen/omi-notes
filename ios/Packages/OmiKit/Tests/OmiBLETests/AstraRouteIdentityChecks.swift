import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

extension RetryFlowTests {
    @MainActor @Suite(.serialized) struct AstraRouteIdentityChecks {
        @Test func emptyVaultIdsCannotProveTheSameServer() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            AppServerStub.routes["/v1/status"] = [(200, #"{"ok":true,"vault_id":"","features":[]}"#)]
            await m.refreshServer()
            let result = await m.checkConnection(url: URL(string: "https://different.example")!, token: "tok")
            #expect(result.ok)
            #expect(result.sameServer == nil, "An empty identity supplies no same-server proof")
        }

        @Test func missingVaultIdentityStaysUnknown() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            await m.refreshServer()
            AppServerStub.routes["/v1/status"] = [(200, #"{"ok":true,"features":[]}"#)]
            let result = await m.checkConnection(url: URL(string: "https://legacy.example")!, token: "tok")
            #expect(result.ok && result.sameServer == nil)
        }

        @Test func retryMigrationMatchesAWholeVaultIdentityNotItsSuffix() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-route-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = RetryStore(url: root.appendingPathComponent("retry.json"))
            let old = RetryStore.serverKey(baseURL: URL(string: "https://old.example")!, vaultId: "x|v")
            let target = RetryStore.serverKey(baseURL: URL(string: "https://new.example")!, vaultId: "v")
            let entry = try store.begin(conversationId: "c", server: old)
            store.move(vaultId: "v", to: target)
            #expect(store.entry(conversationId: "c", server: old)?.requestId == entry.requestId)
            #expect(store.entry(conversationId: "c", server: target) == nil, "Different vaults do not inherit requests")
        }

        @Test func priorityMigrationMatchesAWholeVaultIdentityNotItsSuffix() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-route-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = PriorityStore(url: root.appendingPathComponent("priority.json"))
            let old = RetryStore.serverKey(baseURL: URL(string: "https://old.example")!, vaultId: "x|v")
            let target = RetryStore.serverKey(baseURL: URL(string: "https://new.example")!, vaultId: "v")
            let entry = try store.choose("c", state: "important", server: old)
            store.move(vaultId: "v", to: target)
            #expect(store.pending("c", server: old)?.requestId == entry.requestId)
            #expect(store.pending("c", server: target) == nil, "Different vaults do not inherit decisions")
        }
    }
}
