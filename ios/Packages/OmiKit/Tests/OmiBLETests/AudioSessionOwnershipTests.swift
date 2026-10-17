import Testing
@testable import OmiBLE

/// When a note's player may deactivate the app's shared audio session (telling other apps they may
/// resume). The session is shared with the clip players, so it must never deactivate one they own.
@Suite struct AudioSessionOwnershipTests {
    @Test func aUserPauseOrLeavingReleasesWhatThisPlayerActivated() {
        var s = AudioSessionOwnership()
        let r1 = s.handle(.play); #expect(!r1)
        let r2 = s.handle(.pause); #expect(r2, "paused by the user: other audio may resume")
        let r3 = s.handle(.teardown); #expect(!r3, "already released")
        _ = s.handle(.play)
        let r4 = s.handle(.end); #expect(r4)
    }

    @Test func anInterruptionLeavesNothingToRelease() {
        var s = AudioSessionOwnership()
        _ = s.handle(.play)
        let r5 = s.handle(.interrupted); #expect(!r5, "the system already deactivated it for the call")
        let r6 = s.handle(.teardown); #expect(!r6)
    }

    @Test func lostHeadphonesKeepTheSessionUntilTheUserActsOrLeaves() {
        var s = AudioSessionOwnership()
        _ = s.handle(.play)
        let r7 = s.handle(.outputLost); #expect(!r7, "not now: other audio would resume on the speaker")
        let r8 = s.handle(.teardown); #expect(r8, "leaving the note after a system pause still releases it")
    }

    @Test func anotherPlayerStartingTakesTheSessionOver() {
        var s = AudioSessionOwnership()
        _ = s.handle(.play)
        let r9 = s.handle(.otherAudioStarting); #expect(!r9)
        let r10 = s.handle(.pause); #expect(!r10, "the clip player owns it now: don't deactivate its session")
        let r11 = s.handle(.teardown); #expect(!r11)
    }
}
