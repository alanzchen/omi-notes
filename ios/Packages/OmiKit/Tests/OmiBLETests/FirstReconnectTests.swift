import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol

/// Nightly 2026-11-24 R2: the first minutes after reconnecting to the server with a 5-day backlog (the UX inventory,
/// build/deployment/nightly/2026-11-24/ux-lane/INVENTORY.md). Unknown never reads as fine; counts stay in Details; the
/// time left isn't displaced by something that isn't a fault; bytes flowing are not "can't reach".
@Suite struct FirstReconnectTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func backlog() -> EngineSnapshot {
        var s = EngineSnapshot()
        s.ready = true; s.serverConfigured = true
        s.outbox.pendingCount = 5_135
        return s
    }

    /// Right after Save the new server hasn't answered: Home said "Uploading audio" (working, blue) before anything
    /// was known (inventory §3e).
    @Test func audioIsNotUploadingBeforeTheServerAnswers() {
        for reach in [ServerReachability.checking, .unknown] {
            let step = SystemHealth.phone(backlog(), server: reach, now: now)
            #expect(step.title == "Audio is waiting to upload" && step.level == .unknown, "\(reach): \(step.title)")
            #expect(step.detail == nil && step.fix == nil, "nothing to do yet but wait for the answer")
        }
        #expect(SystemHealth.phone(backlog(), server: .reachable(version: "t", detail: ""), now: now).title == "Uploading audio")
    }

    /// Counts belong in Details: the collapsed Home card said "5135 files stored safely on this phone; they upload when
    /// the server is reachable." (inventory §3c), the second half restating the server step beside it.
    @Test func theOutageLineNamesNoCount() throws {
        let step = SystemHealth.phone(backlog(), server: .unreachable("timed out"), now: now)
        #expect(step.title == "Audio is waiting to upload" && step.level == .delayed && step.fix == .retryUploads)
        let detail = try #require(step.detail)
        #expect(!detail.contains(where: \.isNumber) && !detail.contains("reachable"), "\(detail)")
    }

    func fixture(_ name: String) throws -> TransferSummary { try #require(TransferSummary.debugFixture(name, now: now)) }

    /// A slow /v1/status under the upload burst set "can't reach" while acknowledged bytes were moving every few seconds
    /// (inventory §3, item 3): the upload itself is the newer proof of reach.
    @Test func bytesFlowingAreNotUnreachable() throws {
        var t = try fixture("backlog")
        t.server.reachable = false
        #expect(t.problemLine(now: now) == nil)
        #expect(t.cardLine(now: now)?.text == "约 13 小时传完")
        t.phone.state = .waiting
        #expect(t.problemLine(now: now) == "连不上服务器", "without bytes moving, the status answer decides")
    }

    /// The Watch reports only on change or while its app runs, so an idle Watch's report goes stale during a healthy
    /// upload; the card then led with orange "手表报告已过时" instead of the time left (inventory §4, item 2). The page
    /// keeps it (its Watch bar says "等待手表报告"); the one-line card shows the phone's time left.
    @Test func aStaleWatchReportDoesNotHideTheTimeLeftOnTheCard() throws {
        var t = try fixture("backlog")
        t.watch.reportFresh = false
        t.watch.reportAt = now.addingTimeInterval(-3 * 3600)
        #expect(t.problemLine(now: now) == "手表报告已过时")
        let card = try #require(t.cardLine(now: now))
        #expect(card.text == "约 13 小时传完" && !card.attention)
        t.watch.reportAt = now.addingTimeInterval(3600)
        #expect(t.cardLine(now: now)?.text == "手表时间与 iPhone 不一致", "a clock problem is a real problem")
        t.watch.reportAt = now.addingTimeInterval(-3 * 3600)
        t.phone.keptAside = 1
        #expect(t.cardLine(now: now)?.attention == true, "a phone problem still leads")
        var idle = try fixture("waiting")
        idle.watch.reportFresh = false
        idle.watch.reportAt = now.addingTimeInterval(-3 * 3600)
        #expect(idle.cardLine(now: now)?.text == "手表报告已过时", "no time left to show: the problem stays")
    }
}

extension RetryFlowTests {
    @MainActor @Suite(.serialized) struct ConnectionRefusalWordingTests {
        /// "Test connection" with a wrong token said "Couldn't connect: Token rejected (401)": the client throws
        /// `.unauthorized`, so the intended sentence was never reached.
        @Test func aRejectedTokenIsSaidPlainly() async throws {
            let (m, root) = try RetryFlowTests().model()
            defer { try? FileManager.default.removeItem(at: root) }
            AppServerStub.routes["/v1/status"] = [(401, #"{"error":"unauthorized"}"#)]
            let refused = await m.checkConnection(url: URL(string: "https://oracle.tailcd4f.ts.net:8446")!, token: "bad")
            #expect(!refused.ok && refused.message == "Couldn't connect: the server rejected this token.", "\(refused.message)")
        }
    }
}
