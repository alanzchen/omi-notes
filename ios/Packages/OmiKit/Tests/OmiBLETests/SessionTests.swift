import CoreBluetooth
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
import OmiProtocol

final class TestClock: CaptureClock, @unchecked Sendable {
    private let lock = NSLock()
    private var mono: UInt64 = 7_000_000_000_000
    private var wall = Date(timeIntervalSince1970: 1_790_451_125.123)
    func monotonicNanoseconds() -> UInt64 { lock.lock(); defer { lock.unlock() }; return mono }
    func wallNow() -> Date { lock.lock(); defer { lock.unlock() }; return wall }
    func advance(_ s: Double) {
        lock.lock(); defer { lock.unlock() }
        mono += UInt64((s * 1e9).rounded())
        wall = wall.addingTimeInterval(s)
    }
}

final class FakeDeviceTransport: DeviceTransport {
    let identifier: UUID
    var name: String? = "Omi"
    var maximumWriteValueLength = 244
    var isSimulated = false
    weak var delegate: DeviceTransportDelegate?
    var calls: [String] = []
    var values: [OmiCharacteristic: Data] = [:]
    /// Characteristics already notifying (restored link): setNotify(true) reports immediately,
    /// like `CBDeviceTransport`, without a fresh CoreBluetooth round trip.
    var alreadyNotifying: Set<OmiCharacteristic> = []
    /// Restored link with cached services: discover() answers synchronously.
    var cachedCharacteristics: Set<OmiCharacteristic>?

    init(identifier: UUID = UUID(uuidString: "D1F0C2AA-0000-4000-8000-000000000001")!) {
        self.identifier = identifier
    }

    func discover() {
        calls.append("discover")
        if let cached = cachedCharacteristics { delegate?.transport(self, didDiscover: cached, complete: true) }
    }

    /// Reads that fail although the pendant has a value.
    var failReads: Set<OmiCharacteristic> = []

    /// Reads that are never answered (the op stays outstanding, e.g. until the link drops).
    var unansweredReads: Set<OmiCharacteristic> = []

    func read(_ c: OmiCharacteristic) {
        calls.append("read \(c.rawValue)")
        if unansweredReads.contains(c) { return }
        let value = failReads.contains(c) ? nil : values[c]
        delegate?.transport(self, didUpdateValue: value, for: c, error: value == nil ? SessionError.timeout : nil)
    }

    /// Writes that fail (a pendant rejecting or not answering them).
    var writeErrors: [OmiCharacteristic: Error] = [:]
    /// Writes that are never answered (the op stays outstanding).
    var unanswered: Set<OmiCharacteristic> = []

    func write(_ data: Data, to c: OmiCharacteristic) {
        calls.append("write \(c.rawValue) \(data.map { String(format: "%02x", $0) }.joined())")
        if unanswered.contains(c) { return }
        if let e = writeErrors[c] { delegate?.transport(self, didWriteTo: c, error: e); return }
        // The pendant keeps its settings (flash), as the firmware does: one byte, capped.
        if c == .ledDimRatio, let b = data.first { values[c] = Data([min(b, 100)]) }
        if c == .micGain, let b = data.first { values[c] = Data([min(b, 8)]) }
        delegate?.transport(self, didWriteTo: c, error: nil)
    }

    func setNotify(_ enabled: Bool, for c: OmiCharacteristic) {
        calls.append("notify \(c.rawValue) \(enabled)")
        if alreadyNotifying.contains(c) == enabled, c == .audioData, enabled {
            delegate?.transport(self, didUpdateNotificationStateFor: c, enabled: true, error: nil)
            return
        }
        if c != .audioData { delegate?.transport(self, didUpdateNotificationStateFor: c, enabled: enabled, error: nil) }
    }

    func confirmAudioSubscription() {
        delegate?.transport(self, didUpdateNotificationStateFor: .audioData, enabled: true, error: nil)
    }

    func audio(_ d: Data) { delegate?.transport(self, didUpdateValue: d, for: .audioData, error: nil) }

    static func cv1Values(codec: UInt8 = 21, status: Data? = nil) -> [OmiCharacteristic: Data] {
        var status16 = Data()
        for v: UInt32 in [0, 0, 1_000_000, 1] { status16.append(withUnsafeBytes(of: v.littleEndian) { Data($0) }) }
        return [
            .audioCodec: Data([codec]), .modelNumber: Data("Omi CV 1".utf8), .firmwareRevision: Data("3.0.21".utf8),
            .hardwareRevision: Data("5.0".utf8), .manufacturerName: Data("Based Hardware".utf8),
            .features: withUnsafeBytes(of: UInt32(0x1EC).littleEndian) { Data($0) }, .batteryLevel: Data([83]),
            .charging: Data([1]), .timeSyncRead: withUnsafeBytes(of: UInt32(1_790_451_125).littleEndian) { Data($0) },
            .storageStatus: status ?? status16,
        ]
    }
}

final class RecordingSessionDelegate: DeviceSessionDelegate {
    var disconnectRequests: [(String, Bool)] = []
    var ready = 0
    var buttons: [ButtonEvent] = []
    func sessionDidChange(_ session: DeviceSession) {}
    func sessionDidStartCapture(_ session: DeviceSession) {}
    func sessionDidBecomeReady(_ session: DeviceSession) { ready += 1 }
    func session(_ session: DeviceSession, didReceiveButton event: ButtonEvent) { buttons.append(event) }
    func session(_ session: DeviceSession, requestsDisconnect reason: String, suppressReconnect: Bool) { disconnectRequests.append((reason, suppressReconnect)) }
    var reconnectRequests: [String] = []
    func sessionDidHitStorageError(_ session: DeviceSession) {}
    func sessionDidWakeAfterSilence(_ session: DeviceSession) {}
    func session(_ session: DeviceSession, requestsReconnect reason: String) { reconnectRequests.append(reason) }
}

struct SessionHarness {
    let clock = TestClock()
    let dirs: CaptureDirectories
    let outbox: Outbox
    let transport = FakeDeviceTransport()
    let session: DeviceSession
    let delegate = RecordingSessionDelegate()

    init(values: [OmiCharacteristic: Data] = FakeDeviceTransport.cv1Values()) {
        dirs = CaptureDirectories(root: FileManager.default.temporaryDirectory.appendingPathComponent("omible-\(UUID().uuidString)"))
        try! dirs.create()
        outbox = Outbox(dirs: dirs)
        let env = CaptureEnvironment(dirs: dirs, outbox: outbox, clock: clock, appVersion: "t", timezone: "UTC")
        let ring = RingSyncEngine(writer: RingCaptureWriter(env: env), cursors: RingCursorStore(stateDir: dirs.state))
        session = DeviceSession(transport: transport, recorder: LiveCaptureRecorder(env: env), ring: ring, clock: clock)
        session.delegate = delegate
        transport.values = values
    }

    func connectFully() {
        session.start()
        transport.delegate?.transport(transport, didDiscover: Set(OmiCharacteristic.allCases), complete: true)
        transport.confirmAudioSubscription()
    }
}

@Suite struct DeviceSessionTests {
    @Test func subscribesToAudioBeforeAnythingElse() throws {
        let h = SessionHarness()
        h.session.start()
        #expect(h.transport.calls == ["discover"])
        // Audio service characteristics arrive before the other services finish.
        h.transport.delegate?.transport(h.transport, didDiscover: [.audioData, .audioCodec], complete: false)
        #expect(h.transport.calls == ["discover", "notify audioData true"])
        h.transport.delegate?.transport(h.transport, didDiscover: Set(OmiCharacteristic.allCases), complete: true)
        #expect(h.transport.calls.count == 2)  // nothing until the subscription is confirmed
        h.transport.confirmAudioSubscription()
        #expect(h.session.recorder.isActive)
        let calls = h.transport.calls
        let secs = UInt32(1_790_451_125)
        let expectedTime = withUnsafeBytes(of: secs.littleEndian) { Data($0) }.map { String(format: "%02x", $0) }.joined()
        #expect(calls[2] == "write timeSyncWrite \(expectedTime)")
        #expect(calls[3] == "read timeSyncRead")
        #expect(calls[4] == "read audioCodec")
        #expect(calls.contains("read firmwareRevision"))
        #expect(calls.contains("notify button true"))
        #expect(calls.contains("notify batteryLevel true"))
        #expect(calls.contains("notify charging true"))
        #expect(h.session.notifyOrder.first == .audioData)
        #expect(h.session.phase == .streaming)
        #expect(h.session.info.codec == .opus20ms)
        #expect(h.session.info.modelNumber == "Omi CV 1")
        #expect(h.session.info.firmwareRevision == "3.0.21")
        #expect(h.session.info.battery == 83)
        #expect(h.session.info.charging == true)
        #expect(h.session.info.clockDriftSeconds == 0)
        #expect(h.session.info.offlineSupport == .supported)
        #expect(h.delegate.ready == 1)
        // Ring detection starts with a status read, after configuration; then INFO (unread 0 here).
        let statusIndex = try #require(calls.firstIndex(of: "read storageStatus"))
        #expect(statusIndex > calls.firstIndex(of: "read audioCodec")!)
        let info = try #require(calls.lastIndex(of: "write storageControl 10"))
        #expect(info > statusIndex)
        // the pendant's settings are read only after that, never ahead of offline sync
        #expect(calls.suffix(from: info + 1) == ["read ledDimRatio", "read micGain"])
    }

    /// Field log, build 42 (2026-11-08 04:58–05:00Z, a link restored by iOS): four "no INFO response"
    /// in a row. Firmware 3.0.21 answers INFO within ~5 s (INFO, or ACK "not ready") when the phone
    /// is subscribed (storage.c `storage_notify`); silence means the pendant saw no subscription,
    /// while iOS reported the restored one as on. The retry writes the subscription again (off, on).
    @Test func anUnansweredInfoResubscribesBeforeTheRetry() throws {
        let h = SessionHarness()
        h.connectFully()
        let first = try #require(h.transport.calls.lastIndex(of: "write storageControl 10"))
        h.clock.advance(16)
        h.session.tick()  // INFO times out
        h.clock.advance(1)
        h.session.tick()  // retry scheduled
        h.clock.advance(31)
        h.session.tick()  // retry
        let after = Array(h.transport.calls[(first + 1)...])
        let off = try #require(after.firstIndex(of: "notify storageControl false"))
        let on = try #require(after.lastIndex(of: "notify storageControl true"))
        let info = try #require(after.lastIndex(of: "write storageControl 10"))
        #expect(off < on && on < info)
    }

    @Test func unsupportedCodecRefusesToRecord() {
        let h = SessionHarness(values: FakeDeviceTransport.cv1Values(codec: 1))
        h.connectFully()
        h.transport.audio(Data([0, 0, 0, 1, 2, 3]))
        #expect(h.session.phase == .refused("unsupported audio codec 1 — only Opus 20/21 are supported"))
        #expect(h.delegate.disconnectRequests.count == 1)
        #expect(h.delegate.disconnectRequests.first?.1 == true)
        #expect(!h.session.recorder.isActive)
        #expect(h.outbox.pending().isEmpty)  // nothing uploaded: the audio is undecodable
        #expect(FileIO.contents(of: h.dirs.journalLive).isEmpty)
        #expect(!h.transport.calls.contains("read storageStatus"))
    }

    /// A codec read that fails on a live link is not an unsupported codec: read again, then a fresh
    /// connection (not suppressed). Only a codec value actually read and unknown refuses the pendant.
    @Test func unreadableCodecIsRetriedThenReconnectedNotRefused() {
        var values = FakeDeviceTransport.cv1Values()
        values[.audioCodec] = nil
        let h = SessionHarness(values: values)
        h.connectFully()
        #expect(h.transport.calls.filter { $0 == "read audioCodec" }.count == 2)
        #expect(h.delegate.reconnectRequests == ["audio codec unreadable"])
        #expect(h.delegate.disconnectRequests.isEmpty)
        if case .refused = h.session.phase { Issue.record("refused: \(h.session.phase)") }
        #expect(FileIO.contents(of: h.dirs.journalQuarantine).isEmpty)
    }

    /// ASTRA-20261111-IT1-01: a pendant that reported codec 1 is refused and its audio quarantined; with the reason
    /// file gone (as build 49 wrote none) recovery must not send those bytes labelled as the remembered Opus codec.
    @Test func aRefusedCodecsAudioIsNeverRecoveredAsTheRememberedCodec() throws {
        let h = SessionHarness()
        h.transport.unansweredReads = [.audioCodec]
        h.connectFully()
        h.transport.audio(Data([0, 0, 0, 0x11, 0x22, 0x33]))
        h.transport.delegate?.transport(h.transport, didUpdateValue: Data([1]), for: .audioCodec, error: nil)
        #expect(h.delegate.disconnectRequests.count == 1)
        let dir = try #require(FileIO.contents(of: h.dirs.journalQuarantine).first)
        let reason = dir.appendingPathComponent(CaptureRecovery.reasonFileName)
        #expect(try String(contentsOf: reason, encoding: .utf8).hasPrefix("unsupported audio codec 1"))
        let env = CaptureEnvironment(dirs: h.dirs, outbox: h.outbox, clock: h.clock, appVersion: "t", timezone: "UTC")
        #expect(CaptureRecovery.run(env: env, codecFallback: { _ in 21 }).restored.isEmpty)
        try FileManager.default.removeItem(at: reason)
        #expect(CaptureRecovery.run(env: env, codecFallback: { _ in 21 }).restored.isEmpty)
        #expect(!h.outbox.pending().contains { $0.kind.isChunk })
    }

    /// Field log, build 49 (2026-11-11 01:01:20–24Z): connected, the link dropped during the codec read, and
    /// `end` failing that read counted as "unreadable" twice: "refusing to record: audio codec unreadable",
    /// the capture quarantined as "unsupported codec" and reconnection suppressed. Now the drop just ends
    /// the session; the audio already received waits in the journal and the next launch's recovery sends it
    /// with the codec remembered for the pendant.
    @Test func aLinkLostDuringTheCodecReadKeepsTheAudioAndDoesNotRefuseThePendant() throws {
        let h = SessionHarness()
        h.transport.unansweredReads = [.audioCodec]
        h.connectFully()
        #expect(h.transport.calls.last == "read audioCodec")
        for i in 0..<4 {
            h.transport.audio(Data([UInt8(i), 0, 0, 0xB8, 1, 2, 3]))
            h.clock.advance(0.02)
        }
        h.session.end(reason: .bleDisconnected)
        #expect(h.session.phase == .ended)
        #expect(h.delegate.disconnectRequests.isEmpty, "no refusal, so nothing suppresses the reconnect")
        #expect(FileIO.contents(of: h.dirs.journalQuarantine).isEmpty)
        let kept = try #require(FileIO.contents(of: h.dirs.journalLive).first)
        let id = kept.lastPathComponent
        // reconnect → launch recovery knows the pendant's codec (21) from earlier connections
        let env = CaptureEnvironment(dirs: h.dirs, outbox: h.outbox, clock: h.clock, appVersion: "t", timezone: "UTC")
        let report = CaptureRecovery.run(env: env, codecFallback: { _ in 21 })
        #expect(report.liveRecovered == [id])
        let chunk = try #require(h.outbox.pending().first { $0.kind == .chunk(captureId: id, sequence: 0) })
        let parsed = try Envelope.parse(Data(contentsOf: chunk.url))
        #expect(parsed.header.codecId == 21 && parsed.header.recordCount == 4)
        #expect(h.outbox.contains(.seal(captureId: id)))
    }

    @Test func audioIsJournaledAndSealedOnDisconnect() throws {
        let h = SessionHarness()
        h.connectFully()
        for i in 0..<5 {
            h.transport.audio(Data([UInt8(i), 0, 0, 0xB8, 1, 2, 3]))
            h.clock.advance(0.02)
        }
        h.transport.audio(Data([9, 0, 0, 0xB8]))  // seq gap 5..8
        #expect(h.session.stats.lost == 4)
        #expect(h.session.recorder.stats.totalRecords == 6)
        h.clock.advance(1)
        h.session.end(reason: .bleDisconnected)
        let chunk = try #require(h.outbox.pending().first { $0.kind.isChunk })
        let parsed = try Envelope.parse(Data(contentsOf: chunk.url))
        #expect(parsed.header.recordCount == 6)
        #expect(parsed.header.modelNumber == "Omi CV 1")
        #expect(parsed.header.firmwareRevision == "3.0.21")
        #expect(parsed.header.offlineStorage == true)
        #expect(BLERecord.scan(parsed.payload).records.map(\.flags) == [1, 0, 0, 0, 0, 0])
        #expect(h.outbox.pending().contains { if case .seal = $0.kind { return true } else { return false } })
    }

    @Test func notificationBeforeConfirmationStartsCapture() {
        let h = SessionHarness()
        h.session.start()
        h.transport.delegate?.transport(h.transport, didDiscover: Set(OmiCharacteristic.allCases), complete: true)
        h.transport.audio(Data([1, 0, 0, 0xB8]))
        #expect(h.session.recorder.isActive)
        #expect(h.session.recorder.stats.totalRecords == 1)
    }

    @Test func livenessWatchdogResubscribesButDoesNotDisconnect() {
        let h = SessionHarness()
        h.connectFully()
        h.clock.advance(11)
        h.session.tick()
        #expect(h.transport.calls.filter { $0 == "notify audioData true" }.count == 2)
        #expect(h.session.info.noAudioYet)
        #expect(h.delegate.disconnectRequests.isEmpty)
        h.transport.audio(Data([1, 0, 0, 0xB8]))
        #expect(!h.session.info.noAudioYet)
    }

    @Test func legacyStorageStatusGetsNoStorageWrites() {
        let h = SessionHarness(values: FakeDeviceTransport.cv1Values(status: Data(count: 8)))
        h.connectFully()
        #expect(h.transport.calls.contains("read storageStatus"))
        #expect(!h.transport.calls.contains { $0.hasPrefix("write storageControl") })
        #expect(!h.transport.calls.contains("notify storageControl true"))
        #expect(h.session.info.offlineSupport.headerValue == false)
    }

    @Test func buttonEventsAreForwarded() {
        let h = SessionHarness()
        h.connectFully()
        h.transport.delegate?.transport(h.transport, didUpdateValue: Data([2, 0, 0, 0, 0, 0, 0, 0]), for: .button, error: nil)
        #expect(h.delegate.buttons == [.doubleTap])
    }

    @Test func lowMTUIsReported() {
        let h = SessionHarness()
        h.transport.maximumWriteValueLength = 97
        h.session.start()
        #expect(h.session.info.mtu == 97)
    }
}

@Suite struct PairingPolicyTests {
    @Test func detectsPeerRemovedPairingInformation() {
        let e = NSError(domain: CBErrorDomain, code: CBError.Code.peerRemovedPairingInformation.rawValue)
        #expect(PairingPolicy.isPairingLost(e))
        let wrapped = NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: e])
        #expect(PairingPolicy.isPairingLost(wrapped))
        #expect(!PairingPolicy.isPairingLost(NSError(domain: CBErrorDomain, code: CBError.Code.connectionTimeout.rawValue)))
        #expect(!PairingPolicy.isPairingLost(nil))
    }
}
