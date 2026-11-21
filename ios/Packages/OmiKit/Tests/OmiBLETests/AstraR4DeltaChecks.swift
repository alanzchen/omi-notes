// Astra's IT4 checks (omi-notes-reviews/nightly-2026-11-21-it4/swift/AstraR4DeltaChecks.swift), adopted unchanged.
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

extension RetryFlowTests {
    @MainActor @Suite(.serialized) struct AstraR4DeltaAsyncChecks {
        @Test func oldIssuesStayLastKnownUntilTheirOwnAnswer() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            AppServerStub.routes["/v1/issues"] = [(200, #"{"issues":[{"code":"worker_absent","severity":"action","message":"The processing worker is not running"}]}"#)]
            await m.refreshServer()
            #expect(m.issues.count == 1 && m.issuesAreCurrent())
            AppServerStub.offline = true
            await m.refreshServer()
            #expect(!m.issuesAreCurrent())
            AppServerStub.offline = false
            AppServerStub.holdNext.insert("/v1/issues")
            let recovery = Task { await m.refreshServer() }
            try await AppServerStub.waitUntilHeld("/v1/issues")
            let currentWhileHeld = m.issuesAreCurrent()
            #expect(m.serverAnswerIsCurrent())
            AppServerStub.release("/v1/issues", offline: true)
            await recovery.value
            #expect(!currentWhileHeld, "fresh status cannot renew old issues before the issues request answers")
            #expect(!m.issuesAreCurrent())
            AppServerStub.routes["/v1/issues"] = [(200, #"{"issues":[]}"#)]
            await m.refreshServer()
            #expect(m.issues.isEmpty && m.issuesAreCurrent())
        }
    }
}

@Suite struct AstraR4DeltaPresentationChecks {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func sharedFreshnessBoundaries() {
        #expect(!ServiceLabel.isCurrent(age: nil))
        for age in [-60.0, 0, 300] { #expect(ServiceLabel.isCurrent(age: age)) }
        for age in [-61.0, 301, .infinity, .nan] { #expect(!ServiceLabel.isCurrent(age: age)) }
    }
    @Test func futureStatusMustNotBeHealthyOnHome() throws {
        let status = try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"ok":true,"worker":{"present":true},"stt":{"ready":true},"llm":{"ready":true},"queue":{"failed":0}}"#.utf8))
        let step = SystemHealth.server(.reachable(version: "t", detail: ""), status: status,
            statusAt: now.addingTimeInterval(3600), now: now)
        #expect(!ServiceLabel.isCurrent(age: -3600))
        #expect(step.level == .unknown, "Home must apply the same future-time bound as the Server groups")
    }
    @Test func diskFlagMustNotOverrideMovingBytesOnWatch() {
        let helper = TransferSummaryTests()
        var s = helper.snapshot(pending: 3, bytesAt: 5_000_000_000)
        s.watchWaitingUpload = 3
        s.upload.lastResult = UploadResultSummary(name: "c", status: 507, message: "storage_full", date: now, success: false)
        let p = TransferSummary.evaluate(snapshot: s, server: helper.reachable(), status: nil, statusAt: nil,
            watchInstalled: nil, nowMono: 5_000_000_000, now: now).phone
        #expect(p.state == .sending && p.serverFull)
        let line = WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 0, inventoryReadable: true,
            lastUploadedAt: nil, received: 3, now: now, upload: p.state, serverFull: p.serverFull)
        #expect(!line.hasPrefix("Waiting"), "Transfers reports moving bytes; the Watch row must not override it with an old disk flag")
    }
    @Test func diskFlagMustNotMaskRejectionOrPauseOnWatch() {
        for state in [TransferSummary.UploadState.offline(TransferSummary.rejectedReason), .paused("user paused")] {
            let line = WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 0, inventoryReadable: true,
                lastUploadedAt: nil, received: 3, now: now, upload: state, serverFull: true)
            #expect(!line.contains("disk is full"), "the selected Transfers state wins")
        }
    }
    @Test func pendantBytesDoNotProveWatchBytesAreMoving() {
        let helper = TransferSummaryTests()
        var s = helper.snapshot(pending: 10, bytesAt: nil)
        s.watchWaitingUpload = 3
        s.transfer.meter.progress(id: "pendant-only", audio: true, sent: 0, expected: 1000, atMono: 4_000_000_000)
        s.transfer.meter.progress(id: "pendant-only", audio: true, sent: 500, expected: 1000, atMono: 5_000_000_000)
        let state = helper.state(s, at: 5_000_000_000)
        #expect(state == .sending)
        let line = WatchSummary.uploadLine(waiting: 3, othersWaiting: 7, setAside: 0, inventoryReadable: true,
            lastUploadedAt: nil, received: 3, now: now, upload: state)
        #expect(line != "Watch audio uploading", "phone-wide moving bytes have no Watch-source evidence")
    }
    @Test func legacyDetailRoundTripAndFilter() throws {
        let old = SyncActivityState(stage: .offline, title: "Can't reach your server", detail: "The request timed out.", queuedFiles: 3, asOf: now)
        let decoded = try JSONDecoder().decode(SyncActivityState.self, from: JSONEncoder().encode(old))
        #expect(decoded == old && decoded.detail == "The request timed out.")
        #expect(decoded.displayDetail == nil)
        let rejected = SyncActivityState(stage: .offline, title: "Can't reach your server", detail: SyncActivityState.rejectedDetail, queuedFiles: 3, asOf: now)
        #expect(rejected.displayDetail == SyncActivityState.rejectedDetail)
    }
}
