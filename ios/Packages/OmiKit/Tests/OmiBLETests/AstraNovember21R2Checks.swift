// Astra's IT2 checks (omi-notes-reviews/nightly-2026-11-21-it2/swift/AstraNovember21R2Checks.swift), adopted. Adapted to
// the fix: the Watch line now takes the Transfers upload state (not the reachability), and the issues check asks the
// issues-specific predicate (the rows stay, marked last-known).
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

extension RetryFlowTests {
    @MainActor @Suite(.serialized) struct AstraNovember21R2CurrencyChecks {
        @Test func futureAnswerIsNotCurrent() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            await m.refreshServer()
            let at = try #require(m.serverStatusAt)
            #expect(!m.serverAnswerIsCurrent(now: at.addingTimeInterval(-3600)), "phone clock rolls back one hour: a future answer is not current")
        }
        @Test func currencyBoundaryAndRecoveryControls() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(!m.serverAnswerIsCurrent())
            await m.refreshServer()
            let at = try #require(m.serverStatusAt)
            #expect(m.serverAnswerIsCurrent(now: at))
            #expect(m.serverAnswerIsCurrent(now: at.addingTimeInterval(300)))
            #expect(!m.serverAnswerIsCurrent(now: at.addingTimeInterval(301)))
            AppServerStub.offline = true
            await m.refreshServer()
            #expect(!m.serverAnswerIsCurrent(now: at))
            AppServerStub.offline = false
            await m.refreshServer()
            #expect(m.serverAnswerIsCurrent())
        }
        @Test func freshStatusMustNotRenewAnUnansweredIssuesList() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            AppServerStub.routes["/v1/issues"] = [(200, #"{"issues":[{"code":"worker_absent","severity":"action","message":"The processing worker is not running"}]}"#)]
            await m.refreshServer()
            #expect(m.issues.count == 1)
            AppServerStub.offline = true
            await m.refreshServer()
            #expect(!m.serverAnswerIsCurrent())
            AppServerStub.offline = false
            AppServerStub.routes["/v1/issues"] = [(503, #"{"error":"unavailable"}"#)]
            await m.refreshServer()
            // ServerView applies this predicate to the retained issues list's opacity.
            #expect(m.issues.count == 1 && !m.issuesAreCurrent(), "a new status answer must not make retained, unrefreshed issues current")
            #expect(m.serverAnswerIsCurrent(), "the status answer itself is current")
        }
    }
}

@Suite struct AstraNovember21R2PresentationChecks {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func watchDoesNotCallMovingUploadsUnreachable() {
        let helper = TransferSummaryTests()
        var snapshot = helper.snapshot(pending: 3, bytesAt: 5_000_000_000)
        snapshot.watchWaitingUpload = 3
        let server = ServerReachability.unreachable("old status failure")
        let transfers = helper.state(snapshot, server, at: 5_000_000_000)
        #expect(transfers == .sending)
        let line = WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 0, inventoryReadable: true,
            lastUploadedAt: nil, received: 3, now: now, upload: transfers)
        #expect(!line.contains("can't reach"), "Transfers has current moved bytes while the Watch row trusts the old status error")
    }
    @Test func unknownAndCheckingFallthroughDocumented() {
        for upload in [TransferSummary.UploadState.unknown, .waiting] {
            let line = WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 0, inventoryReadable: true,
                lastUploadedAt: nil, received: 3, now: now, upload: upload)
            #expect(line == "Watch audio waiting to upload")
        }
    }
    @Test func oldActivityStateDecodesButRetainsItsRawDetail() throws {
        let old = SyncActivityState(stage: .offline, title: "Can't reach your server", detail: "The request timed out.", queuedFiles: 3, asOf: now)
        let decoded = try JSONDecoder().decode(SyncActivityState.self, from: JSONEncoder().encode(old))
        #expect(decoded == old)
        #expect(decoded.detail == "The request timed out.", "compatibility control: unchanged decoder does not sanitize already-persisted cards")
    }
    @Test func namedAlertConditionsAndOrdinaryOutageControl() {
        var s = EngineSnapshot()
        s.storageTripped = true
        s.outbox.quarantineCount = 1
        s.upload.pausedReason = "Server rejected the token (401)"
        #expect(PhoneProblem.current(s) == [.recordingStopped, .audioKept, .uploadsPaused])
        s.storageTripped = false; s.outbox.quarantineCount = 0; s.upload.pausedReason = nil
        s.outbox.pendingCount = 3; s.upload.backingOff = 3
        #expect(PhoneProblem.current(s).isEmpty)
    }
}
