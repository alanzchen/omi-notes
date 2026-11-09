import Foundation
import Testing
@testable import OmiWatchKit

/// WatchConnectivity kills a Watch app that uses 2 s of CPU in a background wake (builds 38 and 42 were, in
/// `WatchOutbox.segments()` from the send loop). In the background, sending stops after `cpuSeconds`.
@Suite struct WatchBackgroundBudgetTests {
    @Test func aBackgroundLaunchCountsFromProcessStartAndStopsAtTheBudget() {
        var b = WatchBackgroundBudget()
        let r1 = b.mayWork(active: false, cpu: 0.3)
        #expect(r1)
        let r2 = b.mayWork(active: false, cpu: WatchBackgroundBudget.cpuSeconds + 0.01)
        #expect(!r2, "launch and cold load count too")
    }

    @Test func theForegroundIsUnlimitedAndEachBackgroundPeriodGetsItsOwnBudget() {
        var b = WatchBackgroundBudget()
        let r3 = b.mayWork(active: true, cpu: 30)
        #expect(r3)
        let r4 = b.mayWork(active: false, cpu: 30.5)
        #expect(r4, "counted from the first background look after the foreground")
        let r5 = b.mayWork(active: false, cpu: 30.5 + WatchBackgroundBudget.cpuSeconds + 0.01)
        #expect(!r5)
        let r6 = b.mayWork(active: true, cpu: 40)
        #expect(r6)
        let r7 = b.mayWork(active: false, cpu: 40.2)
        #expect(r7)
    }

    @Test func theProcessClockMoves() {
        let a = WatchBackgroundBudget.processCPUSeconds()
        var x = 0.0
        for i in 0..<2_000_000 { x += Double(i % 7) }
        #expect(WatchBackgroundBudget.processCPUSeconds() > a && x > 0)
    }
}
