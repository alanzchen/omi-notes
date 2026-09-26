import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

/// Regression tests for the iOS code review (`/tmp/review_ios.md`), BLE / engine side.
@Suite struct SessionReviewRegressionTests {
    func seals(_ h: SessionHarness) -> [SealBody] {
        h.outbox.pending().filter { if case .seal = $0.kind { return true } else { return false } }
            .compactMap { try? JSONDecoder().decode(SealBody.self, from: Data(contentsOf: $0.url)) }
    }

    func chunks(_ h: SessionHarness) -> [EnvelopeHeader] {
        h.outbox.pending().filter(\.kind.isChunk).compactMap { try? Envelope.parse(Data(contentsOf: $0.url)).header }
    }

    // MARK: #5 — losing the audio subscription ends coverage

    @Test func subscriptionLossSealsCaptureAndResubscribes() throws {
        let h = SessionHarness()
        h.connectFully()
        for i in 0..<3 { h.transport.audio(Data([UInt8(i), 0, 0, 0xB8])); h.clock.advance(0.02) }
        let firstCapture = try #require(h.session.recorder.captureId)
        h.clock.advance(2)
        h.transport.delegate?.transport(h.transport, didUpdateNotificationStateFor: .audioData, enabled: false, error: nil)
        #expect(!h.session.recorder.isActive, "no coverage while unsubscribed")
        let seal = try #require(seals(h).first)
        #expect(seal.reason == .bleDisconnected)
        let last = try #require(chunks(h).filter { $0.captureId == firstCapture }.max { $0.chunkSequence < $1.chunkSequence })
        #expect(seal.endOffsetUs == last.chunkEndOffsetUs)
        #expect(last.chunkEndOffsetUs <= 2_100_000, "coverage stops at the loss, not later")
        #expect(h.transport.calls.filter { $0 == "notify audioData true" }.count == 2, "re-subscribe requested")
        // 3 minutes pass without the subscription: no chunk may claim that time.
        h.clock.advance(180)
        h.session.tick()
        #expect(chunks(h).allSatisfy { $0.captureId == firstCapture })
        h.transport.confirmAudioSubscription()
        #expect(h.session.recorder.isActive)
        #expect(h.session.recorder.captureId != firstCapture, "a new capture starts at the re-subscription")
        h.transport.audio(Data([9, 0, 0, 0xB8]))
        h.clock.advance(1)
        h.session.end(reason: .bleDisconnected)
        let newChunk = try #require(h.outbox.pending().first { $0.kind.isChunk && $0.kind.captureId != firstCapture })
        let parsed = try Envelope.parse(Data(contentsOf: newChunk.url))
        #expect(BLERecord.scan(parsed.payload).records.first?.isSessionStart == true)
    }

    /// Verification #4: a not-notifying callback that also carries an error must end coverage too.
    @Test func subscriptionLossWithErrorEndsCoverage() throws {
        let h = SessionHarness()
        h.connectFully()
        for i in 0..<3 { h.transport.audio(Data([UInt8(i), 0, 0, 0xB8])); h.clock.advance(0.02) }
        let firstCapture = try #require(h.session.recorder.captureId)
        h.clock.advance(2)
        struct Lost: Error {}
        h.transport.delegate?.transport(h.transport, didUpdateNotificationStateFor: .audioData, enabled: false, error: Lost())
        #expect(!h.session.recorder.isActive, "no coverage while unsubscribed, even on the error path")
        #expect(try #require(seals(h).first).reason == .bleDisconnected)
        #expect(h.transport.calls.filter { $0 == "notify audioData true" }.count == 2, "bounded re-subscribe requested")
        h.clock.advance(180)
        h.session.tick()
        #expect(chunks(h).allSatisfy { $0.captureId == firstCapture })
        #expect(chunks(h).allSatisfy { $0.chunkEndOffsetUs <= 2_100_000 }, "no chunk claims the unsubscribed time")
    }

    @Test func subscriptionThatCannotBeRestoredReconnects() {
        let h = SessionHarness()
        h.connectFully()
        h.transport.delegate?.transport(h.transport, didUpdateNotificationStateFor: .audioData, enabled: false, error: nil)
        for _ in 0..<4 {
            h.clock.advance(11)
            h.session.tick()
        }
        #expect(h.delegate.reconnectRequests.count == 1)
    }

    // MARK: #7 — setup deadlines

    @Test func discoveryThatNeverCompletesRetriesThenReconnects() {
        let h = SessionHarness()
        h.session.start()
        h.clock.advance(16)
        h.session.tick()
        #expect(h.transport.calls.filter { $0 == "discover" }.count == 2)
        #expect(h.delegate.reconnectRequests.isEmpty)
        h.clock.advance(16)
        h.session.tick()
        #expect(h.delegate.reconnectRequests == ["service discovery timed out"])
    }

    @Test func subscriptionThatIsNeverConfirmedRetriesThenReconnects() {
        let h = SessionHarness()
        h.session.start()
        h.transport.delegate?.transport(h.transport, didDiscover: Set(OmiCharacteristic.allCases), complete: true)
        for _ in 0..<2 {
            h.clock.advance(11)
            h.session.tick()
        }
        #expect(h.transport.calls.filter { $0 == "notify audioData true" }.count == 3)
        #expect(h.delegate.reconnectRequests.isEmpty)
        h.clock.advance(11)
        h.session.tick()
        #expect(h.delegate.reconnectRequests == ["audio subscription not confirmed"])
        h.clock.advance(120)
        h.session.tick()
        #expect(h.delegate.reconnectRequests.count == 1, "requested once")
    }

    // MARK: #6 — unreadable DIS/features → unknown, retried

    @Test func unreadableFirmwareIsUnknownAndRetried() throws {
        var values = FakeDeviceTransport.cv1Values()
        values[.firmwareRevision] = nil  // DIS read times out once
        let h = SessionHarness(values: values)
        h.connectFully()
        #expect(h.session.info.offlineSupport == .unknown)
        #expect(!h.transport.calls.contains("read storageStatus"), "no ring sync on unknown")
        h.transport.audio(Data([1, 0, 0, 0xB8]))
        h.clock.advance(1)
        h.session.recorder.rotateNow(reason: .forced)
        let header = try #require(chunks(h).first)
        #expect(header.offlineStorage == nil, "header says null, not false")
        // The device answers on a later attempt.
        h.transport.values[.firmwareRevision] = Data("3.0.21".utf8)
        h.session.tick()
        h.clock.advance(31)
        h.session.tick()
        #expect(h.session.info.offlineSupport == .supported)
        #expect(h.transport.calls.contains("read storageStatus"), "ring sync started after re-detection")
    }

    @Test func affirmativeOldFirmwareIsUnsupportedWithoutRetry() {
        var values = FakeDeviceTransport.cv1Values()
        values[.firmwareRevision] = Data("3.0.19".utf8)
        let h = SessionHarness(values: values)
        h.connectFully()
        #expect(h.session.info.offlineSupport.headerValue == false)
        h.clock.advance(31)
        h.session.tick()
        h.clock.advance(31)
        h.session.tick()
        #expect(h.transport.calls.filter { $0 == "read firmwareRevision" }.count == 1)
    }
}

// MARK: - #9 / #16 settings

final class FlakyTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    var failuresLeft: Int
    var token: String?
    init(failures: Int, token: String?) {
        failuresLeft = failures
        self.token = token
    }
    func load() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw KeychainError.status(-25308)  // errSecInteractionNotAllowed (device locked)
        }
        return token
    }
    func save(_ token: String?) throws {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }
}

@Suite struct SettingsReviewRegressionTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "omi-review-\(UUID().uuidString)")! }

    /// #16: a transient Keychain failure is not cached as "no token".
    @Test func transientKeychainFailureIsRetried() throws {
        let d = defaults()
        d.set("https://mac.ts.net", forKey: "omi.serverURL")
        let s = SettingsStore(defaults: d, tokens: FlakyTokenStore(failures: 1, token: "tok-abcdef"))
        #expect(s.serverConfig().endpoint == nil)
        #expect(s.tokenError != nil)
        #expect(s.serverConfig().endpoint?.token == "tok-abcdef", "next access reads the Keychain again")
        #expect(s.tokenError == nil)
    }

    @Test func definitiveNoTokenIsCachedUntilInvalidated() throws {
        let store = FlakyTokenStore(failures: 0, token: nil)
        let s = SettingsStore(defaults: defaults(), tokens: store)
        #expect(s.token == nil)
        store.token = "late"
        #expect(s.token == nil)
        s.invalidateTokenCache()  // protectedDataDidBecomeAvailable
        #expect(s.token == "late")
    }

    /// #9: URL and token always come from the same configuration.
    @Test func concurrentReadsNeverMixServers() throws {
        let s = SettingsStore(defaults: defaults(), tokens: InMemoryTokenStore())
        try s.setServer(url: URL(string: "https://a.ts.net")!, token: "token-A-000000")
        let pairs = [("https://a.ts.net", "token-A-000000"), ("https://b.ts.net", "token-B-111111")]
        let mismatches = MismatchCounter()
        DispatchQueue.concurrentPerform(iterations: 4000) { i in
            if i % 4 == 0 {
                let (u, t) = pairs[(i / 4) % 2]
                try? s.setServer(url: URL(string: u)!, token: t)
            } else if let e = s.serverConfig().endpoint {
                let expected = e.baseURL.host == "a.ts.net" ? "token-A-000000" : "token-B-111111"
                if e.token != expected { mismatches.add() }
            }
        }
        #expect(mismatches.value == 0)
    }

    @Test func generationIsPersistedAndBumped() throws {
        let d = defaults()
        let s1 = SettingsStore(defaults: d, tokens: InMemoryTokenStore())
        let g0 = s1.serverConfig().generation
        try s1.setServer(url: URL(string: "https://a.ts.net")!, token: "tok-111111")
        let g1 = s1.serverConfig().generation
        #expect(g1 == g0 + 1)
        let s2 = SettingsStore(defaults: d, tokens: InMemoryTokenStore("tok-111111"))
        #expect(s2.serverConfig().generation == g1, "tasks surviving a relaunch keep matching")
    }
}

final class MismatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

// MARK: - #18 / #4 engine

@Suite(.serialized) struct EngineReviewRegressionTests {
    func makeSettings(simulated: Bool = false, remembered: UUID? = nil) throws -> SettingsStore {
        let d = UserDefaults(suiteName: "omi-eng-\(UUID().uuidString)")!
        let s = SettingsStore(defaults: d, tokens: InMemoryTokenStore())
        try s.setServer(url: URL(string: "https://mac.ts.net")!, token: "tok-engine-review")
        s.simulatedMode = simulated
        s.rememberedDeviceId = remembered
        return s
    }

    /// #18: launch does not wait for recovery; recording and uploads wait for it.
    @Test func recoveryRunsAsyncAndGatesUploads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-rec-\(UUID().uuidString)")
        let dirs = CaptureDirectories(root: root)
        try dirs.create()
        // An abandoned capture from a "previous run".
        let outbox = Outbox(dirs: dirs)
        let env = CaptureEnvironment(dirs: dirs, outbox: outbox, clock: SystemClock(), appVersion: "t", timezone: "UTC")
        let r = LiveCaptureRecorder(env: env)
        let abandoned = try r.begin(meta: CaptureDeviceMeta(deviceId: "dev", codec: .opus20ms))
        r.append(Data([1, 0, 0, 0xB8]))
        r.syncNow()

        let uploads = CountingUploadTransport()
        var config = EngineConfiguration(dirs: dirs, appVersion: "t", useCoreBluetooth: false, tickInterval: 0.2)
        config.testBeforeRecovery = { Thread.sleep(forTimeInterval: 0.8) }
        let started = Date()
        let engine = OmiEngine(config: config, settings: try makeSettings(), uploadTransport: uploads)
        #expect(Date().timeIntervalSince(started) < 0.5, "init must not block on recovery")
        #expect(uploads.started.isEmpty, "no uploads before recovery")
        let done = engine.queue.sync { engine.recoveryComplete }  // waits behind recovery on the queue
        #expect(done)
        engine.queue.sync {}
        #expect(uploads.startedNames.contains(OutboxKind.seal(captureId: abandoned).fileName))
        #expect(uploads.startedNames.contains(OutboxKind.chunk(captureId: abandoned, sequence: 0).fileName))
    }

    /// #4: with the storage guard tripped, a restored connection is cancelled, never recorded.
    @Test func storageGuardBlocksRestoredConnection() throws {
        let x = UUID(uuidString: "0000000A-0000-4000-8000-00000000000A")!
        let backend = FakeBackend()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-guard-\(UUID().uuidString)")
        var config = EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false, tickInterval: 0.2)
        config.testCentralBackend = { _ in backend }
        config.storagePolicy.tripBelow = Int64.max  // "less than 200 MB free" from the start
        config.storagePolicy.recoverAbove = Int64.max
        let engine = OmiEngine(config: config, settings: try makeSettings(remembered: x), uploadTransport: CountingUploadTransport())
        engine.queue.sync {}
        #expect(engine.snapshotNow().storageTripped)
        let p = FakePeripheral(x, state: .connected)
        p.configure = { $0.values = FakeDeviceTransport.cv1Values() }
        let events = try #require(engine.centralEventsForTesting)
        engine.queue.sync { events.backendWillRestore([p]) }
        backend.state = .poweredOn
        engine.queue.sync { events.backendDidUpdateState(.poweredOn) }
        #expect(backend.cancels.contains(x))
        #expect(engine.session == nil)
        engine.queue.sync { events.backendDidConnect(p) }
        #expect(engine.session == nil)
    }

    @Test func restoredConnectionStartsSessionWhenAllowed() throws {
        let x = UUID(uuidString: "0000000A-0000-4000-8000-00000000000B")!
        let backend = FakeBackend()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-restore-\(UUID().uuidString)")
        var config = EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false, tickInterval: 0.2)
        config.testCentralBackend = { _ in backend }
        let engine = OmiEngine(config: config, settings: try makeSettings(remembered: x), uploadTransport: CountingUploadTransport())
        let p = FakePeripheral(x, state: .connected)
        p.configure = {
            $0.values = FakeDeviceTransport.cv1Values()
            $0.cachedCharacteristics = Set(OmiCharacteristic.allCases)
            $0.alreadyNotifying = [.audioData]
        }
        let events = try #require(engine.centralEventsForTesting)
        engine.queue.sync { events.backendWillRestore([p]) }
        #expect(engine.session != nil)
        #expect(engine.recorder.isActive)
    }
}
