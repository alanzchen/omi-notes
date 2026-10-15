import Foundation
import Testing
@testable import OmiBLE
import OmiProtocol

/// iPhone alerts for Watch recordings that stop without the wearer stopping them.
@Suite struct WatchStopAlertsTests {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    func alerts() -> WatchStopAlerts { WatchStopAlerts(defaults: UserDefaults(suiteName: "omi-stop-\(UUID().uuidString)")!) }

    func s(_ event: String, _ minute: Double, rec: String = "rec-1", id: String? = nil) -> WatchPerfSample {
        WatchPerfSample(id: id ?? "\(rec)-\(event)-\(minute)", at: ISO8601UTC.format(t0.addingTimeInterval(minute * 60)), monoS: minute * 60,
                        bootId: "b", launchId: "l", recordingId: rec, event: event, state: "recording", battery: nil,
                        batteryState: "unknown", counters: [:], gauges: [:], app: "t", os: "t", model: "t")
    }

    func scheduled(_ d: [WatchStopAlerts.Decision]) -> [WatchStopAlerts.Alert] {
        d.compactMap { if case .schedule(let a) = $0 { return a } else { return nil } }
    }

    @Test func theWearersStopNeverAlertsAndAnInterruptionWaitsForItsGrace() {
        let a = alerts()
        #expect(a.process(deviceId: "w", samples: [s("start", 0), s("periodic", 5), s("stopped", 9)], now: t0.addingTimeInterval(600)).isEmpty)
        let d = scheduled(a.process(deviceId: "w", samples: [s("start", 20, rec: "rec-2"), s("interrupted", 25, rec: "rec-2")],
                                    now: t0.addingTimeInterval(25 * 60 + 10)))
        #expect(d.count == 1 && d[0].fireAt == t0.addingTimeInterval(25 * 60 + WatchStopAlerts.grace) && d[0].title.contains("paused"))
        #expect(d[0].body.contains("Resume") && d[0].identifier == "omi.watch-stop.rec-2")
    }

    @Test func aResumeOrANewerRecordingWithdrawsItAndRepeatsNeverAlertTwice() {
        let a = alerts()
        let first = a.process(deviceId: "w", samples: [s("interrupted", 1)], now: t0.addingTimeInterval(70))
        #expect(scheduled(first).count == 1)
        #expect(a.process(deviceId: "w", samples: [s("interrupted", 1)], now: t0.addingTimeInterval(90)).isEmpty, "the same batch again")
        #expect(a.process(deviceId: "w", samples: [s("resumed", 2)], now: t0.addingTimeInterval(130)) == [.withdraw(identifier: "omi.watch-stop.rec-1")])
        // later stop of an unrelated kind, then a newer recording supersedes it
        #expect(scheduled(a.process(deviceId: "w", samples: [s("failed", 30)], now: t0.addingTimeInterval(1800))).count == 1)
        #expect(a.process(deviceId: "w", samples: [s("start", 40, rec: "rec-9")], now: t0.addingTimeInterval(2400)) == [.withdraw(identifier: "omi.watch-stop.rec-1")])
    }

    @Test func lateAndOutOfOrderSamplesTellTheTruthAboutNow() {
        let a = alerts()
        // the resume arrives before the (older) interruption: no alert
        #expect(a.process(deviceId: "w", samples: [s("resumed", 3)], now: t0.addingTimeInterval(200)).isEmpty)
        #expect(a.process(deviceId: "w", samples: [s("interrupted", 2)], now: t0.addingTimeInterval(210)).isEmpty)
        // an interruption and its resume in one late batch: no alert
        #expect(a.process(deviceId: "w", samples: [s("interrupted", 10, rec: "r2"), s("resumed", 11, rec: "r2")], now: t0.addingTimeInterval(3600)).isEmpty)
        // delayed but unresolved: alerted at once, with the time it happened
        let late = scheduled(a.process(deviceId: "w", samples: [s("interrupted", 20, rec: "r3")], now: t0.addingTimeInterval(3 * 3600)))
        #expect(late.count == 1 && late[0].fireAt == t0.addingTimeInterval(3 * 3600))
        // too old to be useful: nothing
        #expect(a.process(deviceId: "w", samples: [s("failed", 0, rec: "r4")], now: t0.addingTimeInterval(25 * 3600)).isEmpty)
        // opening the Watch app while paused is not a resume
        #expect(a.process(deviceId: "w", samples: [s("opened", 21, rec: "r3")], now: t0.addingTimeInterval(3 * 3600 + 60)).isEmpty)
        // a fresh status report that says it is recording withdraws older alerts
        #expect(a.recording(asOf: t0.addingTimeInterval(3 * 3600 + 120)) == [.withdraw(identifier: "omi.watch-stop.r3")])
    }

    @Test func aRecordingReportThatArrivedFirstStopsAnOlderInterruptionFromAlerting() {
        // the Watch said "recording" at T2; the interruption from T1 (before T2) arrives later, at T3
        let defaults = UserDefaults(suiteName: "omi-stop-\(UUID().uuidString)")!
        let t1 = 10.0, t2 = t0.addingTimeInterval(12 * 60), t3 = t0.addingTimeInterval(15 * 60)
        let a = WatchStopAlerts(defaults: defaults)
        #expect(a.recording(asOf: t2).isEmpty)
        #expect(a.process(deviceId: "w", samples: [s("interrupted", t1)], now: t3).isEmpty, "known to be recording again since")
        // the same after a relaunch (the report's time is remembered)
        #expect(WatchStopAlerts(defaults: defaults).process(deviceId: "w", samples: [s("interrupted", t1, rec: "r2")], now: t3).isEmpty)
        // an interruption after that report still alerts
        #expect(scheduled(WatchStopAlerts(defaults: defaults).process(deviceId: "w", samples: [s("interrupted", 13, rec: "r3")], now: t3)).count == 1)
        // a report from another Watch says nothing about this one
        let b = alerts()
        _ = b.recording(asOf: t2, deviceId: "other-watch")
        #expect(scheduled(b.process(deviceId: "w", samples: [s("interrupted", t1)], now: t3)).count == 1)
        _ = b.recording(asOf: t2, deviceId: "w")
        #expect(b.process(deviceId: "w", samples: [s("interrupted", t1, rec: "r4")], now: t3).isEmpty)
    }

    @Test func aClosedAppAlertsOnceAcrossARelaunch() {
        let defaults = UserDefaults(suiteName: "omi-stop-\(UUID().uuidString)")!
        let rec = s("recovered", 50)
        let d = scheduled(WatchStopAlerts(defaults: defaults).process(deviceId: "w", samples: [rec], now: t0.addingTimeInterval(3001)))
        #expect(d.count == 1 && d[0].title.contains("stopped") && d[0].fireAt == t0.addingTimeInterval(3001) && d[0].body.contains("kept"))
        #expect(WatchStopAlerts(defaults: defaults).process(deviceId: "w", samples: [rec], now: t0.addingTimeInterval(3100)).isEmpty,
                "the phone relaunched and got the batch again")
    }
}
