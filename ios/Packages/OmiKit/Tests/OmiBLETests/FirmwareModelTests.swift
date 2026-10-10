import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
@testable import OmiProtocol

@MainActor
@Suite struct FirmwareModelTests {
    final class Feed: @unchecked Sendable {
        var answers: [String: (Data, Int)] = [:]
        var asked: [URL] = []
        func fetch(_ url: URL) -> (Data, Int) {
            asked.append(url)
            return answers.first { url.absoluteString.contains($0.key) }?.value ?? (Data(), 404)
        }
    }

    func cv1(_ firmware: String) -> DeviceSession.Info {
        var d = DeviceSession.Info()
        d.modelNumber = "Omi CV 1"
        d.firmwareRevision = firmware
        d.hardwareRevision = "5.0"
        d.manufacturer = "Based Hardware"
        return d
    }

    func engine() -> OmiEngine {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-fwm-\(UUID().uuidString)")
        return OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false),
                         settings: SettingsStore(defaults: UserDefaults(suiteName: "omi-fwm-\(UUID().uuidString)")!, tokens: InMemoryTokenStore()),
                         uploadTransport: CountingUploadTransport())
    }

    @Test func upToDateAvailableAndNothingDownloadedUnlessItCanBeInstalled() async throws {
        let feed = Feed()
        feed.answers["stable"] = (FirmwareReleaseTestsData.answer, 200)
        let model = FirmwareModel(engine: engine(), fetch: { feed.fetch($0) })
        await model.checkForUpdate(cv1("3.0.21"))
        #expect(model.check == .upToDate("3.0.21") && model.stable?.version == "3.0.21", "the backend's 404 means up to date")

        feed.answers["latest"] = (FirmwareReleaseTestsData.answer, 200)
        await model.checkForUpdate(cv1("3.0.20"))
        guard case .available(let r) = model.check else { Issue.record("\(model.check)"); return }
        #expect(r.version == "3.0.21")

        var foreign = r
        foreign.zipURL = URL(string: "https://example.com/x.zip")!
        await model.install(foreign, current: "3.0.20")
        #expect(model.prepare == .failed("Can't install 3.0.21: its download isn't the official Omi release."))
        await model.install(r, current: "3.0.20")
        #expect(model.prepare == .failed("Connect the pendant first."))
        #expect(!feed.asked.contains { $0.pathExtension == "zip" }, "nothing downloaded or sent")
    }
}

/// The backend's real answer (as in OmiProtocolTests).
enum FirmwareReleaseTestsData {
    static let answer = Data(#"{"version":"3.0.21","min_version":"3.0.6","zip_url":"https://github.com/BasedHardware/omi/releases/download/Omi_CV1_v3.0.21/Omi_CV1_OTA_v3.0.21.zip","is_legacy_secure_dfu":false,"changelog":["fix audio sync issue"]}"#.utf8)
}
