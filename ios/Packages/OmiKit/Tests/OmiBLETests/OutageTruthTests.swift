import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol
import OmiWatchKit

/// Nightly 2026-11-21 R2: during a long server outage nothing may read as current or calm.
@Suite struct OutageTruthTests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    /// The Live Activity showed the raw transport text ("The request timed out.") under "Can't reach your server".
    @Test func theLiveActivityShowsNoRawErrorText() throws {
        var t = try #require(TransferSummary.debugFixture("offline", now: now))
        t.phone.state = .offline("The request timed out.")
        let s = SyncActivityState(t, now: now)
        #expect(s.title == "Can't reach your server")
        #expect(s.detail == nil, "\(s.detail ?? "")")
        // the server's refusal is the app's own sentence, not a transport error: it stays
        t.phone.state = .offline(TransferSummary.rejectedReason)
        #expect(SyncActivityState(t, now: now).detail == TransferSummary.rejectedReason)
    }

    /// The Pendant page said "Server unreachable right now" after 38 hours.
    @Test func thePendantRowSaysSinceTheLastUploadNotRightNow() throws {
        let s = try #require(PendantSummary.debugFixture("blocked", now: now))  // unreachable, last upload 88 min ago
        let row = try #require(s.rows.first { $0.kind == .phone })
        #expect(row.detail?.contains("right now") == false, "\(row.detail ?? "")")
        #expect(row.detail?.hasPrefix("Server unreachable · last upload") == true, "\(row.detail ?? "")")
    }

    /// The Watch page's "Upload to your server" read as a calm queue while nothing could reach the server.
    @Test func theWatchUploadLineSaysWhyItWaits() {
        let unreachable = WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 0, inventoryReadable: true, lastUploadedAt: nil,
                                                  received: 10, now: now, server: .unreachable("x"))
        #expect(unreachable == "Waiting: can't reach your server")
        let rejected = WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 1, inventoryReadable: true, lastUploadedAt: nil,
                                               received: 10, now: now, server: .unauthorized)
        #expect(rejected == "Waiting: the server rejected this iPhone · 1 part set aside")
        let fine = WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 0, inventoryReadable: true, lastUploadedAt: nil,
                                           received: 10, now: now, server: .reachable(version: "t", detail: ""))
        #expect(fine == "Watch audio waiting to upload")
    }
}
