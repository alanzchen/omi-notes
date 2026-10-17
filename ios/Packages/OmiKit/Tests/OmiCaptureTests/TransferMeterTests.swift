import Foundation
import Testing
@testable import OmiCapture

/// The live phone → server numbers must come from real progress callbacks and never inflate:
/// no negative or stale rates, retries are network bytes but not delivered audio, a completion counts
/// once, and bytes from before the window started are not counted.
@Suite struct TransferMeterTests {
    let s: UInt64 = 1_000_000_000
    func meter() -> TransferMeter { var m = TransferMeter(); m.start(atMono: 0, wall: Date(timeIntervalSince1970: 1_800_000_000)); return m }

    @Test func theRateIsBytesActuallyReportedOverTheRecentWindow() {
        var m = meter()
        m.progress(id: "a", audio: true, sent: 100_000, expected: 2_000_000, atMono: 1 * s)  // first report: the baseline
        m.progress(id: "a", audio: true, sent: 600_000, expected: 2_000_000, atMono: 2 * s)
        m.progress(id: "a", audio: true, sent: 1_100_000, expected: 2_000_000, atMono: 3 * s)
        #expect(m.networkBytes == 1_000_000, "counted from the first report: nothing before it is claimed")
        let r = m.rate(atMono: 3 * s)
        #expect(r != nil && abs(r! - 1_000_000.0 / 3) < 1, "\(String(describing: r))")
        #expect(m.since == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func aRestartedAttemptIsNeverNegative() {
        var m = meter()
        m.progress(id: "a", audio: true, sent: 0, expected: 1_000_000, atMono: 1 * s)
        m.progress(id: "a", audio: true, sent: 800_000, expected: 1_000_000, atMono: 2 * s)
        m.progress(id: "a", audio: true, sent: 50_000, expected: 1_000_000, atMono: 3 * s)  // retried from the start
        #expect(m.networkBytes == 800_000)
        m.progress(id: "a", audio: true, sent: 250_000, expected: 1_000_000, atMono: 4 * s)
        #expect(m.networkBytes == 1_000_000, "the retry's own bytes count as network bytes")
        #expect((m.rate(atMono: 4 * s) ?? -1) >= 0)
    }

    @Test func noRecentBytesMeansNoRateNotAStaleOne() {
        var m = meter()
        m.progress(id: "a", audio: true, sent: 0, expected: nil, atMono: 1 * s)
        m.progress(id: "a", audio: true, sent: 500_000, expected: nil, atMono: 2 * s)
        #expect(m.rate(atMono: 2 * s) != nil)
        #expect(m.rate(atMono: 6 * s) == nil, "idle: no rate shown after bytes stop")
    }

    @Test func aCompletionCountsOnceAndFailuresAreNotDelivered() {
        var m = meter()
        m.progress(id: "a", audio: true, sent: 0, expected: 900, atMono: 1 * s)
        m.progress(id: "a", audio: true, sent: 900, expected: 900, atMono: 2 * s)
        m.finished(id: "a", audio: true, bytes: 900, outcome: .retrying, atMono: 2 * s)
        #expect(m.deliveredAudioFiles == 0 && m.retryingAttempts == 1)
        m.progress(id: "a", audio: true, sent: 0, expected: 900, atMono: 3 * s)
        m.progress(id: "a", audio: true, sent: 900, expected: 900, atMono: 4 * s)
        m.finished(id: "a", audio: true, bytes: 900, outcome: .delivered, atMono: 4 * s)
        m.finished(id: "a", audio: true, bytes: 900, outcome: .delivered, atMono: 4 * s)  // delivered twice
        #expect(m.deliveredAudioFiles == 1 && m.deliveredAudioBytes == 900)
        #expect(m.networkBytes == 1_800_000 / 1_000, "both attempts went over the network")
        m.finished(id: "e", audio: false, bytes: 200, outcome: .delivered, atMono: 4 * s)
        #expect(m.deliveredOtherFiles == 1 && m.deliveredAudioFiles == 1, "metadata isn't audio")
    }

    @Test func theWindowStartsFreshAndATaskAlreadyRunningOnlyCountsWhatFollows() {
        var m = meter()
        m.progress(id: "a", audio: true, sent: 0, expected: 2_000_000, atMono: 1 * s)
        m.progress(id: "a", audio: true, sent: 1_000_000, expected: 2_000_000, atMono: 2 * s)
        m.finished(id: "b", audio: true, bytes: 10, outcome: .delivered, atMono: 2 * s)
        m.suspend()
        #expect(m.since == nil && m.rate(atMono: 2 * s) == nil, "in the background nothing is live")
        m.start(atMono: 100 * s, wall: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(m.networkBytes == 0 && m.deliveredAudioFiles == 0, "counters are for this window")
        m.progress(id: "a", audio: true, sent: 1_500_000, expected: 2_000_000, atMono: 101 * s)
        #expect(m.networkBytes == 0, "UX-LT-ASTRA-03: what it sent while suspended has no foreground baseline")
        m.progress(id: "a", audio: true, sent: 1_800_000, expected: 2_000_000, atMono: 102 * s)
        #expect(m.networkBytes == 300_000, "only what followed its first report in this window")
    }

    // UX-LT-ASTRA-03/04: Astra's schedules (astra-review/AcceptanceHarness.swift).

    @Test func aNewUploadsFirstReportCountsInFull() {
        var m = meter()
        m.began(id: "1.1|new", audio: true, expected: 600)  // the uploader started it in this window
        m.progress(id: "1.1|new", audio: true, sent: 600, expected: 600, atMono: 1 * s)  // a single report
        #expect(m.networkBytes == 600)
        m.finished(id: "1.1|new", audio: true, bytes: 600, outcome: .delivered, atMono: 2 * s)
        #expect(m.deliveredAudioFiles == 1)
    }

    @Test func bytesSentWhileSuspendedAreNotCountedAfterResuming() {
        var m = meter()
        m.began(id: "1.1|a", audio: true, expected: 1_000)
        m.progress(id: "1.1|a", audio: true, sent: 100, expected: 1_000, atMono: 1 * s)
        m.suspend()
        m.start(atMono: 10 * s, wall: Date(timeIntervalSince1970: 10))
        m.progress(id: "1.1|a", audio: true, sent: 800, expected: 1_000, atMono: 11 * s)  // 700 of it went in the background
        #expect(m.networkBytes == 0, "no foreground baseline for those bytes")
        m.progress(id: "1.1|a", audio: true, sent: 900, expected: 1_000, atMono: 12 * s)
        #expect(m.networkBytes == 100)
    }

    @Test func anAdoptedUploadCountsOnlyWhatFollowsItsFirstReport() {
        var m = meter()
        m.progress(id: "1.1|old", audio: true, sent: 400, expected: 1_000, atMono: 1 * s)  // never began in this window
        m.progress(id: "1.1|old", audio: true, sent: 700, expected: 1_000, atMono: 2 * s)
        #expect(m.networkBytes == 300)
    }

    @Test func uploadsOfAnotherServerOrEpochAreRetired() {
        var m = meter()
        m.began(id: "0.1|x", audio: true, expected: 1_000)
        m.progress(id: "0.1|x", audio: true, sent: 600, expected: 1_000, atMono: 1 * s)
        m.retain(key: "1.1")
        #expect(m.inFlight.uploads == 0, "no phantom upload left by an obsolete key")
    }

    @Test func percentUsesOnlyUploadsWithAKnownTotal() {
        var m = meter()
        m.progress(id: "a", audio: true, sent: 0, expected: 1_000, atMono: 1 * s)
        m.progress(id: "a", audio: true, sent: 400, expected: 1_000, atMono: 2 * s)
        m.progress(id: "b", audio: false, sent: 0, expected: nil, atMono: 2 * s)
        let f = m.inFlight
        #expect(f.sent == 400 && f.total == 1_000 && f.uploads == 2 && f.unknownTotals == 1)
        m.finished(id: "a", audio: true, bytes: 1_000, outcome: .delivered, atMono: 3 * s)
        #expect(m.inFlight.uploads == 1 && m.inFlight.total == 0)
    }
}
