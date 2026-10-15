import Foundation
import Testing
@testable import OmiWatchKit

/// The watch-face complication shows only what the Watch app knows, and stops claiming it once old.
@Suite struct WatchComplicationTests {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    func snap(_ r: ComplicationSnapshot.Recorder, _ waiting: Int = 0, bound: Bool = true, at: TimeInterval = 0) -> ComplicationSnapshot {
        ComplicationSnapshot(at: t0.addingTimeInterval(at), recorder: r, waitingParts: waiting, bound: bound)
    }

    @Test func eachStateAndTheQueueAreShownAndOnlyTheIPhoneIsClaimed() {
        #expect(ComplicationDisplay.evaluate(snap(.recording, 3), now: t0) == ComplicationDisplay(main: .recording, sync: .waiting(3)))
        #expect(ComplicationDisplay.evaluate(snap(.paused), now: t0) == ComplicationDisplay(main: .paused, sync: .onIPhone))
        #expect(ComplicationDisplay.evaluate(snap(.failed), now: t0).main == .error)
        #expect(ComplicationDisplay.evaluate(snap(.idle, 2), now: t0) == ComplicationDisplay(main: .idle, sync: .waiting(2)))
        #expect(ComplicationDisplay.evaluate(snap(.idle, 5, bound: false), now: t0).sync == .notConnected)
        let label = ComplicationDisplay.evaluate(snap(.idle), now: t0).accessibilityLabel
        #expect(label.contains("on the iPhone") && !label.lowercased().contains("server") && !label.lowercased().contains("note"))
    }

    @Test func anOldOrMissingSnapshotIsUnknownNotLive() {
        let rec = snap(.recording, 1)
        #expect(ComplicationDisplay.evaluate(rec, now: t0.addingTimeInterval(34 * 60)).main == .recording)
        #expect(ComplicationDisplay.evaluate(rec, now: t0.addingTimeInterval(35 * 60)) == ComplicationDisplay(main: .unknown, sync: .unknown),
                "the app may have been terminated: no longer shown as recording")
        #expect(ComplicationDisplay.staleAt(rec) == t0.addingTimeInterval(35 * 60), "the timeline's second entry")
        #expect(ComplicationDisplay.evaluate(snap(.idle), now: t0.addingTimeInterval(5 * 3600)).main == .idle)
        #expect(ComplicationDisplay.evaluate(snap(.idle), now: t0.addingTimeInterval(6 * 3600)).main == .unknown)
        #expect(ComplicationDisplay.evaluate(nil, now: t0).main == .unknown)
        var future = snap(.recording)
        future.schema = 2
        #expect(ComplicationDisplay.evaluate(future, now: t0).main == .unknown, "an unknown schema is not guessed at")
        #expect(ComplicationDisplay.evaluate(snap(.recording, at: 3600), now: t0).main == .unknown, "a snapshot from the future (clock change)")
    }

    @Test func reloadsAreAskedForOnlyWhenTheFaceWouldChangeOrGoStale() {
        let first = snap(.recording, 0)
        #expect(ComplicationPublishPolicy.shouldWrite(last: nil, next: first))
        #expect(ComplicationPublishPolicy.shouldWrite(last: first, next: snap(.recording, 1, at: 10)), "none → waiting")
        #expect(!ComplicationPublishPolicy.shouldWrite(last: snap(.recording, 1), next: snap(.recording, 2, at: 60)), "count only, too soon")
        #expect(ComplicationPublishPolicy.shouldWrite(last: snap(.recording, 1), next: snap(.recording, 2, at: 300)))
        #expect(!ComplicationPublishPolicy.shouldWrite(last: first, next: snap(.recording, 0, at: 14 * 60)))
        #expect(ComplicationPublishPolicy.shouldWrite(last: first, next: snap(.recording, 0, at: 15 * 60)), "kept fresh while recording")
        #expect(!ComplicationPublishPolicy.shouldWrite(last: snap(.idle), next: snap(.idle, at: 3 * 3600)), "idle: no periodic reloads")
        #expect(ComplicationPublishPolicy.shouldWrite(last: first, next: snap(.paused, at: 1)), "state change: at once")
    }
}
