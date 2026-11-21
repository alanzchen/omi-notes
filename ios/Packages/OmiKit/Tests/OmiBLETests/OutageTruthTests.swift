import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
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

    /// R4 residual: a card started by build 61 stored the raw text; it is not drawn.
    @Test func anOldCardsRawDetailIsNotShown() {
        let old = SyncActivityState(stage: .offline, title: "Can't reach your server", detail: "The request timed out.", queuedFiles: 3, asOf: now)
        #expect(old.displayDetail == nil)
        let refused = SyncActivityState(stage: .offline, title: "Can't reach your server", detail: TransferSummary.rejectedReason, queuedFiles: 3, asOf: now)
        #expect(refused.displayDetail == TransferSummary.rejectedReason)
        let paused = SyncActivityState(stage: .paused, title: "Uploads paused", detail: "Server rejected the token (401)", queuedFiles: 3, asOf: now)
        #expect(paused.displayDetail == "Server rejected the token (401)")
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
                                                  received: 10, now: now, upload: .offline("x"))
        #expect(unreachable == "Waiting: can't reach your server")
        let rejected = WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 1, inventoryReadable: true, lastUploadedAt: nil,
                                               received: 10, now: now, upload: .offline(TransferSummary.rejectedReason))
        #expect(rejected == "Waiting: the server rejected this iPhone · 1 part set aside")
        let fine = WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 0, inventoryReadable: true, lastUploadedAt: nil,
                                           received: 10, now: now, upload: .waiting)
        #expect(fine == "Watch audio waiting to upload")
        // R4 (ASTRA-20261121-IT2-03): the server's full disk, and bytes actually moving, as Transfers says them
        #expect(WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 0, inventoryReadable: true, lastUploadedAt: nil,
                                        received: 10, now: now, upload: .retrying, serverFull: true) == "Waiting: server disk is full")
        #expect(WatchSummary.uploadLine(waiting: 3, othersWaiting: 0, setAside: 0, inventoryReadable: true, lastUploadedAt: nil,
                                        received: 10, now: now, upload: .sending) == "Watch audio uploading")
    }

    /// R4: the Pendant page's phone row said "N files uploading" while the server refused them for lack of disk.
    @Test func thePendantRowSaysTheServerDiskIsFull() throws {
        var s = EngineSnapshot()
        s.ready = true
        s.serverConfigured = true
        s.rememberedDeviceId = "x"
        s.outbox.pendingCount = 2
        s.upload.lastResult = UploadResultSummary(name: "c", status: 507, message: "storage_full", date: now, success: false)
        let p = PendantSummary.evaluate(snapshot: s, server: .reachable(version: "t", detail: ""), status: nil, statusAt: nil, now: now)
        let row = try #require(p.rows.first { $0.kind == .phone })
        #expect(row.title == "2 files waiting on iPhone" && row.detail == "Server disk is full" && row.attention)
    }
}
