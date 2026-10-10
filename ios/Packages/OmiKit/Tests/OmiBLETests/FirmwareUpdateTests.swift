import CryptoKit
import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
@testable import OmiProtocol

/// A small CV1-shaped package (MCUboot images signed "with" the CV1 key hash, in a stored zip).
enum UpdateFixture {
    static func image(size: Int, seed: UInt8) -> Data {
        var d = Data()
        func le16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func le32(_ v: Int) { le16(v & 0xffff); le16(v >> 16 & 0xffff) }
        le32(Int(MCUbootImage.magic)); le32(0); le16(32); le16(0); le32(size); le32(0); le32(0); le32(0); le32(0)
        d.append(contentsOf: (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ Int(seed)) })
        let tlvs = Data([1, 0, 32, 0]) + FirmwarePackage.cv1KeyHash + Data([0x10, 0, 32, 0]) + Data(SHA256.hash(data: d))
        le16(0x6907); le16(4 + tlvs.count)
        return d + tlvs
    }

    static func package() throws -> FirmwarePackage {
        let app = image(size: 3000, seed: 1), net = image(size: 1500, seed: 2)
        let manifest = Data(#"{"files":[{"board":"omi","soc":"nrf5340","image_index":"0","size":\#(app.count),"file":"omi.signed.bin"},{"board":"omi/nrf5340/cpunet","soc":"nrf5340","image_index":"1","size":\#(net.count),"file":"ipc_radio.bin"}]}"#.utf8)
        var out = Data(), dir = Data()
        func le16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func le32(_ v: Int, _ d: inout Data) { le16(v & 0xffff, &d); le16(v >> 16 & 0xffff, &d) }
        let files = [("manifest.json", manifest), ("omi.signed.bin", app), ("ipc_radio.bin", net)]
        for (name, c) in files {
            let off = out.count, crc = Int(CRC32.checksum(c)), n = Data(name.utf8)
            le32(0x04034b50, &out); for _ in 0..<5 { le16(0, &out) }; le32(crc, &out); le32(c.count, &out); le32(c.count, &out); le16(n.count, &out); le16(0, &out); out.append(n); out.append(c)
            le32(0x02014b50, &dir); for _ in 0..<6 { le16(0, &dir) }; le32(crc, &dir); le32(c.count, &dir); le32(c.count, &dir); le16(n.count, &dir); for _ in 0..<4 { le16(0, &dir) }; le32(0, &dir); le32(off, &dir); dir.append(n)
        }
        let at = out.count
        out.append(dir); le32(0x06054b50, &out); le16(0, &out); le16(0, &out); le16(files.count, &out); le16(files.count, &out); le32(dir.count, &out); le32(at, &out); le16(0, &out)
        return try FirmwarePackage(zip: out)
    }
}

/// The update flow end to end over the simulated pendant's MCUmgr: real engine, session and SMP.
@Suite(.serialized) struct FirmwareUpdateTests {
    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @Test func installVerifyRefuseMismatchAndPreconditions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-fw-\(UUID().uuidString)")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-fw-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.tail1234.ts.net")!, token: "tok-fw")
        let engine = OmiEngine(
            config: EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "test", timezone: "UTC",
                                        simulatedTrace: SimulatedTrace.synthetic(seconds: 3), useCoreBluetooth: false, tickInterval: 0.2),
            settings: settings, uploadTransport: CountingUploadTransport())
        defer { engine.setSimulatedMode(false) }
        let package = try UpdateFixture.package()
        #expect(engine.firmwareUpdateBlocker() == "Connect the pendant first.")

        engine.setSimulatedMode(true)
        let ready = { engine.snapshotNow().connection == .streaming && engine.snapshotNow().device?.battery != nil
            && engine.snapshotNow().offline != .idle && !engine.snapshotNow().offline.isActiveForTest }
        #expect(await waitFor(15, ready))
        #expect(engine.firmwareUpdateBlocker() == nil)

        // 1. a good update: uploaded, checked, marked, restarted, and the new version is read back
        engine.configureSimulatedPendant { $0.firmwareAfterUpdate = "3.0.22" }
        engine.installFirmware(package, version: "3.0.22")
        #expect(await waitFor(20) { engine.snapshotNow().firmware == .done(version: "3.0.22") }, "\(engine.snapshotNow().firmware)")
        #expect(engine.snapshotNow().device?.firmwareRevision == "3.0.22")
        #expect(await waitFor(5) { engine.snapshotNow().device?.audioPaused == false }, "recording is back after the update")
        engine.clearFirmwareResult()
        #expect(await waitFor(15, ready))

        // 2. the pendant refuses the upload: failed, nothing marked to install, recording back on
        engine.configureSimulatedPendant { $0.refuseFirmwareUpload = true }
        engine.installFirmware(package, version: "3.0.23")
        #expect(await waitFor(10) { if case .failed(let why) = engine.snapshotNow().firmware { return why.contains("refused") } else { return false } })
        #expect(engine.queue.sync { engine.simulated?.markedForInstall.isEmpty } == true)
        #expect(await waitFor(5) { engine.snapshotNow().device?.audioPaused == false })
        #expect(engine.snapshotNow().device?.firmwareRevision == "3.0.22")

        // 3. it restarts but reports another version: a failure, never "done"
        engine.configureSimulatedPendant { $0.refuseFirmwareUpload = false; $0.firmwareAfterUpdate = nil }
        engine.installFirmware(package, version: "3.0.23")
        #expect(await waitFor(20) { if case .failed(let why) = engine.snapshotNow().firmware { return why.contains("reports firmware 3.0.22") } else { return false } },
                "\(engine.snapshotNow().firmware)")
        #expect(await waitFor(15, ready))

        // 4. the link drops mid-upload: nothing installed, said so; recording back on reconnect
        engine.configureSimulatedPendant { $0.dropLinkDuringUpload = true }
        engine.installFirmware(package, version: "3.0.23")
        #expect(await waitFor(10) { engine.snapshotNow().firmware == .failed("the connection dropped during the update; nothing was installed") },
                "\(engine.snapshotNow().firmware)")
        #expect(await waitFor(15) { ready() && engine.snapshotNow().device?.audioPaused == false && engine.snapshotNow().device?.firmwareRevision == "3.0.22" })

        // 5. a low battery (not charging) blocks it before anything is sent
        engine.configureSimulatedPendant { $0.battery = 10 }
        engine.simulateOutOfRange(returnAfter: 1)
        #expect(await waitFor(15) { ready() && engine.snapshotNow().device?.battery == 10 })
        #expect(engine.firmwareUpdateBlocker() == "Charge the pendant to at least 15% first.")
        let before = engine.queue.sync { engine.simulated?.uploaded }
        engine.installFirmware(package, version: "3.0.23")
        #expect(await waitFor(5) { engine.snapshotNow().firmware == .failed("Charge the pendant to at least 15% first.") })
        #expect(engine.queue.sync { engine.simulated?.uploaded } == before, "nothing was sent")
    }
}

extension RingSyncState {
    var isActiveForTest: Bool {
        switch self {
        case .idle, .complete, .failed, .interrupted, .unsupported: return false
        default: return true
        }
    }
}
