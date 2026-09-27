import Foundation
import Testing
@testable import OmiBLE

final class RecordingSink: ProblemAlertSink, @unchecked Sendable {
    var posted: [PhoneProblem] = []
    var withdrawn: [PhoneProblem] = []
    func post(_ problem: PhoneProblem) { posted.append(problem) }
    func withdraw(_ problem: PhoneProblem) { withdrawn.append(problem) }
}

@Suite struct ProblemAlertsTests {
    func alerts() -> (ProblemAlerts, RecordingSink, UserDefaults) {
        let d = UserDefaults(suiteName: "alerts-\(UUID().uuidString)")!
        let a = ProblemAlerts(defaults: d)
        let sink = RecordingSink()
        a.sink = sink
        return (a, sink, d)
    }

    @Test func onlyOncePerConditionAndWithdrawnWhenItClears() {
        let (a, sink, _) = alerts()
        a.enabled = true
        var s = EngineSnapshot()
        s.storageTripped = true
        a.update(s)
        a.update(s)
        #expect(sink.posted == [.recordingStopped])
        s.storageTripped = false
        a.update(s)
        #expect(sink.withdrawn == [.recordingStopped])
    }

    @Test func ordinaryWaitingNeverAlertsAndNothingWhenOff() {
        let (a, sink, _) = alerts()
        var s = EngineSnapshot()
        s.connection = .waitingForDevice
        s.outbox.pendingCount = 40
        a.enabled = true
        a.update(s)
        #expect(sink.posted.isEmpty)
        a.enabled = false
        s.upload.pausedReason = "Server rejected the token (401)"
        a.update(s)
        #expect(sink.posted.isEmpty)
    }

    @Test func aRelaunchDoesNotRepeatAnAlert() {
        let (a, sink, d) = alerts()
        a.enabled = true
        var s = EngineSnapshot()
        s.outbox.quarantineCount = 2
        a.update(s)
        let again = ProblemAlerts(defaults: d)
        let sink2 = RecordingSink()
        again.sink = sink2
        again.update(s)
        #expect(sink.posted == [.audioKept] && sink2.posted.isEmpty)
    }
}
