import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

extension RetryFlowTests {
    @MainActor @Suite(.serialized) struct AstraCacheProofRaceChecks {
        static let new = URL(string: "https://new.example")!
        func saveRow(_ m: AppModel) throws {
            let scope = try #require(m.cacheScope(m.engine.settings.serverConfig()))
            m.noteCache.saveRecent([ConversationSummary(id:"saved-a",status:"done",startedAt:"2026-11-22T00:00:00Z",title:"A only")],scope:scope)
        }
        @Test func emptyIdentityCannotAuthorizeKeepingOfflineNotes() async throws {
            let (m, root)=try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at:root) }
            AppServerStub.routes["/v1/status"]=[(200,#"{"ok":true,"vault_id":"","features":[]}"#)]
            await m.refreshServer();try saveRow(m)
            _ = await m.checkConnection(url:Self.new,token:"tok")
            AppServerStub.offline=true
            try m.saveServer(url:Self.new,token:"tok")
            await m.saveRefresh?.value
            #expect(m.noteCache.lastScope == nil, "Unknown identity cannot authorize a cache re-scope")
            #expect(!m.recent.contains { $0.id == "saved-a" }, "One unknown vault's notes must not be displayed as another unknown vault's")
        }
        @Test func anOlderProbeCannotUndoANewerDifferentVaultAnswer() async throws {
            let (m, root)=try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at:root) }
            await m.refreshServer();try saveRow(m)
            AppServerStub.holdNext.insert("/v1/status")
            let older=Task { await m.checkConnection(url:Self.new,token:"tok") }
            try await AppServerStub.waitUntilHeld("/v1/status")
            AppServerStub.routes["/v1/status"]=[(200,RetryFlowTests.status.replacingOccurrences(of:"vault-a",with:"vault-b"))]
            let newer=await m.checkConnection(url:Self.new,token:"tok")
            #expect(newer.sameServer == false)
            AppServerStub.routes["/v1/status"]=[(200,RetryFlowTests.status)]
            AppServerStub.release("/v1/status",offline:false)
            _ = await older.value
            AppServerStub.offline=true
            try m.saveServer(url:Self.new,token:"tok")
            await m.saveRefresh?.value
            #expect(m.noteCache.lastScope == nil, "The latest test said different vault; a late previous test cannot authorize keeping A")
            #expect(!m.recent.contains { $0.id == "saved-a" })
        }
    }
}
