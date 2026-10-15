import Foundation
import Testing
@testable import OmiWatchKit

/// The watch-face complication shows only what the Watch app knows, and stops claiming it once old.
@Suite struct WatchComplicationTests {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    func snap(_ r: ComplicationSnapshot.Recorder, _ waiting: Int = 0, seconds: Int? = nil, bound: Bool = true, at: TimeInterval = 0) -> ComplicationSnapshot {
        ComplicationSnapshot(at: t0.addingTimeInterval(at), recorder: r, waitingParts: waiting, waitingSeconds: seconds ?? waiting * 60, bound: bound)
    }

    @Test func eachStateAndTheQueueAreShownAndOnlyTheIPhoneIsClaimed() {
        #expect(ComplicationDisplay.evaluate(snap(.recording, 3, seconds: 150), now: t0) == ComplicationDisplay(main: .recording, sync: .waiting(seconds: 150)))
        #expect(ComplicationDisplay.evaluate(snap(.paused), now: t0) == ComplicationDisplay(main: .paused, sync: .onIPhone))
        #expect(ComplicationDisplay.evaluate(snap(.failed), now: t0).main == .error)
        #expect(ComplicationDisplay.evaluate(snap(.idle, 2, seconds: 40), now: t0) == ComplicationDisplay(main: .idle, sync: .waiting(seconds: 40)))
        #expect(ComplicationDisplay.evaluate(snap(.idle, 1, seconds: 0), now: t0).sync == .waiting(seconds: nil), "only an end marker: no length to show")
        var old = snap(.idle, 4)
        old.waitingSeconds = nil
        #expect(ComplicationDisplay.evaluate(old, now: t0).sync == .waiting(seconds: nil), "unknown length is not guessed from the count")
        #expect(ComplicationDisplay.evaluate(snap(.idle, 5, bound: false), now: t0).sync == .notConnected)
        let label = ComplicationDisplay.evaluate(snap(.idle), now: t0).accessibilityLabel
        #expect(label.contains("on the iPhone") && !label.lowercased().contains("server") && !label.lowercased().contains("note"))
    }

    @Test func waitingAudioIsTheRecordedLengthNotACount() {
        func seg(_ i: Int, _ start: Int64, _ end: Int64) -> WatchSegment {
            WatchSegment(recordingId: "r", index: i, deviceId: "w", deviceName: "W", binding: "p", recordingStartedAt: t0,
                         startOffsetUs: start, endOffsetUs: end, bytes: 1, sha256: "")
        }
        // two full minutes and a 12.4 s partial part (a stop or an interruption)
        let parts = [seg(0, 0, 60_000_000), seg(1, 60_000_000, 120_000_000), seg(2, 120_000_000, 132_400_000)]
        #expect(WaitingAudio.seconds(parts) == 132, "not 3 × 60")
        #expect(WaitingAudio.seconds([seg(0, 5, 2)]) == 0, "a damaged manifest adds nothing")
        #expect(WaitingAudio.short(0) == "" && WaitingAudio.short(40) == "<1m" && WaitingAudio.short(132) == "2m"
                && WaitingAudio.short(99 * 60) == "99m" && WaitingAudio.short(19 * 3600 + 300) == "19h")
        #expect(WaitingAudio.text(40) == "less than a minute" && WaitingAudio.text(132) == "2 min" && WaitingAudio.text(3900) == "1 h 5 min")
        #expect(WaitingAudio.spoken(60) == "1 minute" && WaitingAudio.spoken(7200) == "2 hours")
        let label = ComplicationDisplay(main: .recording, sync: .waiting(seconds: 720)).accessibilityLabel
        #expect(label.contains("12 minutes of audio waiting to go to the iPhone"))
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
        #expect(!ComplicationPublishPolicy.shouldWrite(last: snap(.recording, 1), next: snap(.recording, 2, at: 60)), "length only, too soon")
        #expect(!ComplicationPublishPolicy.shouldWrite(last: snap(.recording, 1, seconds: 61), next: snap(.recording, 2, seconds: 90, at: 400)), "same minutes shown")
        #expect(ComplicationPublishPolicy.shouldWrite(last: snap(.recording, 1), next: snap(.recording, 2, at: 300)))
        #expect(!ComplicationPublishPolicy.shouldWrite(last: first, next: snap(.recording, 0, at: 14 * 60)))
        #expect(ComplicationPublishPolicy.shouldWrite(last: first, next: snap(.recording, 0, at: 15 * 60)), "kept fresh while recording")
        #expect(!ComplicationPublishPolicy.shouldWrite(last: snap(.idle), next: snap(.idle, at: 3 * 3600)), "idle: no periodic reloads")
        #expect(ComplicationPublishPolicy.shouldWrite(last: first, next: snap(.paused, at: 1)), "state change: at once")
    }
}
