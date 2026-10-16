import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol
import OmiWatchKit

@Suite struct SystemHealthTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func streaming() -> EngineSnapshot {
        var s = EngineSnapshot()
        s.ready = true
        s.connection = .streaming
        s.serverConfigured = true
        s.rememberedDeviceName = "Omi"
        var d = DeviceSession.Info()
        d.battery = 80
        s.device = d
        return s
    }

    func status(_ queue: [String: Int] = [:], worker: Bool = true, readOnly: String? = nil) throws -> ServerStatus {
        var q = ["chunks_pending": 0, "conversations_open": 0, "conversations_pending": 0, "failed": 0, "conversations_failed": 0,
                 "chunks_failed": 0, "conversations_retrying": 0, "notes_conflicted": 0]
        q.merge(queue) { $1 }
        let body: [String: Any] = [
            "ok": true, "stt": ["provider": "fake", "ready": true], "llm": ["provider": "fake", "ready": true], "queue": q,
            "worker": ["present": worker], "last_note_at": "2026-09-21T12:00:00.000Z", "read_only": readOnly ?? NSNull(),
            "features": ["issues"],
        ]
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: body))
    }

    func reachable() -> ServerReachability { .reachable(version: "0.1.0", detail: "") }

    func health(_ s: EngineSnapshot, _ reach: ServerReachability, _ st: ServerStatus?, age: TimeInterval = 10) -> SystemHealth {
        SystemHealth.evaluate(snapshot: s, server: reach, status: st, statusAt: st == nil ? nil : now.addingTimeInterval(-age), now: now)
    }

    func step(_ h: SystemHealth, _ area: SystemHealth.Area) -> SystemHealth.Step { h.steps.first { $0.area == area }! }

    @Test func allGoodIsNormal() throws {
        let h = health(streaming(), reachable(), try status())
        #expect(h.level == .normal && h.headline == "Connected; no reported problems")
        #expect(step(h, .notes).title.hasPrefix("Last note"))
    }

    @Test func unreachableServerWithQueuedAudioIsDelayedNotBroken() {
        var s = streaming()
        s.outbox.pendingCount = 3
        let h = health(s, .unreachable("offline"), nil)
        #expect(h.level == .delayed)
        #expect(step(h, .phone).level == .delayed && step(h, .phone).title == "Audio is waiting to upload" && step(h, .phone).detail?.hasPrefix("3 files") == true)
        #expect(step(h, .server).level == .delayed && step(h, .server).fix == .openServer)
    }

    @Test func rejectedTokenNeedsAction() {
        let h = health(streaming(), .unauthorized, nil)
        #expect(h.level == .needsAction && h.headline == "The server rejected this phone")
    }

    @Test func staleStatusIsUnknownButPhoneProblemsStillWin() throws {
        let stale = health(streaming(), reachable(), try status(), age: 3600)
        #expect(stale.level == .unknown && step(stale, .server).title.hasPrefix("Server last checked"))

        var full = streaming()
        full.storageTripped = true
        full.connection = .paused("phone storage low")
        let h = health(full, reachable(), try status(), age: 3600)
        #expect(h.level == .needsAction && h.headline == "Recording is paused")
        #expect(step(h, .phone).title == "Phone storage is full; recording stopped")
    }

    @Test func disconnectedPendantIsUnknownNotAClaim() throws {
        var s = streaming()
        s.connection = .waitingForDevice
        s.device = nil
        let h = health(s, reachable(), try status())
        #expect(h.level == .unknown && h.headline == "Omi isn't connected")
        #expect(step(h, .pendant).detail?.contains("If its firmware supports offline recording") == true)
    }

    @Test func failedChunksAndConflictsNeedAction() throws {
        let chunks = health(streaming(), reachable(), try status(["chunks_failed": 2]))
        #expect(chunks.level == .needsAction && chunks.headline == "2 items couldn't be finished on the server")
        #expect(chunks.detail == "The server keeps the audio. See Server for what happened.")
        let conflict = health(streaming(), reachable(), try status(["notes_conflicted": 1]))
        #expect(conflict.headline == "1 item couldn't be finished on the server")
    }

    @Test func aNoSpeakerResultIsNotCriticalAndGenuineFailuresStillAre() throws {
        func issue(_ id: String, keep: Bool) throws -> ServerIssue {
            try JSONDecoder().decode(ServerIssue.self, from: Data(#"{"code":"conversation_failed","severity":"action","message":"m","can_keep":\#(keep),"conversation_id":"\#(id)"}"#.utf8))
        }
        let st = try status(["conversations_failed": 1, "failed": 1])
        let kept = SystemHealth.evaluate(snapshot: streaming(), server: reachable(), status: st, statusAt: now.addingTimeInterval(-10), now: now,
                                         issues: [try issue("c1", keep: true)])
        #expect(kept.level == .delayed && kept.headline == "1 recording has no separable speaker")
        #expect(step(kept, .server).fix == .openServer)
        let mixed = SystemHealth.evaluate(snapshot: streaming(), server: reachable(), status: try status(["conversations_failed": 2]),
                                          statusAt: now.addingTimeInterval(-10), now: now, issues: [try issue("c1", keep: true), try issue("c2", keep: false)])
        #expect(mixed.level == .needsAction && mixed.headline == "1 item couldn't be finished on the server")
        // once kept, the server's counts are zero: nothing left to show
        let after = SystemHealth.evaluate(snapshot: streaming(), server: reachable(), status: try status(), statusAt: now.addingTimeInterval(-10), now: now)
        #expect(after.level == .normal)
    }

    @Test func olderServersFallBackToTheLegacyFailedSum() throws {
        let json = #"{"queue":{"chunks_pending":0,"conversations_open":0,"conversations_pending":0,"failed":1}}"#
        let st = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
        let h = health(streaming(), reachable(), st)
        #expect(step(h, .server).level == .needsAction)
        #expect(step(h, .notes).level == .normal)  // an older server can't say when; not "no notes"
    }

    @Test func missingHealthFieldsAreUnknownNeverGreen() throws {
        for json in [#"{"ok":true}"#, #"{"queue":{"failed":0}}"#] {
            let st = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
            let h = health(streaming(), reachable(), st)
            #expect(step(h, .server).level == .unknown && h.level != .normal, "\(json)")
        }
    }

    @Test func unconfiguredSummariesNeedAction() throws {
        let body: [String: Any] = ["llm": ["provider": "anthropic", "ready": false], "stt": ["provider": "fake", "ready": true],
                "queue": ["failed": 0], "worker": ["present": true]]
        let st = try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: body))
        let h = health(streaming(), reachable(), st)
        #expect(h.level == .needsAction && h.headline == "Summaries aren't set up on the server")
    }

    @Test func missingWorkerAndReadOnlyNeedAction() throws {
        let stopped = health(streaming(), reachable(), try status(worker: false))
        #expect(stopped.headline == "Processing is stopped on the server")
        let ro = health(streaming(), reachable(), try status(readOnly: "vault divergence"))
        #expect(ro.level == .needsAction && ro.headline == "The server stopped saving notes")
    }

    @Test func retryingIsDelayedAndProcessingIsWorking() throws {
        let retry = health(streaming(), reachable(), try status(["conversations_retrying": 1]))
        #expect(retry.level == .delayed)
        let busy = health(streaming(), reachable(), try status(["conversations_pending": 2]))
        #expect(busy.level == .working && busy.headline == "Recording; notes are catching up")
    }

    @Test func noNotesYetOnANewServer() throws {
        let json = #"{"queue":{"failed":0,"conversations_failed":0,"chunks_failed":0},"worker":{"present":true},"last_note_at":null,"features":["issues"]}"#
        let st = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
        let h = health(streaming(), reachable(), st)
        #expect(h.level == .unknown && h.headline == "No notes yet")
    }

    @Test func nothingPairedNeedsAction() {
        var s = EngineSnapshot()
        s.ready = true  // the engine looked: no pendant remembered, no Watch evidence
        s.serverConfigured = false
        let h = health(s, .notConfigured, nil)
        #expect(h.level == .needsAction && h.headline == "No recording device set up")
        #expect(step(h, .pendant).detail?.contains("Apple Watch") == true, "either device starts recording")
        #expect(step(h, .pendant).fix == .openDevices, "both choices, not a pendant-only button")
        #expect(step(h, .server).fix == .openServer)
    }

    /// Alan's screenshot: both devices set up, yet Home said "No recording device set up". Before the
    /// engine's first snapshot (it runs launch recovery first) the app showed the empty default as if
    /// it were the engine's answer.
    @Test func beforeTheEnginesFirstSnapshotNothingIsClaimedMissing() {
        let h = health(EngineSnapshot(), reachable(), nil)
        #expect(step(h, .pendant).level == .unknown && step(h, .pendant).fix == nil, "\(step(h, .pendant))")
        #expect(step(h, .pendant).title == "Checking your devices" && h.level != .needsAction)
    }

    @Test func aRememberedPendantOutOfRangeAfterARelaunchIsNotUnpaired() {
        var s = EngineSnapshot()
        s.ready = true
        s.serverConfigured = true
        s.connection = .waitingForDevice
        s.rememberedDeviceName = "Omi"
        let h = health(s, reachable(), nil)
        #expect(step(h, .pendant).title == "Omi isn't connected" && step(h, .pendant).level == .unknown && step(h, .pendant).fix == nil)
    }

    @Test func anInstalledWatchAppWithoutAReportIsNotNothingSetUp() {
        var s = EngineSnapshot()
        s.ready = true
        s.serverConfigured = true
        let h = SystemHealth.evaluate(snapshot: s, server: reachable(), status: nil, statusAt: nil, now: now, watchAppInstalled: true)
        #expect(step(h, .pendant).level == .normal && step(h, .pendant).fix == nil, "\(step(h, .pendant))")
        #expect(!step(h, .pendant).title.contains("Recording"), "installed is not recording")
        let unknown = SystemHealth.evaluate(snapshot: s, server: reachable(), status: nil, statusAt: nil, now: now, watchAppInstalled: nil)
        #expect(step(unknown, .pendant).level == .needsAction, "no evidence at all: the real first-time case")
    }

    @Test func aWatchUserWithoutAPendantIsNotToldToPairOne() {
        var s = streaming()
        s.connection = .noDevice
        s.watchLastReceivedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let h = health(s, reachable(), nil)
        #expect(step(h, .pendant).level == .normal && step(h, .pendant).fix == nil, "\(step(h, .pendant))")
        #expect(!step(h, .pendant).title.contains("Recording"), "a receipt doesn't mean the Watch is recording now")
        #expect(h.headline != "No recording device set up" && h.level != .needsAction)
    }

    @Test func aFreshlyPausedWatchIsOnHomeAndAnOldReportIsNot() {
        let now = Date()
        var s = streaming()
        s.watchReport = WatchReport(state: .paused, since: now.addingTimeInterval(-600), waitingParts: 0, at: now.addingTimeInterval(-30))
        let h = SystemHealth.evaluate(snapshot: s, server: reachable(), status: nil, statusAt: nil, now: now)
        let watch = h.steps.first { $0.area == .watch }
        #expect(watch?.level == .needsAction && watch?.detail?.contains("Resume") == true && h.headline == watch?.title)
        s.watchReport?.at = now.addingTimeInterval(-3600)
        #expect(SystemHealth.evaluate(snapshot: s, server: reachable(), status: nil, statusAt: nil, now: now).steps.allSatisfy { $0.area != .watch },
                "an hour-old report claims nothing about now")
    }
}

@MainActor
@Suite struct RecentMergeTests {
    func row(_ id: String, _ minute: Int) -> ConversationSummary {
        let json = #"{"id":"\#(id)","status":"done","started_at":"2026-09-26T19:\#(String(format: "%02d", minute)):00.000Z"}"#
        return try! JSONDecoder().decode(ConversationSummary.self, from: Data(json.utf8))
    }

    func page(_ rows: [ConversationSummary], cursor: String?) -> RecentConversationsResponse {
        var p = try! JSONDecoder().decode(RecentConversationsResponse.self, from: Data(#"{"conversations":[]}"#.utf8))
        p.conversations = rows
        p.nextCursor = cursor
        return p
    }

    func model() -> AppModel {
        let dirs = CaptureDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-merge-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        let engine = OmiEngine(config: EngineConfiguration(dirs: dirs, appVersion: "test", useCoreBluetooth: false),
                               settings: settings, uploadTransport: CountingUploadTransport())
        return AppModel(engine: engine)
    }

    @Test func refreshingPageOneKeepsOlderLoadedPages() {
        let m = model()
        m.mergeFirstPage(page([row("d", 40), row("c", 30)], cursor: "c1"))
        m.mergeFirstPage(page([row("d", 40), row("c", 30), row("b", 20), row("a", 10)], cursor: nil))  // simulate a loaded second page
        #expect(m.recent.map(\.id) == ["d", "c", "b", "a"])
        m.mergeFirstPage(page([row("e", 50), row("d", 40)], cursor: "c2"))
        #expect(m.recent.map(\.id) == ["e", "d", "c", "b", "a"])
    }

    @Test func rowsSharingTheBoundaryTimeFollowTheServersIdOrder() {
        let m = model()
        m.mergeFirstPage(page([row("d", 40), row("c", 30), row("b", 30), row("a", 10)], cursor: nil))
        // page one now ends at (30, "c"); "b" shares its time but comes after it in (start, id) order
        m.mergeFirstPage(page([row("e", 50), row("d", 40), row("c", 30)], cursor: "next"))
        #expect(m.recent.map(\.id) == ["e", "d", "c", "b", "a"])
    }

    @Test func aCompleteFirstPageReplacesTheList() {
        let m = model()
        m.mergeFirstPage(page([row("b", 20), row("a", 10)], cursor: nil))
        m.mergeFirstPage(page([row("c", 30)], cursor: nil))
        #expect(m.recent.map(\.id) == ["c"] && m.recentCursor == nil)
    }
}
