import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

@MainActor
final class FakeActivityHost: SyncActivityHost {
    var enabled = true
    var live: [String] = []
    var started = 0
    var updates: [(String, SyncActivityState, Date)] = []
    var ended: [(String, SyncActivityState?)] = []
    func existing() -> [String] { live }
    func start(_ state: SyncActivityState, staleDate: Date) throws -> String {
        started += 1
        let id = "act-\(started)"
        live.append(id)
        return id
    }
    func update(_ id: String, _ state: SyncActivityState, staleDate: Date) { updates.append((id, state, staleDate)) }
    func end(_ id: String, final: SyncActivityState?) { ended.append((id, final)); live.removeAll { $0 == id } }
}

/// The sync Live Activity: what it may say (nothing invented) and when it exists (one, started only
/// in the foreground, never nagging after a dismissal, ended when everything reached the server).
@MainActor
@Suite struct SyncActivityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func state(_ stage: SyncActivityState.Stage, rate: Double? = nil, files: Int? = 4, seconds: Double? = 600) -> SyncActivityState {
        SyncActivityState(stage: stage, title: "\(stage)", rate: rate, queuedAudioSeconds: seconds, queuedFiles: files, asOf: now)
    }

    // MARK: content

    func summary(_ state: TransferSummary.UploadState, rate: Double? = nil, files: Int = 3, audioFiles: Int = 2, unknown: Int = 0) -> TransferSummary {
        let w = TransferSummary.Watch(inUse: true, reportAt: now, reportFresh: true, waitingParts: 1, waitingSeconds: 50, receivedOnPhone: 1,
                                      lastReceivedAt: nil, converting: 0, waitingForServer: 0)
        let p = TransferSummary.Phone(state: state, rate: rate, networkBytes: 0, since: now, inFlightUploads: 0, inFlightSent: 0, inFlightTotal: 0,
                                      inFlightUnknownTotals: 0, deliveredAudioFiles: 0, deliveredAudioBytes: 0, deliveredOtherFiles: 0,
                                      retryingAttempts: 0, heldAttempts: 0, queuedFiles: files, queuedAudioFiles: audioFiles, queuedBytes: 1_000,
                                      queuedAudioSeconds: 125, queuedAudioUnknown: unknown, retryingFiles: 0, keptAside: 0)
        return TransferSummary(watch: w, phone: p, server: .init(reachable: true, checkedAt: now, chunksPending: nil, conversationsPending: 2, lastNoteAt: nil))
    }

    @Test func theContentSaysOnlyWhatIsKnown() {
        let sending = SyncActivityState(summary(.sending, rate: 48_000), now: now)
        #expect(sending.rate == 48_000 && sending.queuedAudioSeconds == 125 && sending.watchWaitingSeconds == 50)
        let waiting = SyncActivityState(summary(.waiting, rate: nil), now: now)
        #expect(waiting.rate == nil, "no rate unless bytes are moving")
        let unknownLength = SyncActivityState(summary(.waiting, audioFiles: 2, unknown: 2), now: now)
        #expect(unknownLength.queuedAudioSeconds == nil, "every chunk of unknown length: unknown, not 0")
        let partial = SyncActivityState(summary(.waiting, audioFiles: 2, unknown: 1), now: now)
        #expect(partial.queuedAudioSeconds == 125 && partial.queuedAudioPartial)
        let unreadable = SyncActivityState(summary(.queueUnreadable, files: 0, audioFiles: 0), now: now)
        #expect(unreadable.queuedFiles == nil && unreadable.queuedAudioSeconds == nil && unreadable.hasWork)
        let kept = SyncActivityState(summary(.keptAside(1), files: 0, audioFiles: 0), now: now)
        #expect(kept.hasWork, "kept-aside files aren't 'all sent'")
        let done = SyncActivityState(summary(.allSent, files: 0, audioFiles: 0), now: now)
        #expect(done.stage == .allSent && done.detail == "Your server is processing 2", "processing is the server's, said apart")
        #expect(done.hasWork, "the Watch still has audio waiting")
    }

    // MARK: lifecycle

    @Test func itStartsOnlyInTheForegroundWithWorkAndOnlyOnce() {
        let host = FakeActivityHost(), c = SyncActivityController(host: host)
        c.refresh(state(.waiting), foreground: false, optedOut: false, now: now)
        #expect(host.started == 0, "never started from the background")
        c.refresh(state(.unknown), foreground: true, optedOut: false, now: now)
        #expect(host.started == 0, "nothing measured: nothing to show")
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        #expect(host.started == 1 && host.live.count == 1)
    }

    @Test func aRelaunchAdoptsOneAndEndsExtras() {
        let host = FakeActivityHost()
        host.live = ["old-1", "old-2"]
        let c = SyncActivityController(host: host)
        c.adopt()
        #expect(c.activityId == "old-1" && host.live == ["old-1"])
        c.refresh(state(.sending, rate: 10), foreground: true, optedOut: false, now: now)
        #expect(host.started == 0 && host.updates.last?.0 == "old-1")
    }

    @Test func numericChangesAreThrottledStageChangesAreNot() {
        let host = FakeActivityHost(), c = SyncActivityController(host: host)
        c.refresh(state(.sending, rate: 10), foreground: true, optedOut: false, now: now)
        c.refresh(state(.sending, rate: 20), foreground: true, optedOut: false, now: now.addingTimeInterval(3))
        #expect(host.updates.isEmpty, "a rate change within the interval waits")
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(4))
        #expect(host.updates.count == 1, "a stage change goes at once")
        c.refresh(state(.waiting, seconds: 500), foreground: true, optedOut: false, now: now.addingTimeInterval(20))
        #expect(host.updates.count == 2)
    }

    @Test func aLiveRateGoesStaleSoonAQueueLater() {
        let host = FakeActivityHost(), c = SyncActivityController(host: host)
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        c.refresh(state(.sending, rate: 99), foreground: true, optedOut: false, now: now.addingTimeInterval(1))
        #expect(host.updates.last?.2 == now.addingTimeInterval(1 + SyncActivityController.liveStale))
        #expect(SyncActivityController.staleDate(state(.waiting), now: now) == now.addingTimeInterval(SyncActivityController.queueStale))
    }

    @Test func notMeasuredLeavesTheLastStateToGoStale() {
        let host = FakeActivityHost(), c = SyncActivityController(host: host)
        c.refresh(state(.sending, rate: 99), foreground: true, optedOut: false, now: now)
        c.refresh(state(.unknown), foreground: true, optedOut: false, now: now.addingTimeInterval(60))
        #expect(host.updates.isEmpty && host.ended.isEmpty, "no frozen 'sending' pushed again; the stale date takes over")
    }

    @Test func itEndsWhenEverythingReachedTheServerSayingProcessingIsSeparate() {
        let host = FakeActivityHost(), c = SyncActivityController(host: host)
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        let done = SyncActivityState(stage: .allSent, title: "Everything has reached your server", detail: "Your server is processing 2", queuedFiles: 0, asOf: now)
        c.refresh(done, foreground: false, optedOut: false, now: now)
        #expect(host.ended.count == 1 && host.ended[0].1?.stage == .allSent && c.activityId == nil)
    }

    @Test func aDismissalIsntRecreatedUntilTheSyncIsOver() {
        let host = FakeActivityHost(), c = SyncActivityController(host: host)
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        c.ended("act-1", byUser: true)
        c.refresh(state(.sending, rate: 5), foreground: true, optedOut: false, now: now.addingTimeInterval(30))
        #expect(host.started == 1, "no nagging: the same sync stays dismissed")
        c.refresh(state(.allSent, files: 0, seconds: 0), foreground: true, optedOut: false, now: now.addingTimeInterval(60))
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(90))
        #expect(host.started == 2, "a new sync later may show again")
    }

    @Test func aSystemEndMayShowAgainOnTheNextForeground() {
        let host = FakeActivityHost(), c = SyncActivityController(host: host)
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        c.ended("act-1", byUser: false)  // e.g. its time limit
        c.refresh(state(.waiting), foreground: false, optedOut: false, now: now)
        #expect(host.started == 1)
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        #expect(host.started == 2)
    }

    @Test func disabledOrOptedOutShowsNothingAndEndsWhatIsThere() {
        let host = FakeActivityHost(), c = SyncActivityController(host: host)
        host.enabled = false
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        #expect(host.started == 0)
        host.enabled = true
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        c.refresh(state(.waiting), foreground: true, optedOut: true, now: now)
        #expect(host.live.isEmpty && c.activityId == nil)
    }
}

/// The Live Activity's tap opens Devices → Transfers (`omi-notes://transfers`), not a configure sheet.
@MainActor
@Suite struct SyncActivityLinkTests {
    @Test func theTransfersLinkAsksForTheTransfersPage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omi-link-\(UUID().uuidString)")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-link-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        let engine = OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: dir), appVersion: "t", timezone: "UTC", useCoreBluetooth: false),
                               settings: settings, uploadTransport: CountingUploadTransport())
        let model = AppModel(engine: engine)
        #expect(model.handleOpenURL(URL(string: "omi-notes://transfers")!))
        #expect(model.transferPageRequests == 1 && model.pendingConfigure == nil)
        #expect(!model.handleOpenURL(URL(string: "omi-notes://elsewhere")!) && model.transferPageRequests == 1)
    }
}
