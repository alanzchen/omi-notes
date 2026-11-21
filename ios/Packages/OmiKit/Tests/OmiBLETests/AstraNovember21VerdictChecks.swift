// Astra's IT1 check (omi-notes-reviews/nightly-2026-11-21-it1/swift/AstraNovember21VerdictChecks.swift), adopted unchanged.
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture

extension RetryFlowTests {
@MainActor @Suite(.serialized) struct AstraNovember21VerdictChecks {
    @Test func olderFailureMustNotOverwriteNewerSuccess() async throws {
        let (m, root) = try RetryFlowTests().model()
        defer { try? FileManager.default.removeItem(at: root) }
        await m.refreshServer()
        AppServerStub.holdNext.insert("/v1/status")
        let older = Task { await m.refreshServer() }
        try await AppServerStub.waitUntilHeld("/v1/status")
        await m.refreshServer()
        guard case .reachable = m.server else { Issue.record("new answer wasn't reachable"); return }
        AppServerStub.release("/v1/status", offline: true)
        await older.value
        if case .reachable = m.server {} else { Issue.record("older failure overwrote newer success: \(m.server)") }
    }
    @Test func diskFullBackoffIsNotPresentedAsUploading() {
        var snapshot=EngineSnapshot()
        snapshot.ready=true; snapshot.serverConfigured=true
        snapshot.outbox.pendingCount=1
        snapshot.upload.backingOff=1
        snapshot.upload.lastResult=UploadResultSummary(name:"synthetic",status:507,message:"storage_full: server disk is nearly full",date:Date(),success:false)
        let step=SystemHealth.phone(snapshot,server:.reachable(version:"test",detail:""))
        print("DISK_FULL_PHONE_STEP",step.title,step.level)
        #expect(step.level >= .delayed && step.title != "Uploading audio")
    }
}
}
