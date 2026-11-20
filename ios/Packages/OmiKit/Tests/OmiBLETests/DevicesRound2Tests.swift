import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiWatchKit

/// Nightly 2026-11-20 R2 (Devices): a problem said once on the pendant card; Transfers says when the Watch's
/// transfer stopped instead of a blank card and a bar that reads as nearly done.
@Suite struct DevicesRound2Tests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    /// A1: "This pendant can't be used" was both the state line and the issue row under it.
    @Test func aPendantProblemIsSaidOnceOnTheCard() throws {
        for name in ["refused", "codec", "pairingLost", "storage", "btOff"] {
            let s = try #require(PendantSummary.debugFixture(name, now: now), "fixture \(name)")
            let issue = try #require(s.rows.first { $0.attention }, "an issue row for \(name)")
            #expect(s.cardState == "Not connected", "\(name): \(s.cardState)")
            #expect(issue.title != s.cardState)
        }
        // no issue of its own: the state line as before
        #expect(PendantSummary.debugFixture("normal", now: now)?.cardState == "Recording")
        #expect(PendantSummary.debugFixture("disconnected", now: now)?.cardState == "Not connected")
    }

    /// B2/B3: Alan's case (three Watch parts in stalled transfers, the iPhone has sent everything): the Transfers card
    /// had no line at all and the Watch bar said "还剩 2 分钟录音" over a nearly full bar, forever.
    @Test func aStalledWatchTransferIsOneProblemLine() throws {
        let t = try #require(TransferSummary.debugFixture("watch-stalled", now: now))
        #expect(t.problemLine(now: now) == "手表传输已停止")
        #expect(t.cardLine(now: now)?.attention == true)
        #expect(t.watchLine(now: now) == "还剩 2 分钟录音 · 未在发送")
        #expect(!t.everythingSent)
        // a moving Watch transfer: no problem, the usual line
        let moving = try #require(TransferSummary.debugFixture("waiting", now: now))
        #expect(moving.watchLine(now: now) == "还剩 4 分钟录音" || !moving.watchLine(now: now).contains("未在发送"))
    }

    /// The stall comes from the Watch's own report through the same rule as the Devices card.
    @Test func theSnapshotsStalledReportReachesTransfers() {
        var s = EngineSnapshot()
        s.serverConfigured = true
        s.watchReport = WatchReport(state: .idle, since: nil, waitingParts: 3, waitingSeconds: 140, at: now.addingTimeInterval(-60),
                                    stats: ["orphan_parts": 0, "outstanding_stalled": 3])
        s.watchLastReceivedAt = now.addingTimeInterval(-11 * 86400)
        let t = TransferSummary.evaluate(snapshot: s, server: .reachable(version: "t", detail: ""), status: nil, statusAt: nil,
                                         watchInstalled: true, nowMono: 0, now: now)
        #expect(t.watch.stalled)
        #expect(t.problemLine(now: now)?.contains("手表传输已停止") == true)
    }
}
