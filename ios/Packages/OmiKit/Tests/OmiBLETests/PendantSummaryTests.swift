import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol

@Suite struct PendantSummaryTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func streaming(battery: Int? = 82, charging: Bool? = false) -> EngineSnapshot {
        var s = EngineSnapshot()
        s.connection = .streaming
        s.serverConfigured = true
        s.rememberedDeviceId = "dev"
        s.rememberedDeviceName = "Omi"
        var d = DeviceSession.Info()
        d.battery = battery
        d.charging = charging
        s.device = d
        var live = LiveSnapshot()
        live.lastNotificationAt = now.addingTimeInterval(-12)
        s.live = live
        s.upload.lastSuccessAt = now.addingTimeInterval(-60)
        return s
    }

    func status(pending: Int = 0, lastNote: String? = "2026-09-21T12:00:00.000Z") throws -> ServerStatus {
        let body: [String: Any] = [
            "queue": ["chunks_pending": 0, "conversations_open": 0, "conversations_pending": pending, "failed": 0,
                      "conversations_failed": 0, "chunks_failed": 0],
            "worker": ["present": true], "last_note_at": lastNote ?? NSNull(), "features": ["issues"],
        ]
        return try JSONDecoder().decode(ServerStatus.self, from: JSONSerialization.data(withJSONObject: body))
    }

    let reachable = ServerReachability.reachable(version: "0.1.0", detail: "")

    func summary(_ s: EngineSnapshot, _ reach: ServerReachability, _ st: ServerStatus?, age: TimeInterval = 10) -> PendantSummary {
        PendantSummary.evaluate(snapshot: s, server: reach, status: st, statusAt: st == nil ? nil : now.addingTimeInterval(-age), now: now)
    }

    @Test func thePhonesChoicesAreSaidWithAWayBack() throws {
        var s = streaming()
        s.recordingPaused = true
        s.device?.audioPaused = true
        s.device?.offlineHeld = true
        s.device?.offlineUnread = 3
        s.doubleTapAction = .starConversation
        let p = summary(s, reachable, try status())
        #expect(p.stateLine == "Connected · recording paused" && p.headline.title == "Recording paused")
        #expect(p.rows.contains { $0.title == "Recording paused" && $0.fix == .resumeRecording })
        #expect(p.rows.contains { $0.title == "3 records waiting on the pendant" && $0.fix == .collectPendantAudio })
        #expect(p.rows.contains { $0.detail == "Double-tap to star the conversation" })
        s.buttonActionsEnabled = false
        #expect(summary(s, reachable, try status()).rows.contains { $0.title == "Button actions are off" })
    }

    @Test func normalShowsBatteryAndObservedFactsOnly() throws {
        let p = summary(streaming(), reachable, try status(pending: 1))
        #expect(p.connected && p.connectionTitle == "Connected · recording")
        #expect(p.battery == .level(percent: 82, charging: false, low: false))
        #expect(p.headline.level == .normal && p.headline.title == "Connected and recording" && p.also.isEmpty)
        #expect(p.flow.map(\.title) == ["Receiving audio", "No files waiting", "Reachable"])
        #expect(p.flow[0].detail == "Last packet just now")  // a packet arrived; nothing claims sound or speech
        #expect(p.flow[2].detail?.hasPrefix("Last successful upload") == true)
        #expect(p.notes?.processing == 1 && p.notes?.stale == false)
    }

    @Test func unknownBatteryIsNeverZero() {
        var waiting = streaming(battery: 40)
        waiting.connection = .waitingForDevice
        waiting.device = nil
        #expect(summary(waiting, reachable, nil).battery == .unknown(reason: "Not connected"))
        #expect(summary(streaming(battery: nil), reachable, nil).battery == .unknown(reason: "Not reported yet"))
        var stale = streaming(battery: 40)
        stale.connection = .waitingForDevice  // a leftover session must not look live
        #expect(summary(stale, reachable, nil).battery == .unknown(reason: "Not connected"))
        #expect(summary(EngineSnapshot(), .notConfigured, nil).battery == .unknown(reason: "No pendant"))
    }

    @Test func lowBatteryFollowsTheHealthRuleAndChargingIsNotLow() {
        #expect(summary(streaming(battery: 12), reachable, nil).battery == .level(percent: 12, charging: false, low: true))
        #expect(summary(streaming(battery: 12, charging: true), reachable, nil).battery == .level(percent: 12, charging: true, low: false))
        #expect(summary(streaming(battery: 16), reachable, nil).battery == .level(percent: 16, charging: false, low: false))
    }

    @Test func disconnectedIsUnknownWithoutAFakeAction() {
        var s = streaming()
        s.connection = .waitingForDevice
        s.device = nil
        s.live = nil
        let p = summary(s, reachable, nil)
        #expect(!p.connected && p.connectionTitle == "Not connected")
        #expect(p.headline.area == .pendant && p.headline.level == .unknown && p.headline.fix == nil)
        #expect(p.flow[0].level == .unknown)
    }

    @Test func unpairedAsksToPair() {
        let p = summary(EngineSnapshot(), .notConfigured, nil)
        #expect(p.headline.level == .needsAction && p.headline.fix == .pairDevice)
        #expect(p.flow[0].title == "Not paired" && p.flow[2].title == "Not connected")
    }

    @Test func blockedUploadLeadsAndLowBatteryIsStillListed() {
        var s = streaming(battery: 12)
        s.outbox.pendingCount = 38
        let p = summary(s, .unreachable("offline"), nil)
        #expect(p.headline.area == .phone && p.headline.fix == .retryUploads)
        #expect(p.also.map(\.area) == [.pendant] && p.also[0].title.contains("battery is low"))
        #expect(p.flow[1].title == "38 files waiting" && p.flow[1].detail == "Stored here, not uploaded yet")
        // a past success is shown as such, never as "reachable" or "all uploaded"
        #expect(p.flow[2].title == "Can't reach" && p.flow[2].detail?.hasPrefix("Last successful upload") == true)
    }

    @Test func quarantineAndFullStorageNeedAction() {
        var q = streaming()
        q.outbox.quarantineCount = 2
        #expect(summary(q, reachable, nil).flow[1].level == .needsAction)
        var full = streaming()
        full.storageTripped = true
        full.connection = .paused("phone storage low")
        let p = summary(full, reachable, nil)
        #expect(p.flow[1].title == "Storage full" && p.headline.level == .needsAction)
    }

    @Test func staleServerAnswersAreMarkedNotCurrent() throws {
        let p = summary(streaming(), reachable, try status(pending: 0), age: 3600)
        #expect(p.flow[2].level == .unknown && p.flow[2].title.hasPrefix("Last checked"))
        #expect(p.notes?.stale == true && p.notes?.processing == 0)
    }

    @Test func lowBatteryIsSaidEvenWhilePendantAudioIsCollected() {
        var s = streaming(battery: 12)
        s.offline = .receiving(received: 68, total: 241)  // SystemHealth's pendant step reports this instead
        s.outbox.pendingCount = 38
        let p = summary(s, .unreachable("offline"), nil)
        #expect(p.headline.area == .phone)
        #expect(p.also.count == 1 && p.also[0].title == "Pendant battery is low (12%)")
    }

    @Test func pendantStorageCollectionIsReportedInRecords() {
        var s = streaming()
        s.offline = .receiving(received: 68, total: 241)
        let p = summary(s, reachable, nil)
        #expect(p.collecting?.received == 68 && p.collecting?.total == 241)
    }

    @Test func recordingNeedsRecentAudioNotJustAConnection() {
        #expect(summary(streaming(), reachable, nil).stateLine == "Recording · audio received just now")
        var quiet = streaming()
        quiet.live?.lastNotificationAt = now.addingTimeInterval(-300)
        #expect(summary(quiet, reachable, nil).stateLine.hasPrefix("Connected · last audio"))
        var none = streaming()
        none.live = nil
        #expect(summary(none, reachable, nil).stateLine == "Connected · no audio yet")
        var asleep = streaming()
        asleep.device?.noAudioYet = true
        #expect(summary(asleep, reachable, nil).stateLine == "Connected · no audio yet")
        var away = streaming()
        away.connection = .waitingForDevice
        #expect(summary(away, reachable, nil).stateLine.hasPrefix("Not connected"))
    }

    @Test func pendantStorageIsOnlyClaimedFromThisSessionsSync() {
        var s = streaming()
        #expect(summary(s, reachable, nil).storage == nil)  // never synced: say nothing
        s.offline = .complete(records: 0)
        #expect(summary(s, reachable, nil).storage == .collected(records: 0))
        s.offline = .interrupted("link lost")
        #expect(summary(s, reachable, nil).storage == .stopped("link lost"))
        s.offline = .complete(records: 5)
        s.connection = .waitingForDevice  // an earlier session's result is not current
        #expect(summary(s, reachable, nil).storage == nil)
    }

    @Test func batteryToneBands() {
        #expect(PendantSummary.Battery.level(percent: 82, charging: false, low: false).tone == .healthy)
        #expect(PendantSummary.Battery.level(percent: 41, charging: false, low: false).tone == .healthy)
        #expect(PendantSummary.Battery.level(percent: 40, charging: false, low: false).tone == .middle)
        #expect(summary(streaming(battery: 15), reachable, nil).battery.tone == .low)
        #expect(summary(streaming(battery: 12, charging: true), reachable, nil).battery.tone == .middle)  // charging: never low
        #expect(PendantSummary.Battery.unknown(reason: "Not connected").tone == .unknown)
    }

    @Test func cardRowsSayOnlyWhatIsObserved() {
        let normal = summary(streaming(), reachable, nil)
        #expect(normal.rows.map(\.title) == ["Nothing waiting on this iPhone", "Tap once to bookmark"])
        #expect(normal.rows[0].detail == "Last upload 1 minute ago" && !normal.rows[0].attention)

        var blocked = streaming(battery: 12)
        blocked.outbox.pendingCount = 38
        blocked.offline = .receiving(received: 68, total: 241)
        let b = summary(blocked, .unreachable("offline"), nil)
        #expect(b.rows.map(\.kind) == [.phone, .storage, .gestures])  // low battery is on the ring, not a row
        #expect(b.rows[0].title == "38 files waiting on iPhone" && b.rows[0].attention && b.rows[0].fix == .retryUploads)
        #expect(b.rows[1].progress != nil)

        var away = streaming()
        away.connection = .waitingForDevice
        away.device = nil
        #expect(summary(away, reachable, nil).rows.first?.title == "Looking for your pendant")

        let unpaired = summary(EngineSnapshot(), .notConfigured, nil)
        #expect(unpaired.rows.map(\.title) == ["Pair your pendant", "No server connected"])
        #expect(unpaired.rows[0].fix == .pairDevice)
    }
}
