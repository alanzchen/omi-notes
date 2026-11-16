// ASTRA-20261116-IT1 review checks (reused; fixture root moved to a temporary directory).
import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol
@testable import OmiWatchKit

@Suite(.serialized) struct AstraWatchBuildChecks {
    let now = Date()
    func fixture() -> (OmiEngine, URL, SettingsStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-it1-20261116").appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "astra-watch-build-" + UUID().uuidString)!, tokens: InMemoryTokenStore())
        let engine = OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "0.1.0 (57)", timezone: "UTC", useCoreBluetooth: false), settings: settings, uploadTransport: CountingUploadTransport())
        return (engine, root, settings)
    }
    func report(_ e: OmiEngine, device: String, build: Int?, at: Date) {
        e.acceptWatchReport(WatchWire.encode(WatchReport(state: .idle, since: nil, waitingParts: 3, at: at, deviceId: device, stats: ["orphan_parts":0,"outstanding_stalled":3], appBuild: build)))
    }
    func perf(_ e: OmiEngine, _ root: URL, _ s: SettingsStore, device: String, build: Int, at: Date) throws {
        let q = WatchPerfQueue(root: root.appendingPathComponent("perf-" + UUID().uuidString))
        q.append(WatchPerfSample(id: UUID().uuidString.lowercased(), at: ISO8601UTC.format(at), monoS: 0, bootId: "b", launchId: "l", recordingId: "r", event: "stopped", state: "idle", battery: nil, batteryState: "unknown", counters: [:], gauges: [:], app: "0.1.0 (\(build))", os: "test", model: "test"), deviceId: device, binding: s.phoneInstallId!, seal: true)
        _ = try e.acceptWatchPerf(WatchWire.encode(try #require(q.batches().first)))
    }
    @Test func numericAndParsingControls() {
        #expect(WatchAppBuild.behind(watch: 99, phone: 100) == 99)
        #expect(WatchAppBuild.behind(watch: 100, phone: 99) == nil)
        #expect(WatchAppBuild.parse(app: "9.9.9 (49)") == 49)
        #expect(WatchAppBuild.parse(app: " 0.1.0 (49)") == 49)
        #expect(WatchAppBuild.parse(app: "0.1.0 (49) ") == nil)
        #expect(WatchAppBuild.parse(app: "0.1.0 ( 49 )") == nil)
        #expect(WatchAppBuild.parse(app: "0.1.0 49") == nil)
        #expect(WatchAppBuild.parse(app: "0.1.0 (9999999999999999999999999)") == nil)
    }
    @Test func laterDowngradeWinsAndDelayedSampleDoesNot() throws {
        let (e,r,s) = fixture()
        report(e,device:"A",build:58,at:now)
        try perf(e,r,s,device:"A",build:49,at:now.addingTimeInterval(-60))
        #expect(e.watchInbox.appBuild?.build == 58)
        report(e,device:"A",build:49,at:now.addingTimeInterval(60))
        #expect(e.watchInbox.appBuild?.build == 49)
        let reloaded = PhoneWatchInbox(root:r.appendingPathComponent("watch"),currentBinding:{s.phoneInstallId})
        #expect(reloaded.appBuild?.build == 49)
    }
    @Test func anotherWatchWithoutBuildMustNotInheritOldWatchBuild() throws {
        let (e,_,_) = fixture()
        report(e,device:"A",build:49,at:now)
        report(e,device:"B",build:nil,at:now.addingTimeInterval(60))
        #expect(e.watchInbox.latestReport?.deviceId == "B")
        #expect(e.snapshotNow().watchAppBuild == nil,"new Watch B has not supplied a build; A's 49 is not B's build")
    }
    @Test func otherWatchPerformanceCannotReplaceCurrentReportBuild() throws {
        let (e,r,s) = fixture()
        report(e,device:"B",build:58,at:now)
        try perf(e,r,s,device:"A",build:49,at:now.addingTimeInterval(60))
        #expect(e.snapshotNow().watchAppBuild?.build == 58,"late telemetry from A cannot describe the active Watch B")
    }
    @Test func futureTelemetryMustNotPinOldBuildAfterClockCorrects() throws {
        let (e,r,s) = fixture()
        try perf(e,r,s,device:"A",build:49,at:now.addingTimeInterval(86400))
        report(e,device:"A",build:57,at:now)
        #expect(e.snapshotNow().watchAppBuild?.build == 57,"future-dated old telemetry must not outrank current direct evidence forever")
    }
    @Test func telemetryFallbackMustAppearInReportLog() throws {
        let (e,r,s) = fixture()
        try perf(e,r,s,device:"A",build:49,at:now)
        report(e,device:"A",build:nil,at:now.addingTimeInterval(60))
        #expect(e.snapshotNow().watchAppBuild?.build == 49)
        let line = try #require(OmiLog.shared.recent().last { $0.message.hasPrefix("Watch idle,") })
        #expect(line.message.contains("build 49"),"learned fallback should appear in the uploaded diagnostic line: \(line.message)")
    }
    @Test func offActorReportAndPerfAcceptanceIsSafe() async throws {
        let (e,r,s) = fixture()
        try await Task.detached {
            try perf(e,r,s,device:"A",build:49,at:now)
            report(e,device:"A",build:57,at:now.addingTimeInterval(60))
        }.value
        #expect(e.snapshotNow().watchAppBuild?.build == 57)
    }

    @Test func exactOldReportDecoderIgnoresNewField() throws {
        let fresh = WatchReport(state: .idle, since: nil, waitingParts: 3, at: now, deviceId: "A", stats: ["orphan_parts":0], appBuild:57)
        let legacy = try #require(WatchWire.decode(LegacyBuild55WatchReport.self,WatchWire.encode(fresh)))
        #expect(legacy.waitingParts == 3 && legacy.deviceId == "A")
        let backward = try #require(WatchWire.decode(WatchReport.self,WatchWire.encode(legacy)))
        #expect(backward.appBuild == nil && backward.waitingParts == 3)
    }
}
