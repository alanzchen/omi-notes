import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

/// The pendant's own settings and Find: written over BLE, confirmed only by reading them back.
@Suite struct PendantControlsTests {
    static func cv1() -> [OmiCharacteristic: Data] {
        var v = FakeDeviceTransport.cv1Values()
        v[.ledDimRatio] = Data([50])
        v[.micGain] = Data([6])
        return v
    }

    final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

    @Test func connectReadsTheSettingsTheFeaturesAdvertise() throws {
        let h = SessionHarness(values: Self.cv1())
        h.connectFully()
        let info = h.session.info
        #expect(info.controlsKnown && info.settingsSupported == [.ledBrightness, .micGain] && info.canVibrate)
        #expect(info.settings == [.ledBrightness: 50, .micGain: 6])
        let calls = h.transport.calls
        #expect(try #require(calls.firstIndex(of: "read ledDimRatio")) > calls.firstIndex(of: "read storageStatus")!,
                "read after ready: offline sync is not held up")
    }

    @Test func aPendantWithoutTheFeatureBitsGetsNoControlsAndNoWrites() {
        var values = Self.cv1()
        values[.features] = withUnsafeBytes(of: UInt32(0x4C).littleEndian) { Data($0) }
        let h = SessionHarness(values: values)
        h.connectFully()
        #expect(h.session.info.controlsKnown && h.session.info.settingsSupported.isEmpty && !h.session.info.canVibrate)
        #expect(h.session.info.settings.isEmpty)
        let result = Box<Result<Int, Error>>()
        h.session.change(.ledBrightness, to: 10) { result.value = $0 }
        var vibrated: Error?
        h.session.vibrate(.long) { vibrated = $0 }
        #expect((try? result.value?.get()) == nil && (vibrated as? PendantControlError) == .unsupported)
        #expect(!h.transport.calls.contains { $0.hasPrefix("write ledDimRatio") || $0.hasPrefix("write haptic") })
    }

    @Test func aChangeIsWrittenThenReadBackAndAFailureKeepsWhatThePendantHas() throws {
        let h = SessionHarness(values: Self.cv1())
        h.connectFully()
        let ok = Box<Result<Int, Error>>()
        h.session.change(.ledBrightness, to: 30) { ok.value = $0 }
        #expect(try ok.value?.get() == 30 && h.session.info.settings[.ledBrightness] == 30)
        let tail = Array(h.transport.calls.suffix(2))
        #expect(tail == ["write ledDimRatio 1e", "read ledDimRatio"])

        h.transport.writeErrors[.micGain] = SessionError.timeout       // the pendant rejects it
        let failed = Box<Result<Int, Error>>()
        h.session.change(.micGain, to: 2) { failed.value = $0 }
        #expect((try? failed.value?.get()) == nil)
        #expect(h.session.info.settings[.micGain] == 6, "still what the pendant reports, not the requested 2")
        #expect(h.transport.calls.last == "read micGain")

        // a readback that fails: the value is unknown, not assumed
        h.transport.failReads = [.ledDimRatio]
        let unconfirmed = Box<Result<Int, Error>>()
        h.session.change(.ledBrightness, to: 70) { unconfirmed.value = $0 }
        #expect((try? unconfirmed.value?.get()) == nil && h.session.info.settings[.ledBrightness] == nil)
    }

    @Test func aChangeInFlightWhenTheLinkDropsFailsAndTheNextConnectionReadsThePendantAgain() throws {
        let h = SessionHarness(values: Self.cv1())
        h.connectFully()
        h.transport.unanswered = [.ledDimRatio]
        let r = Box<Result<Int, Error>>()
        h.session.change(.ledBrightness, to: 0) { r.value = $0 }
        h.session.end(reason: .bleDisconnected)
        #expect((try? r.value?.get()) == nil)
        #expect(h.session.info.settings[.ledBrightness] == nil, "unknown (the write may or may not have landed), never shown as 0")
        let after = Box<Result<Int, Error>>()
        h.session.change(.ledBrightness, to: 0) { after.value = $0 }
        if case .failure(let e)? = after.value { #expect((e as? PendantControlError) == .notConnected) } else { Issue.record("no failure") }

        // reconnect: a new session reads the value the pendant kept
        var device = h.transport.values
        device[.ledDimRatio] = Data([20])
        let again = SessionHarness(values: device)
        again.connectFully()
        #expect(again.session.info.settings[.ledBrightness] == 20)
    }
}

/// The real engine path with the simulated pendant: changes, Find, reconnect, failure, button choices.
@Suite(.serialized) struct EnginePendantControlsTests {
    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func result<T: Sendable>(_ start: (@escaping @Sendable (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { k in start { k.resume(returning: $0) } }
    }

    @Test func settingsFindReconnectFailureAndButtonChoices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-controls-\(UUID().uuidString)")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-controls-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.tail1234.ts.net")!, token: "tok-controls")
        let engine = OmiEngine(
            config: EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "test", timezone: "UTC",
                                        simulatedTrace: SimulatedTrace.synthetic(seconds: 3), useCoreBluetooth: false, tickInterval: 0.2),
            settings: settings, uploadTransport: CountingUploadTransport())
        defer { engine.setSimulatedMode(false) }
        let notYet: Result<Int, Error> = await result { engine.changePendantSetting(.ledBrightness, to: 10, completion: $0) }
        #expect((try? notYet.get()) == nil, "nothing connected: nothing is claimed")

        engine.setSimulatedMode(true)
        #expect(await waitFor(10) { engine.snapshotNow().device?.settings[.micGain] == 6 })

        let changed: Result<Int, Error> = await result { engine.changePendantSetting(.ledBrightness, to: 25, completion: $0) }
        #expect(try changed.get() == 25)
        let found: Error? = await result { engine.findPendant(completion: $0) }
        #expect(found == nil)
        #expect(engine.queue.sync { engine.simulated?.vibrations } == [3, 3, 3])

        // the setting lives on the pendant: after the link drops and returns it is read back from it
        engine.simulateOutOfRange(returnAfter: 1)
        #expect(await waitFor(10) { engine.snapshotNow().connection != .streaming })
        #expect(await waitFor(10) { engine.snapshotNow().connection == .streaming && engine.snapshotNow().device?.settings[.ledBrightness] == 25 })

        // a pendant that rejects the write: an error, and the shown value is still the pendant's
        engine.queue.sync { engine.simulated?.failControlWrites = true }
        let rejected: Result<Int, Error> = await result { engine.changePendantSetting(.micGain, to: 1, completion: $0) }
        #expect((try? rejected.get()) == nil)
        #expect(await waitFor(2) { engine.snapshotNow().device?.settings[.micGain] == 6 })

        // button choices (this phone's): off ignores the button; double tap can bookmark instead
        let outbox = Outbox(dirs: CaptureDirectories(root: root))
        func buttonCodes() -> [Int] {
            (outbox.pending() + outbox.sent()).filter { if case .event = $0.kind { return true } else { return false } }
                .compactMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: $0.url)) as? [String: Any] }
                .filter { $0["type"] as? String == "button" }
                .compactMap { ($0["data"] as? [String: Any])?["code"] as? Int }
        }
        settings.buttonActionsEnabled = false
        engine.simulateButton(code: 2)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(buttonCodes().isEmpty)
        settings.buttonActionsEnabled = true
        settings.doubleTapAction = .bookmark
        engine.simulateButton(code: 2)
        #expect(await waitFor(2) { buttonCodes() == [1] })
    }
}
