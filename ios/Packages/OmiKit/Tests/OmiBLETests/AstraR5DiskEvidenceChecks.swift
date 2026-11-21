// Astra's IT5 check (omi-notes-reviews/nightly-2026-11-21-it5/swift/AstraR5DiskEvidenceChecks.swift), adopted unchanged.
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

@Suite struct AstraR5DiskEvidenceChecks {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func snapshot(refusedAt: Date?) -> EngineSnapshot {
        var s = EngineSnapshot()
        s.ready = true
        s.serverConfigured = true
        s.outbox.pendingCount = 3
        if let refusedAt {
            s.upload.lastResult = UploadResultSummary(name: "test-chunk", status: 507,
                message: "storage_full", date: refusedAt, success: false)
        }
        return s
    }
    func status(_ full: Bool) throws -> ServerStatus {
        try JSONDecoder().decode(ServerStatus.self, from: Data("{\"ok\":true,\"disk\":{\"full\":\(full)}}".utf8))
    }
    @Test func oldUploadRefusalCannotProveCurrentDiskFull() {
        let s = snapshot(refusedAt: now.addingTimeInterval(-3600))
        #expect(!SystemHealth.serverDiskFull(s, status: nil, statusAt: nil, now: now),
            "a one-hour-old 507 is last known, not evidence the disk is full now")
    }
    @Test func futureUploadRefusalCannotProveCurrentDiskFull() {
        let s = snapshot(refusedAt: now.addingTimeInterval(3600))
        #expect(!SystemHealth.serverDiskFull(s, status: nil, statusAt: nil, now: now),
            "phone clock rollback must not make a future-dated 507 authoritative")
    }
    @Test func untimedStatusCannotProveCurrentDiskFull() throws {
        #expect(!SystemHealth.serverDiskFull(snapshot(refusedAt: nil), status: try status(true), statusAt: nil, now: now),
            "missing answer time is unknown under the shared freshness rule")
    }
    @Test func aFuture507CannotDefeatNewerHealthyEvidenceByClockAccident() throws {
        let s = snapshot(refusedAt: now.addingTimeInterval(3600))
        #expect(!SystemHealth.serverDiskFull(s, status: try status(false), statusAt: now, now: now),
            "valid not-full answer must not lose to invalid future evidence")
    }
    @Test func currentEvidenceAndOrderingControls() throws {
        let s = snapshot(refusedAt: now.addingTimeInterval(-10))
        #expect(SystemHealth.serverDiskFull(s, status: nil, statusAt: nil, now: now))
        #expect(!SystemHealth.serverDiskFull(s, status: try status(false), statusAt: now, now: now))
        #expect(SystemHealth.serverDiskFull(s, status: try status(false), statusAt: now.addingTimeInterval(-20), now: now))
        #expect(SystemHealth.serverDiskFull(snapshot(refusedAt: nil), status: try status(true), statusAt: now, now: now))
        #expect(!SystemHealth.serverDiskFull(snapshot(refusedAt: nil), status: try status(true), statusAt: now.addingTimeInterval(-301), now: now))
    }
    @Test func allMalformedDiskShapesStillDecode() throws {
        for shape in ["null", "false", "1", "[]", "\"bad\"", "{\"full\":[],\"since\":{}}"] {
            let value = try JSONDecoder().decode(ServerStatus.self, from: Data("{\"ok\":true,\"disk\":\(shape)}".utf8))
            #expect(value.ok == true)
            #expect(value.disk?.full == nil)
        }
    }
}
