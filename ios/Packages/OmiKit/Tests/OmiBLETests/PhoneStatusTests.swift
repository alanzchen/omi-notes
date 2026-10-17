import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

/// Heartbeats exist only while a pendant is involved, so a Watch-only day said nothing about the
/// phone. `phone_status` reports the phone itself: its build, launch and outbox, with no pendant.
@Suite struct PhoneStatusTests {
    func engine(_ settings: SettingsStore, _ clock: TestClock, _ dir: URL) -> OmiEngine {
        OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: dir), clock: clock, appVersion: "0.1.0 (35)", timezone: "UTC",
                                              useCoreBluetooth: false),
                  settings: settings, uploadTransport: CountingUploadTransport())
    }

    func statuses(_ dir: URL) throws -> [[String: Any]] {
        try Outbox(dirs: CaptureDirectories(root: dir)).pending().filter { if case .event = $0.kind { return true } else { return false } }
            .compactMap { try JSONSerialization.jsonObject(with: Data(contentsOf: $0.url)) as? [String: Any] }
            .filter { $0["type"] as? String == "phone_status" }
    }

    func setup() -> (SettingsStore, TestClock, URL) {
        let defaults = UserDefaults(suiteName: "omi-phone-\(UUID().uuidString)")!
        return (SettingsStore(defaults: defaults, tokens: InMemoryTokenStore()), TestClock(),
                FileManager.default.temporaryDirectory.appendingPathComponent("omi-phone-\(UUID().uuidString)"))
    }

    @Test func withoutAPendantTheLaunchWritesTheBuildAndQueueUnderThePhonesOwnId() throws {
        let (settings, clock, dir) = setup()
        let e = engine(settings, clock, dir)
        e.queue.sync {}  // launch recovery ran
        let s = try statuses(dir)
        #expect(s.count == 1)
        let body = try #require(s.first), data = try #require(body["data"] as? [String: Any])
        #expect(body["device_id"] as? String == "phone-\(settings.phoneInstallId!)", "the phone's identity, never a pendant's")
        #expect(data["app_version"] as? String == "0.1.0 (35)" && data["trigger"] as? String == "launch")
        #expect(data["app_state"] as? String == "unknown", "no lifecycle callback yet: not assumed foreground")
        #expect(data["pendant_remembered"] as? Bool == false && (data["launch_id"] as? String)?.count == 36)
        #expect(data["outbox_pending"] as? Int == 0 && data["upload_paused"] as? Bool == false)
        #expect(try Outbox(dirs: CaptureDirectories(root: dir)).pending().allSatisfy { item in
            guard let o = try? JSONSerialization.jsonObject(with: Data(contentsOf: item.url)) as? [String: Any] else { return true }
            return o["type"] as? String != "heartbeat"
        }, "no pendant: still no heartbeat (pendant semantics unchanged)")
    }

    @Test func statusIsCoalescedToOnePerIntervalWithinALaunch() throws {
        let (settings, clock, dir) = setup()
        let e = engine(settings, clock, dir)
        e.queue.sync {}
        e.appDidBecomeActive()
        e.queue.sync {}
        #expect(try statuses(dir).count == 1, "within the interval: coalesced")
        clock.advance(601)
        e.appDidBecomeActive()
        e.queue.sync {}
        let s = try statuses(dir)
        #expect(s.count == 2)
        let triggers = s.compactMap { ($0["data"] as? [String: Any])?["trigger"] as? String }.sorted()
        #expect(triggers == ["foreground", "launch"])
        let launches = Set(s.compactMap { ($0["data"] as? [String: Any])?["launch_id"] as? String })
        #expect(launches.count == 1, "same process, same launch id")
        let fg = s.first { ($0["data"] as? [String: Any])?["trigger"] as? String == "foreground" }
        #expect((fg?["data"] as? [String: Any])?["app_state"] as? String == "foreground")
    }

    @Test func nothingIsSentWhileThePhonesIdentityIsUnreadable() throws {
        let (settings, clock, dir) = setup()
        settings.unlockedSinceBoot = false  // before the first unlock: no identity, and no stand-in
        let e = engine(settings, clock, dir)
        e.queue.sync {}
        #expect(try statuses(dir).isEmpty)
    }
}
