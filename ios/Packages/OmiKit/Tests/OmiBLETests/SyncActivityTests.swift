import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

/// A double of the system side (ActivityKit): which cards exist and what each one shows.
@MainActor
final class FakeActivityHost: SyncActivityHost {
    var enabled = true
    /// Cards on screen, oldest first: running ones and finished ones still shown.
    var cards: [(id: String, running: Bool, title: String)] = []
    var started = 0
    var updates: [(String, SyncActivityState, Date)] = []
    var ended: [(String, SyncActivityState?, SyncActivityEnding)] = []
    func existing() -> [(id: String, running: Bool)] { cards.map { ($0.id, $0.running) } }
    func start(_ state: SyncActivityState, staleDate: Date) throws -> String {
        started += 1
        let id = "act-\(started)"
        cards.append((id, true, state.title))
        return id
    }
    func update(_ id: String, _ state: SyncActivityState, staleDate: Date) {
        updates.append((id, state, staleDate))
        if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].title = state.title }
    }
    func end(_ id: String, final: SyncActivityState?, ending: SyncActivityEnding) {
        ended.append((id, final, ending))
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        if ending == .immediate { cards.remove(at: i) } else { cards[i].running = false; cards[i].title = final?.title ?? cards[i].title }
    }
}

@MainActor
final class FakeMemory: SyncActivityMemory {
    var dismissed = false
}

/// The sync Live Activity: what it may say (nothing invented) and when it exists (one, started only
/// in the foreground, never nagging after a dismissal, ended when everything reached the server).
@MainActor
@Suite struct SyncActivityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func state(_ stage: SyncActivityState.Stage, rate: Double? = nil, files: Int? = 4, seconds: Double? = 600, watch: Int? = nil) -> SyncActivityState {
        SyncActivityState(stage: stage, title: "\(stage)", rate: rate, queuedAudioSeconds: seconds, queuedFiles: files, watchWaitingSeconds: watch, asOf: now)
    }
    var done: SyncActivityState { state(.allSent, files: 0, seconds: 0) }

    func rig() -> (FakeActivityHost, FakeMemory, SyncActivityController) {
        let host = FakeActivityHost(), memory = FakeMemory()
        return (host, memory, SyncActivityController(host: host, memory: memory))
    }

    // MARK: content

    func summary(_ state: TransferSummary.UploadState, rate: Double? = nil, files: Int = 3, audioFiles: Int = 2, unknown: Int = 0,
                 watchSeconds: Int? = 50, inFlightTotal: Int64 = 0, inFlightSent: Int64 = 0, inFlightUnknown: Int = 0) -> TransferSummary {
        let w = TransferSummary.Watch(inUse: true, reportAt: now, reportFresh: true, waitingParts: 1, waitingSeconds: watchSeconds, receivedOnPhone: 1,
                                      lastReceivedAt: nil, converting: 0, waitingForServer: 0)
        let p = TransferSummary.Phone(state: state, rate: rate, networkBytes: 0, since: now, inFlightUploads: inFlightUnknown + (inFlightTotal > 0 ? 1 : 0),
                                      inFlightSent: inFlightSent, inFlightTotal: inFlightTotal, inFlightUnknownTotals: inFlightUnknown,
                                      deliveredAudioFiles: 0, deliveredAudioBytes: 0, deliveredOtherFiles: 0,
                                      retryingAttempts: 0, heldAttempts: 0, queuedFiles: files, queuedAudioFiles: audioFiles, queuedBytes: 1_000,
                                      queuedAudioSeconds: 125, queuedAudioUnknown: unknown, retryingFiles: 0, keptAside: 0)
        return TransferSummary(watch: w, phone: p, server: .init(reachable: true, checkedAt: now, chunksPending: nil, conversationsPending: 2, lastNoteAt: nil))
    }

    @Test func theContentSaysOnlyWhatIsKnown() {
        let sending = SyncActivityState(summary(.sending, rate: 48_000), now: now)
        #expect(sending.rate == 48_000 && sending.queuedAudioSeconds == 125 && sending.watchWaitingSeconds == 50)
        #expect(SyncActivityState(summary(.waiting), now: now).rate == nil, "no rate unless bytes are moving")
        #expect(SyncActivityState(summary(.waiting, audioFiles: 2, unknown: 2), now: now).queuedAudioSeconds == nil, "all lengths unknown: unknown, not 0")
        let partial = SyncActivityState(summary(.waiting, audioFiles: 2, unknown: 1), now: now)
        #expect(partial.queuedAudioSeconds == 125 && partial.queuedAudioPartial)
        let unreadable = SyncActivityState(summary(.queueUnreadable, files: 0, audioFiles: 0), now: now)
        #expect(unreadable.queuedFiles == nil && unreadable.queuedAudioSeconds == nil && unreadable.hasWork)
        #expect(SyncActivityState(summary(.keptAside(1), files: 0, audioFiles: 0), now: now).hasWork, "kept-aside files aren't 'all sent'")
    }

    /// LA-05 (Astra `watch_waiting_phone_empty`): an empty iPhone queue with Watch audio still to come
    /// says what the iPhone did, not that everything is on the server.
    @Test func anEmptyIPhoneQueueIsScopedToTheIPhone() {
        let s = SyncActivityState(summary(.allSent, files: 0, audioFiles: 0, watchSeconds: 230), now: now)
        #expect(s.title == "This iPhone has sent everything" && s.watchWaitingSeconds == 230 && s.hasWork)
        #expect(!s.title.contains("Everything has reached"), "not a claim about the Watch's audio")
    }

    /// LA-05 (Astra `partial_batch`): a batch with an upload of unknown size carries that, so no bar
    /// claims the whole batch is done.
    @Test func aBatchWithUnknownSizesSaysSo() {
        let s = SyncActivityState(summary(.sending, rate: 1, inFlightTotal: 100, inFlightSent: 100, inFlightUnknown: 1), now: now)
        #expect(s.batchSent == 100 && s.batchTotal == 100 && s.batchUnknownUploads == 1)
        let whole = SyncActivityState(summary(.sending, rate: 1, inFlightTotal: 100, inFlightSent: 40), now: now)
        #expect(whole.batchUnknownUploads == 0)
    }

    /// LA-05 (Astra `unknown_lengths`, `partial_batch`): the words keep "unknown" and "at least"
    /// everywhere, including the few characters of the Dynamic Island.
    @Test func theWordsKeepUnknownAndAtLeast() {
        let allUnknown = SyncActivityState(summary(.waiting, audioFiles: 2, unknown: 2), now: now)
        #expect(SyncWords.queued(allUnknown) == "audio of unknown length to send")
        #expect(SyncWords.compact(allUnknown, stale: false) == "Waiting" && SyncWords.trailing(allUnknown, stale: false) == "")
        let partial = SyncActivityState(summary(.waiting, audioFiles: 2, unknown: 1), now: now)
        #expect(SyncWords.queued(partial) == "at least 2 min of audio to send")
        #expect(SyncWords.compact(partial, stale: false) == "≥2 min" && SyncWords.trailing(partial, stale: true) == "≥2 min")
        let metadataOnly = SyncActivityState(summary(.waiting, files: 2, audioFiles: 0), now: now)
        #expect(SyncWords.queued(metadataOnly) == "2 files to send")
        let watchOnly = SyncActivityState(summary(.allSent, files: 0, audioFiles: 0, watchSeconds: 230), now: now)
        #expect(SyncWords.compact(watchOnly, stale: false) == "Watch 3 min", "not \"Sent\" while the Watch has audio")
        let mixed = SyncActivityState(summary(.sending, rate: 1, inFlightTotal: 100, inFlightSent: 100, inFlightUnknown: 1), now: now)
        #expect(SyncWords.batch(mixed)?.fraction == nil && SyncWords.batch(mixed)?.text.contains("1 of unknown size") == true, "no 100% bar")
        let known = SyncActivityState(summary(.sending, rate: 1, inFlightTotal: 100, inFlightSent: 40), now: now)
        #expect(SyncWords.batch(known)?.fraction == 0.4)
    }

    @Test func aStateFromAnEarlierBuildStillDecodes() throws {
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state(.waiting))) as! [String: Any]
        old["batchUnknownUploads"] = nil
        let decoded = try JSONDecoder().decode(SyncActivityState.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.batchUnknownUploads == nil && decoded.stage == .waiting)
    }

    // MARK: lifecycle

    @Test func itStartsOnlyInTheForegroundWithWorkAndOnlyOnce() {
        let (host, _, c) = rig()
        c.refresh(state(.waiting), foreground: false, optedOut: false, now: now)
        #expect(host.started == 0, "never started from the background")
        c.refresh(nil, foreground: true, optedOut: false, now: now)
        c.refresh(state(.unknown), foreground: true, optedOut: false, now: now)
        #expect(host.started == 0, "nothing measured: nothing to show")
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        #expect(host.started == 1 && host.cards.count == 1)
    }

    /// LA-02 (Astra `cold_placeholder_ends_adopted`): after a relaunch the activity is adopted and the
    /// engine's placeholder (nothing known yet) doesn't end it.
    @Test func aRelaunchKeepsItsActivityUntilSomethingIsKnown() {
        let (host, _, c) = rig()
        host.cards = [("old-1", true, "waiting"), ("old-2", true, "waiting")]
        c.adopt()
        #expect(c.activityId == "old-2" && host.cards.map(\.id) == ["old-2"], "one kept, the extra ended")
        c.refresh(nil, foreground: true, optedOut: false, now: now)  // placeholder snapshot
        #expect(c.activityId == "old-2" && host.ended.count == 1)
        c.refresh(state(.sending, rate: 10), foreground: true, optedOut: false, now: now)
        #expect(host.started == 0 && host.updates.last?.0 == "old-2")
    }

    /// LA-02 (Astra `dismiss_unknown_resume`): a dismissal holds through unknown, background and a
    /// relaunch, and only a confirmed finished sync clears it.
    @Test func aDismissalHoldsUntilASyncIsConfirmedFinished() {
        let (host, memory, c) = rig()
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        c.ended("act-1", dismissed: true)
        c.refresh(state(.unknown), foreground: false, optedOut: false, now: now.addingTimeInterval(10))
        c.refresh(nil, foreground: true, optedOut: false, now: now.addingTimeInterval(20))
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(30))
        #expect(host.started == 1 && memory.dismissed, "not recreated: the same sync")
        let relaunched = SyncActivityController(host: host, memory: memory)  // same memory = UserDefaults
        relaunched.adopt()
        relaunched.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(40))
        #expect(host.started == 1, "still dismissed after a relaunch")
        relaunched.refresh(done, foreground: true, optedOut: false, now: now.addingTimeInterval(50))
        #expect(!memory.dismissed)
        relaunched.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(60))
        #expect(host.started == 2, "a new sync may show again")
    }

    @Test func aSystemEndMayShowAgainOnTheNextForeground() {
        let (host, memory, c) = rig()
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        c.ended("act-1", dismissed: false)  // ended (e.g. time limit), not dismissed
        c.refresh(state(.waiting), foreground: false, optedOut: false, now: now)
        #expect(host.started == 1 && !memory.dismissed)
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        #expect(host.started == 2 && host.cards.map(\.id) == ["act-2"], "the ended card is removed, not left beside the new one")
    }

    /// LA-03 (Astra `completed_cards_accumulate`): drain/refill cycles leave at most one card, a
    /// relaunch adopts the finished one, and turning it off removes it.
    @Test func finishedCardsDontPileUpAndTurningOffRemovesThem() {
        let (host, _, c) = rig()
        for cycle in 0..<3 {
            let t = now.addingTimeInterval(Double(cycle) * 100)
            c.refresh(state(.waiting), foreground: true, optedOut: false, now: t)
            c.refresh(done, foreground: true, optedOut: false, now: t.addingTimeInterval(10))
        }
        #expect(host.cards.count == 1 && host.cards[0].running == false, "one finished card, not three")
        #expect(host.ended.contains { if case .after = $0.2 { return true } else { return false } }, "a short finished-card time, not the default")
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(400))
        #expect(host.cards.count == 1 && host.cards[0].running, "a new sync replaces the finished card")
        let relaunched = SyncActivityController(host: host, memory: FakeMemory())
        relaunched.adopt()
        relaunched.refresh(state(.waiting), foreground: true, optedOut: true, now: now.addingTimeInterval(500))
        #expect(host.cards.isEmpty, "turning it off removes this feature's cards")
    }

    /// LA-03, found by the repair harness with the real adapter: ActivityKit reports a card ended with a
    /// later dismissal as `.ended` at once. It is still on screen, so it stays ours to remove.
    @Test func aFinishedCardReportedEndedIsStillRemoved() {
        let (host, _, c) = rig()
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        c.refresh(done, foreground: true, optedOut: false, now: now.addingTimeInterval(10))
        c.ended("act-1", dismissed: false)  // what ActivityKit reports right after end(_:dismissalPolicy: .after)
        #expect(c.finishedId == "act-1")
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(20))
        #expect(host.cards.count == 1 && host.cards[0].id == "act-2", "the finished card is replaced, not left beside it")
        c.refresh(done, foreground: true, optedOut: false, now: now.addingTimeInterval(30))
        c.ended("act-2", dismissed: false)
        c.refresh(done, foreground: true, optedOut: true, now: now.addingTimeInterval(40))
        #expect(host.cards.isEmpty, "turning it off removes it")
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(50))
        c.ended("act-3", dismissed: true)  // gone from the screen: nothing left to remove
        #expect(c.finishedId == nil && c.activityId == nil)
    }

    @Test func aFinishedSyncSaysTheServerStillProcesses() {
        let (host, _, c) = rig()
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        let final = SyncActivityState(stage: .allSent, title: "This iPhone has sent everything", detail: "Your server is processing 2",
                                      queuedFiles: 0, asOf: now)
        c.refresh(final, foreground: false, optedOut: false, now: now)
        #expect(host.ended.last?.1?.detail == "Your server is processing 2" && c.activityId == nil)
    }

    @Test func noServerEndsItWithoutClearingADismissal() {
        let (host, memory, c) = rig()
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        memory.dismissed = true
        c.refresh(state(.notConfigured, files: 0, seconds: nil), foreground: true, optedOut: false, now: now)
        #expect(host.cards.isEmpty && memory.dismissed, "not a finished sync")
    }

    @Test func numericChangesAreThrottledStageChangesAreNot() {
        let (host, _, c) = rig()
        c.refresh(state(.sending, rate: 10), foreground: true, optedOut: false, now: now)
        c.refresh(state(.sending, rate: 20), foreground: true, optedOut: false, now: now.addingTimeInterval(3))
        #expect(host.updates.isEmpty, "a rate change within the interval waits")
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(4))
        #expect(host.updates.count == 1, "a stage change goes at once")
        c.refresh(state(.waiting, seconds: 500), foreground: true, optedOut: false, now: now.addingTimeInterval(20))
        #expect(host.updates.count == 2)
    }

    /// LA-01 (Astra `snapshot_trigger_gap`): with a rate shown the app looks again within seconds;
    /// an unchanged state measured again is renewed, not left to read as stale.
    @Test func ShownRatesAreRecheckedAndUnchangedStatesRenewed() {
        let (host, _, c) = rig()
        c.refresh(state(.sending, rate: 10), foreground: true, optedOut: false, now: now)
        #expect(c.nextCheck(now: now) == now.addingTimeInterval(SyncActivityController.rateRecheck))
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(4))  // bytes stopped
        #expect(host.updates.last?.1.rate == nil)
        #expect(c.nextCheck(now: now.addingTimeInterval(4)) == now.addingTimeInterval(4 + SyncActivityController.renewAfter))
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now.addingTimeInterval(60))
        #expect(host.updates.count == 1, "unchanged and recent: nothing pushed")
        let later = now.addingTimeInterval(4 + SyncActivityController.renewAfter)
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: later)
        #expect(host.updates.count == 2 && host.updates.last?.2 == later.addingTimeInterval(SyncActivityController.queueStale), "renewed")
        c.refresh(nil, foreground: false, optedOut: false, now: later.addingTimeInterval(SyncActivityController.renewAfter))
        c.refresh(state(.waiting), foreground: false, optedOut: false, now: later.addingTimeInterval(SyncActivityController.renewAfter))
        #expect(host.updates.count == 2, "in the background nothing is watched: never renewed")
    }

    @Test func disabledOrOptedOutShowsNothingAndEndsWhatIsThere() {
        let (host, _, c) = rig()
        host.enabled = false
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        #expect(host.started == 0)
        host.enabled = true
        c.refresh(state(.waiting), foreground: true, optedOut: false, now: now)
        c.refresh(state(.waiting), foreground: true, optedOut: true, now: now)
        #expect(host.cards.isEmpty && c.activityId == nil)
    }
}

/// LA-04 (Astra `async_update_order`): the SDK calls run one after another, so an update delayed at
/// the SDK can't land after a newer one or after the end.
@MainActor
@Suite struct OrderedActivityOperationsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A slow SDK double: the first update waits until released; records what each card shows.
    final class SlowSDK: @unchecked Sendable {
        private let lock = NSLock()
        private var _shown: [String: String] = [:]
        private var _log: [String] = []
        private var gate: CheckedContinuation<Void, Never>?
        var holdFirst = true
        var shown: [String: String] { lock.withLock { _shown } }
        var log: [String] { lock.withLock { _log } }
        func send(_ id: String, _ title: String) async {
            let hold = lock.withLock { () -> Bool in let h = holdFirst; holdFirst = false; return h }
            if hold { await withCheckedContinuation { c in lock.withLock { gate = c } } }
            lock.withLock { _shown[id] = title; _log.append("update \(title)") }
        }
        func finish(_ id: String) { lock.withLock { _shown[id] = nil; _log.append("end") } }
        func release() { lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { gate = nil }; return gate }?.resume() }
        var waiting: Bool { lock.withLock { gate != nil } }
    }

    func ops(_ sdk: SlowSDK) -> OrderedActivityOperations {
        OrderedActivityOperations(send: { id, s, _ in await sdk.send(id, s.title) }, finish: { id, _, _ in sdk.finish(id) })
    }

    func s(_ title: String) -> SyncActivityState { SyncActivityState(stage: .sending, title: title, asOf: now) }

    func untilHeld(_ sdk: SlowSDK) async { while !sdk.waiting { await Task.yield() } }

    @Test func aDelayedOlderUpdateNeverEndsUpOnScreen() async {
        let sdk = SlowSDK(), o = ops(sdk)
        o.update("a", s("older sending"), staleDate: now)
        await untilHeld(sdk)
        o.update("a", s("new offline"), staleDate: now)
        sdk.release()
        await o.drain()
        #expect(sdk.shown["a"] == "new offline", "\(sdk.log)")
    }

    @Test func nothingLandsAfterTheEnd() async {
        let sdk = SlowSDK(), o = ops(sdk)
        o.update("a", s("older sending"), staleDate: now)
        await untilHeld(sdk)
        o.update("a", s("newer"), staleDate: now)
        o.end("a", final: nil, ending: .immediate)
        o.update("a", s("after the end"), staleDate: now)
        sdk.release()
        await o.drain()
        #expect(sdk.shown["a"] == nil && sdk.log.last == "end", "\(sdk.log)")
        #expect(!sdk.log.contains("update after the end") && !sdk.log.contains("update newer"), "superseded by the end, skipped")
    }

    @Test func updatesQueuedBehindASlowOneCoalesceToTheNewest() async {
        let sdk = SlowSDK(), o = ops(sdk)
        o.update("a", s("1"), staleDate: now)
        await untilHeld(sdk)
        o.update("a", s("2"), staleDate: now)
        o.update("a", s("3"), staleDate: now)
        sdk.release()
        await o.drain()
        #expect(sdk.log == ["update 1", "update 3"] && sdk.shown["a"] == "3")
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
        let model = AppModel(engine: engine, noteCache: NoteCache(root: dir.appendingPathComponent("cache")))  // never ~/Library/Caches
        #expect(model.handleOpenURL(URL(string: "omi-notes://transfers")!))
        #expect(model.transferPageRequests == 1 && model.pendingConfigure == nil)
        #expect(!model.handleOpenURL(URL(string: "omi-notes://elsewhere")!) && model.transferPageRequests == 1)
    }
}
