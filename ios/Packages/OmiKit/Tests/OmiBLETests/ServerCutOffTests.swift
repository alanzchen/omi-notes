// 2026-11-28 R1 (ux-lane F1, F3, F4): Alan's phone was cut off from a moved server for 9 days while Home said only
// "Audio is waiting to upload · Stored safely on this phone. [Retry now]".
import Foundation
import Testing
@testable import OmiBLE
import OmiProtocol

@Suite struct ServerCutOffTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func waiting() -> EngineSnapshot {
        var s = EngineSnapshot()
        s.ready = true; s.serverConfigured = true
        s.connection = .noDevice; s.watchLastReceivedAt = now  // a device that records, so the pendant step is calm
        s.outbox.pendingCount = 21
        return s
    }

    @Test func anUnreachableServerLeadsTheCardWithOneWayToChangeIt() throws {
        let health = SystemHealth.evaluate(snapshot: waiting(), server: .unreachable("Could not connect to the server."),
                                           status: nil, statusAt: nil, now: now)
        #expect(health.headline == "Can't reach your server", "why audio waits, not that it waits")
        let server = try #require(health.steps.first { $0.area == .server })
        #expect(server.fix == .changeServer)
        #expect(server.detail == "Recordings wait on this phone.", "no guessed cause: \(server.detail ?? "")")
        #expect(SystemHealth.Fix.changeServer != .openServer)
    }

    @Test func anotherDelayedPhoneProblemStillLeadsWhenTheServerAnswers() {
        // the server lead applies only when the server is why audio waits
        var s = waiting(); s.attention = ["Something on this phone"]; s.outbox.pendingCount = 0
        let health = SystemHealth.evaluate(snapshot: s, server: .reachable(version: "t", detail: ""), status: nil, statusAt: nil, now: now)
        #expect(health.headline != "Can't reach your server")
    }
}
