// Astra's IT3 disk-presentation checks (omi-notes-reviews/nightly-2026-11-21-it3/swift/AstraNovember21R3Checks.swift),
// adopted: the healthy-status check passes the status time; the malformed-decode check is inverted (fixed by d4357e7).
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

@Suite struct AstraNovember21R3DiskPresentationChecks {
    @Test func newerHealthyStatusCanClearAnOldDiskError() throws {
        var s = ServerDiskFullTests().snapshot(lastStatus: 507)
        s.upload.lastResult = UploadResultSummary(name: "c", status: 507, message: "storage_full", date: Date().addingTimeInterval(-3600), success: false)
        let healthy = try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"ok":true,"disk":{"full":false}}"#.utf8))
        #expect(!SystemHealth.serverDiskFull(s, status: healthy, statusAt: Date(), now: Date()), "a newer explicit false overrides an older 507")
    }
    @Test func oldDiskStatusIsNotCurrentAfterAnHour() throws {
        let now = Date()
        let s = ServerDiskFullTests().snapshot(lastStatus: nil)
        let down = try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"ok":true,"disk":{"full":true,"since":"2026-11-21T00:00:00Z"}}"#.utf8))
        let h = SystemHealth.evaluate(snapshot: s, server: .reachable(version: "t", detail: ""), status: down,
                statusAt: now.addingTimeInterval(-3600), now: now)
        #expect(!h.steps.contains { $0.area == .phone && $0.title == "Server disk is full" }, "only old disk evidence exists; say last-known or unknown")
    }
    @Test func malformedOptionalDiskTimestampDoesNotBreakTheStatusDecode() throws {  // (inverted: fixed by d4357e7)
        let bytes = Data(#"{"ok":true,"disk":{"full":true,"since":{"bad":"type"}}}"#.utf8)
        #expect(try JSONDecoder().decode(ServerStatus.self, from: bytes).ok == true)
    }
}
