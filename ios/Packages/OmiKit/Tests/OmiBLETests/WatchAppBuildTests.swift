import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol
@testable import OmiWatchKit

/// The Watch app's build as the iPhone learns it (status report, or an older Watch's performance samples) and
/// the Apple Watch page's line when it is behind this iPhone's. SYNTHETIC values.
@Suite(.serialized) struct WatchAppBuildTests {
    @Test func aReportDecodesWithAndWithoutTheBuild() throws {
        // what a Watch app before this field sends (keys as `WatchWire.encode` writes them)
        let old = Data(#"{"at":1791000000000,"deviceId":"watch-1","state":"idle","waitingParts":3,"stats":{"outstanding_stalled":3}}"#.utf8)
        let decoded = try #require(WatchWire.decode(WatchReport.self, old))
        #expect(decoded.appBuild == nil && decoded.waitingParts == 3, "missing is unknown")
        let now = WatchReport(state: .idle, since: nil, waitingParts: 0, at: Date(timeIntervalSince1970: 1_791_000_000), appBuild: 57)
        let body = try #require(JSONSerialization.jsonObject(with: WatchWire.encode(now)) as? [String: Any])
        #expect(body["appBuild"] as? Int == 57)
        #expect(WatchWire.decode(WatchReport.self, WatchWire.encode(now))?.appBuild == 57)
    }

    @Test func theLineShowsOnlyForAnOlderKnownBuild() {
        #expect(WatchAppBuild.outdatedLine(watch: 49, phone: 56) == "手表上的 Omi 不是最新版本（49）· 在手表上更新")
        #expect(WatchAppBuild.outdatedLine(watch: 56, phone: 56) == nil, "same build")
        #expect(WatchAppBuild.outdatedLine(watch: 57, phone: 56) == nil, "the Watch is newer")
        #expect(WatchAppBuild.outdatedLine(watch: nil, phone: 56) == nil, "unknown: never called up to date or out of date")
        #expect(WatchAppBuild.outdatedLine(watch: 49, phone: nil) == nil)
    }

    @Test func aPerformanceSampleNamesTheBuild() {
        #expect(WatchAppBuild.parse(app: "0.1.0 (49)") == 49)
        #expect(WatchAppBuild.parse(app: "0.1.0 (?)") == nil)
        #expect(WatchAppBuild.parse(app: "t") == nil)
    }

    @Test func thePhoneKeepsTheNewestObservationFromEitherSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omi-build-\(UUID().uuidString)")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-build-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        let engine = OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: dir), appVersion: "0.1.0 (56)", timezone: "UTC", useCoreBluetooth: false),
                               settings: settings, uploadTransport: CountingUploadTransport())
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        // an older Watch app: no build in its report, so nothing is known yet
        engine.acceptWatchReport(WatchWire.encode(WatchReport(state: .idle, since: nil, waitingParts: 3, at: t0, deviceId: "watch-1", stats: ["orphan_parts": 0])))
        #expect(engine.watchInbox.appBuild == nil)
        // its performance samples say "0.1.0 (49)"
        let q = WatchPerfQueue(root: dir.appendingPathComponent("w"))
        q.append(WatchPerfSample(id: UUID().uuidString.lowercased(), at: ISO8601UTC.format(t0.addingTimeInterval(60)), monoS: 0, bootId: "b", launchId: "l",
                                 recordingId: "r", event: "stopped", state: "idle", battery: nil, batteryState: "unknown", counters: [:], gauges: [:],
                                 app: "0.1.0 (49)", os: "t", model: "t"),
                 deviceId: "watch-1", binding: settings.phoneInstallId!, seal: true)
        _ = try engine.acceptWatchPerf(WatchWire.encode(try #require(q.batches().first)))
        #expect(engine.watchInbox.appBuild?.build == 49 && engine.watchInbox.appBuild?.source == .telemetry && engine.watchInbox.appBuild?.at == t0.addingTimeInterval(60))
        // the updated Watch app reports its build
        engine.acceptWatchReport(WatchWire.encode(WatchReport(state: .idle, since: nil, waitingParts: 0, at: t0.addingTimeInterval(120), deviceId: "watch-1", appBuild: 57)))
        #expect(engine.watchInbox.appBuild?.build == 57)
        // an observation older than the stored one doesn't replace it
        engine.acceptWatchReport(WatchWire.encode(WatchReport(state: .idle, since: nil, waitingParts: 0, at: t0.addingTimeInterval(90), deviceId: "watch-1", appBuild: 49)))
        #expect(engine.watchInbox.appBuild?.build == 57)
        // a report without a Watch id names no Watch: its build isn't kept
        engine.acceptWatchReport(WatchWire.encode(WatchReport(state: .idle, since: nil, waitingParts: 0, at: t0.addingTimeInterval(200), appBuild: 40)))
        #expect(engine.watchInbox.appBuild == nil && engine.watchInbox.appBuild(for: "watch-1")?.build == 57)
    }

    @Test func theLogSaysWhereTheBuildCameFrom() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let old = WatchReport(state: .idle, since: nil, waitingParts: 3, at: now, deviceId: "w")
        let known = WatchAppBuild(build: 49, at: now, deviceId: "w", source: .telemetry, receivedAt: now.addingTimeInterval(-2 * 3600))
        #expect(OmiEngine.buildText(old, known, now: now) == "build 49 (last known, telemetry, 2h ago)")
        #expect(OmiEngine.buildText(old, nil, now: now) == "build ?")
        var current = old
        current.appBuild = 57
        #expect(OmiEngine.buildText(current, known, now: now) == "build 57", "the report's own")
    }
}
