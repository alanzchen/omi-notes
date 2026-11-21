import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

/// ASTRA-20261121-IT1-05: a reachable server answering uploads with 507 (its disk full) showed "Uploading audio" on Home
/// and a generic "上传失败，稍后重试" on Transfers.
@Suite struct ServerDiskFullTests {
    func snapshot(lastStatus: Int?) -> EngineSnapshot {
        var s = EngineSnapshot()
        s.ready = true
        s.serverConfigured = true
        s.outbox.pendingCount = 2
        s.upload.backingOff = 2
        if let lastStatus {
            s.upload.lastResult = UploadResultSummary(name: "c", status: lastStatus, message: "storage_full", date: Date(), success: false)
        }
        return s
    }

    @Test func homeSaysTheServerDiskIsFullNotUploading() {
        let step = SystemHealth.phone(snapshot(lastStatus: 507), server: .reachable(version: "t", detail: ""))
        #expect(step.title == "Server disk is full" && step.level == .delayed)
        #expect(step.detail == "2 files wait on this phone")
        // a 500 is not a full disk
        #expect(SystemHealth.phone(snapshot(lastStatus: 500), server: .reachable(version: "t", detail: "")).title == "Uploading audio")
    }

    @Test func theStatusDiskFieldSaysItBeforeAnUploadFails() throws {
        let status = try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"ok":true,"disk":{"full":true,"since":"2026-11-21T00:00:00Z"}}"#.utf8))
        #expect(SystemHealth.phone(snapshot(lastStatus: nil), server: .reachable(version: "t", detail: ""), status: status).title == "Server disk is full")
        // an older server (no field) and a null field change nothing
        let old = try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"ok":true,"disk":null}"#.utf8))
        #expect(SystemHealth.phone(snapshot(lastStatus: nil), server: .reachable(version: "t", detail: ""), status: old).title == "Uploading audio")
    }

    @Test func transfersSaysTheServerDiskIsFull() throws {
        var t = try #require(TransferSummary.debugFixture("retrying", now: Date()))
        t.phone.serverFull = true
        #expect(t.problemLine(now: Date()) == "服务器磁盘已满")
    }
}
