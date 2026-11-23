import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

extension RetryFlowTests {
 @MainActor @Suite(.serialized) struct AstraCacheSaveProofChecks {
  static let new=URL(string:"https://new.example")!
  func prepare() async throws -> (AppModel,URL) {
   let (m,root)=try RetryFlowTests().model()
   await m.refreshServer()
   let scope=try #require(m.cacheScope(m.engine.settings.serverConfig()))
   m.noteCache.saveRecent([ConversationSummary(id:"saved-x",status:"done",title:"Vault X private note")],scope:scope)
   #expect(m.noteCache.lastScope?.vaultId == "vault-a")
   return (m,root)
  }
  @Test func aPairingLinkWithAnotherTokenCannotReuseASettingsProbe() async throws {
   let (m,root)=try await prepare()
   defer { try? FileManager.default.removeItem(at:root) }
   let check=await m.checkConnection(url:Self.new,token:"tok")
   #expect(check.sameServer == true)
   AppServerStub.offline=true
   var c=URLComponents();c.scheme="omi-notes";c.host="configure"
   c.queryItems=[URLQueryItem(name:"url",value:Self.new.absoluteString),URLQueryItem(name:"token",value:"other-vault-token")]
   #expect(m.handleOpenURL(try #require(c.url)))
   try m.confirmPendingConfigure()
   await m.saveRefresh?.value
   #expect(m.engine.settings.token == "other-vault-token")
   #expect(m.recent.isEmpty,"The new token had no same-vault proof")
   #expect(m.noteCache.lastScope == nil)
  }
  @Test func aFailedRetestInvalidatesTheOldProof() async throws {
   let (m,root)=try await prepare()
   defer { try? FileManager.default.removeItem(at:root) }
   _=await m.checkConnection(url:Self.new,token:"tok")
   AppServerStub.offline=true
   let failure=await m.checkConnection(url:Self.new,token:"tok")
   #expect(!failure.ok)
   try m.saveServer(url:Self.new,token:"tok")
   await m.saveRefresh?.value
   #expect(m.recent.isEmpty,"A failed retest no longer supplies proof")
   #expect(m.noteCache.lastScope == nil)
  }
  @Test func fullyMovedCacheIsReadableByANewModelBeforeServerAnswers() async throws {
   let (m,root)=try await prepare()
   defer { try? FileManager.default.removeItem(at:root) }
   _=await m.checkConnection(url:Self.new,token:"tok")
   AppServerStub.offline=true
   try m.saveServer(url:Self.new,token:"tok")
   await m.saveRefresh?.value
   let relaunched=AppModel(engine:m.engine,noteCache:NoteCache(root:root.appendingPathComponent("cache")))
   relaunched.session=m.session
   await relaunched.refreshServer()
   #expect(relaunched.recent.map(\.id) == ["saved-x"])
   #expect(relaunched.currentVaultId == "vault-a")
  }
 }
}
