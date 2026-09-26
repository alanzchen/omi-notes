import Foundation
import OmiCapture
import OmiProtocol

// MARK: - Transport abstraction

/// A connected Omi device as seen by the per-connection logic. Implemented by the CoreBluetooth
/// adapter (`CBDeviceTransport`) and by `SimulatedDevice`. All calls and callbacks happen on the
/// engine queue.
public protocol DeviceTransport: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    /// `maximumWriteValueLength(for: .withoutResponse)` = ATT MTU − 3.
    var maximumWriteValueLength: Int { get }
    var isSimulated: Bool { get }
    var delegate: DeviceTransportDelegate? { get set }

    /// Discover services and characteristics → `didDiscover` (possibly several times, last with `complete`).
    func discover()
    func read(_ characteristic: OmiCharacteristic)
    /// Write with response.
    func write(_ data: Data, to characteristic: OmiCharacteristic)
    func setNotify(_ enabled: Bool, for characteristic: OmiCharacteristic)
}

public protocol DeviceTransportDelegate: AnyObject {
    func transport(_ t: DeviceTransport, didDiscover characteristics: Set<OmiCharacteristic>, complete: Bool)
    /// Read response or notification (CoreBluetooth does not distinguish them).
    func transport(_ t: DeviceTransport, didUpdateValue value: Data?, for c: OmiCharacteristic, error: Error?)
    func transport(_ t: DeviceTransport, didWriteTo c: OmiCharacteristic, error: Error?)
    func transport(_ t: DeviceTransport, didUpdateNotificationStateFor c: OmiCharacteristic, enabled: Bool, error: Error?)
}

public protocol DeviceSessionDelegate: AnyObject {
    func sessionDidChange(_ session: DeviceSession)
    func sessionDidStartCapture(_ session: DeviceSession)
    func sessionDidBecomeReady(_ session: DeviceSession)
    func session(_ session: DeviceSession, didReceiveButton event: ButtonEvent)
    /// Unsupported device / unrecoverable setup failure: disconnect (so the firmware records to its
    /// own storage instead of dropping audio while connected-but-unsubscribed).
    func session(_ session: DeviceSession, requestsDisconnect reason: String, suppressReconnect: Bool)
    func sessionDidHitStorageError(_ session: DeviceSession)
    func sessionDidWakeAfterSilence(_ session: DeviceSession)
    /// Setup stalled or the audio subscription could not be restored: drop the link (without
    /// suppressing auto-reconnect) so a fresh connection starts over.
    func session(_ session: DeviceSession, requestsReconnect reason: String)
}

// MARK: - Session

/// One BLE connection. Sequence (device-protocol.md):
/// discover → **subscribe audio first** (as soon as the characteristic is known) → time sync write
/// (u32 LE) + readback → codec read (only 20/21; otherwise refuse) → DIS + features →
/// battery/button/charging notify → ready (heartbeat) → ring detection + sync.
///
/// Every audio notification is journaled before anything else happens with it.
public final class DeviceSession: DeviceTransportDelegate, RingTransport, @unchecked Sendable {
    public enum Phase: Equatable, Sendable {
        case discovering, subscribing, configuring, streaming, refused(String), ended
    }

    public struct Info: Equatable, Sendable {
        public var name: String?
        public var modelNumber: String?
        public var firmwareRevision: String?
        public var hardwareRevision: String?
        public var manufacturer: String?
        public var serialNumber: String?
        public var codec: OmiCodec?
        public var battery: Int?
        public var charging: Bool?
        public var features: DeviceFeatures?
        public var mtu = 0
        public var rtcValid: Bool?
        public var clockDriftSeconds: Int?
        public var offlineSupport: OfflineStorageSupport = .unknown
        public var offlineUnread: Int?
        public var noAudioYet = false
    }

    public struct LiveStats: Equatable, Sendable {
        public var notificationsPerSecond: Double = 0
        public var lossPercent: Double = 0
        public var received = 0
        public var lost = 0
        public var lastNotificationAt: Date?
    }

    enum Op {
        case read(OmiCharacteristic, (Data?, Error?) -> Void)
        case write(Data, OmiCharacteristic, (Error?) -> Void)
        case notify(OmiCharacteristic, Bool, (Error?) -> Void)
        case barrier(() -> Void)
    }

    public static let lowMTUWarningThreshold = 163
    public static let livenessTimeout: UInt64 = 10_000_000_000
    static let opTimeout: UInt64 = 10_000_000_000
    static let silenceWakeThreshold: UInt64 = 60_000_000_000
    static let discoveryTimeout: UInt64 = 15_000_000_000
    static let subscribeTimeout: UInt64 = 10_000_000_000
    static let maxDiscoveryAttempts = 2
    static let maxSubscribeAttempts = 3
    static let detectionRetryDelay: UInt64 = 30_000_000_000
    static let maxDetectionRetries = 3

    public let transport: DeviceTransport
    public let recorder: LiveCaptureRecorder
    public let ring: RingSyncEngine
    public let clock: CaptureClock
    public weak var delegate: DeviceSessionDelegate?
    public var onCodecLearned: ((OmiCodec) -> Void)?
    /// Called after each audio notification has been journaled (background keep-alive).
    public var onAudioNotification: (() -> Void)?

    public private(set) var phase: Phase = .discovering
    public private(set) var info = Info()
    public private(set) var stats = LiveStats()
    public private(set) var available: Set<OmiCharacteristic> = []
    public private(set) var connectedAt: Date
    /// Characteristics in the order their notifications were requested (tests check subscribe-first).
    public private(set) var notifyOrder: [OmiCharacteristic] = []
    public private(set) var gattLog: [String] = []

    private var discoveryComplete = false
    private var discoveryAttempts = 0
    private var discoveryDeadline: UInt64?
    private var audioSubscribeRequested = false
    private var audioSubscribed = false
    private var subscribeAttempts = 0
    private var subscribeDeadline: UInt64?
    private var reconnectRequested = false
    private var capturedOnce = false
    private var firmwareReadFailed = false
    private var featuresReadFailed = false
    private var detectionRetries = 0
    private var detectionRetryAt: UInt64?
    private var configureStarted = false
    private var subscribedAtMono: UInt64?
    private var watchdogFired = false
    private var codecAttempts = 0
    private var ops: [Op] = []
    private var current: (op: Op, deadline: UInt64)?
    private var loss = SequenceLossTracker()
    private var recentNotificationMonos: [UInt64] = []
    private var lastNotificationMono: UInt64?
    private var ringContext: RingSyncContext?
    private var ringRetries = 0
    private var ringRetryAt: UInt64?
    static let ringRetryDelay: UInt64 = 30_000_000_000
    static let maxRingRetries = 3

    public init(transport: DeviceTransport, recorder: LiveCaptureRecorder, ring: RingSyncEngine, clock: CaptureClock) {
        self.transport = transport
        self.recorder = recorder
        self.ring = ring
        self.clock = clock
        connectedAt = clock.wallNow()
        info.name = transport.name
        transport.delegate = self
        ring.transport = self
    }

    public var deviceId: String { transport.identifier.uuidString.lowercased() }

    public func start() {
        info.mtu = transport.maximumWriteValueLength
        if info.mtu > 0, info.mtu < Self.lowMTUWarningThreshold {
            log(.warning, "ble", "MTU payload \(info.mtu) < \(Self.lowMTUWarningThreshold): CV1 frames may be fragmented and dropped")
        } else {
            log(.info, "ble", "connected to \(transport.name ?? "device"), write length \(info.mtu)")
        }
        phase = .discovering
        requestDiscovery()
    }

    private func requestDiscovery() {
        discoveryAttempts += 1
        discoveryDeadline = clock.monotonicNanoseconds() &+ Self.discoveryTimeout
        transport.discover()
    }

    private func requestReconnect(_ reason: String) {
        guard !reconnectRequested, phase != .ended else { return }
        reconnectRequested = true
        log(.error, "ble", "reconnecting: \(reason)")
        delegate?.session(self, requestsReconnect: reason)
    }

    /// Link lost / user disconnect / app termination. Seals the live capture and interrupts ring sync.
    public func end(reason: SealReason) {
        guard phase != .ended else { return }
        let wasRefused: Bool
        if case .refused = phase { wasRefused = true } else { wasRefused = false }
        phase = .ended
        ring.handleDisconnect()
        let pending = current.map { [$0.op] } ?? []
        current = nil
        let queued = ops
        ops.removeAll()
        for op in pending + queued { fail(op, error: SessionError.disconnected) }
        if recorder.isActive {
            if wasRefused { recorder.abort() } else { recorder.finish(reason: reason) }
        }
        delegate?.sessionDidChange(self)
    }

    /// Storage guard / user stop: stop ring sync politely before the link goes down.
    public func prepareForDisconnect(reason: String) {
        ring.stop(reason: reason)
    }

    public func tick() {
        let now = clock.monotonicNanoseconds()
        checkSetupDeadlines(now: now)
        if let c = current, now >= c.deadline {
            log(.warning, "ble", "GATT op timed out: \(describe(c.op))")
            current = nil
            fail(c.op, error: SessionError.timeout)
            pump()
        }
        if audioSubscribed, lastNotificationMono == nil, !watchdogFired, let s = subscribedAtMono,
           now &- s >= Self.livenessTimeout {
            watchdogFired = true
            info.noAudioYet = true
            log(.warning, "ble", "no audio notification within 10 s of subscribing (device may be silent); re-issuing subscribe")
            transport.setNotify(true, for: .audioData)
            delegate?.sessionDidChange(self)
        }
        recorder.tick()
        ring.tick()
        retryRingSyncIfNeeded(now: now)
        retryDetectionIfNeeded(now: now)
        updateRate(now: now)
    }

    /// Discovery and audio subscription must complete in bounded time (the firmware drops audio
    /// while connected-but-unsubscribed); retry a little, then reconnect.
    private func checkSetupDeadlines(now: UInt64) {
        guard phase != .ended, !reconnectRequested else { return }
        if case .refused = phase { return }
        if !discoveryComplete, let d = discoveryDeadline, now >= d {
            if discoveryAttempts < Self.maxDiscoveryAttempts {
                log(.warning, "ble", "service discovery timed out; retrying")
                requestDiscovery()
            } else {
                requestReconnect("service discovery timed out")
            }
            return
        }
        if audioSubscribeRequested, !audioSubscribed, let d = subscribeDeadline, now >= d {
            if subscribeAttempts < Self.maxSubscribeAttempts {
                log(.warning, "ble", "audio subscription not confirmed; retrying")
                requestAudioSubscription()
            } else {
                requestReconnect("audio subscription not confirmed")
            }
        }
    }

    /// Offline-storage support stayed unknown because DIS/features could not be read: read again.
    private func retryDetectionIfNeeded(now: UInt64) {
        guard phase == .streaming, info.offlineSupport == .unknown, detectionRetries < Self.maxDetectionRetries,
              firmwareReadFailed || featuresReadFailed else { return }
        guard let at = detectionRetryAt else {
            detectionRetryAt = now &+ Self.detectionRetryDelay
            return
        }
        guard now >= at else { return }
        detectionRetries += 1
        detectionRetryAt = nil
        log(.info, "ble", "re-reading device information for offline-storage detection (\(detectionRetries)/\(Self.maxDetectionRetries))")
        if firmwareReadFailed { enqueue(.read(.firmwareRevision) { [weak self] data, error in self?.storeString(.firmwareRevision, data, error) }) }
        if featuresReadFailed { enqueue(.read(.features) { [weak self] data, error in self?.storeFeatures(data, error) }) }
        enqueue(.barrier { [weak self] in self?.evaluateOfflineSupport() })
    }

    /// Every connect must end in a sealed ring sync when the device supports it (the server's
    /// coverage logic relies on it), so a sync that failed or was interrupted while the link is
    /// still up is retried a few times.
    private func retryRingSyncIfNeeded(now: UInt64) {
        guard phase == .streaming, let ctx = ringContext, ringRetries < Self.maxRingRetries else { return }
        switch ring.state {
        case .failed, .interrupted:
            guard let at = ringRetryAt else {
                ringRetryAt = now &+ Self.ringRetryDelay
                return
            }
            guard now >= at else { return }
            ringRetries += 1
            ringRetryAt = nil
            log(.info, "ring", "retrying offline sync (\(ringRetries)/\(Self.maxRingRetries))")
            ring.start(ctx)
        default:
            ringRetryAt = nil
        }
    }

    // MARK: DeviceTransportDelegate

    public func transport(_ t: DeviceTransport, didDiscover characteristics: Set<OmiCharacteristic>, complete: Bool) {
        guard phase != .ended else { return }
        available = characteristics
        if characteristics.contains(.audioData), !audioSubscribeRequested {
            // Routing rule: connected-but-unsubscribed drops audio, so this comes before anything else.
            audioSubscribeRequested = true
            phase = .subscribing
            requestAudioSubscription()
        }
        guard complete else { return }
        discoveryComplete = true
        discoveryDeadline = nil
        if !characteristics.contains(.audioData) {
            refuse("not an Omi device (no audio characteristic)")
            return
        }
        startConfigurationIfReady()
    }

    public func transport(_ t: DeviceTransport, didUpdateValue value: Data?, for c: OmiCharacteristic, error: Error?) {
        guard phase != .ended else { return }
        if c == .audioData {
            if let value, error == nil { handleAudio(value) }
            return
        }
        if case .read(let rc, let done)? = current?.op, rc == c {
            current = nil
            done(value, error)
            pump()
            if c != .batteryLevel && c != .charging { return }
        }
        guard let value, error == nil else { return }
        switch c {
        case .batteryLevel:
            if let b = value.first { info.battery = Int(b); delegate?.sessionDidChange(self) }
        case .charging:
            if let b = value.first { info.charging = b != 0; delegate?.sessionDidChange(self) }
        case .button:
            if let e = ButtonEvent.decode(value) { delegate?.session(self, didReceiveButton: e) }
        case .storageControl:
            ring.handleNotification(value)
            delegate?.sessionDidChange(self)
        default:
            break
        }
    }

    public func transport(_ t: DeviceTransport, didWriteTo c: OmiCharacteristic, error: Error?) {
        guard phase != .ended else { return }
        if case .write(_, let wc, let done)? = current?.op, wc == c {
            current = nil
            done(error)
            pump()
        }
    }

    public func transport(_ t: DeviceTransport, didUpdateNotificationStateFor c: OmiCharacteristic, enabled: Bool, error: Error?) {
        guard phase != .ended else { return }
        if c == .audioData {
            handleAudioSubscription(enabled: enabled, error: error)
            return
        }
        if case .notify(let nc, _, let done)? = current?.op, nc == c {
            current = nil
            done(error)
            pump()
        }
    }

    // MARK: RingTransport

    public func ringReadStatus() {
        enqueue(.read(.storageStatus) { [weak self] data, error in
            guard let self else { return }
            if let data, case .ring(let s) = RingProtocol.parseStatus(data) {
                self.info.rtcValid = s.rtcValid
                self.info.offlineUnread = Int(s.unreadRecords)
            }
            self.ring.handleStatusRead(data, error: error)
        })
    }

    public func ringEnableNotifications() {
        enqueue(.notify(.storageControl, true) { [weak self] error in self?.ring.handleNotificationsEnabled(error: error) })
    }

    public func ringWrite(_ command: Data) {
        enqueue(.write(command, .storageControl) { [weak self] error in self?.ring.handleWriteResult(error: error) })
    }

    // MARK: Audio

    private func requestAudioSubscription() {
        subscribeAttempts += 1
        subscribeDeadline = clock.monotonicNanoseconds() &+ Self.subscribeTimeout
        notifyOrder.append(.audioData)
        gattLog.append("notify audioData")
        transport.setNotify(true, for: .audioData)
    }

    private func handleAudioSubscription(enabled: Bool, error: Error?) {
        if case .refused = phase { return }
        guard enabled else {
            // Not notifying (turned off, or a failed subscribe): the firmware drops audio while
            // unsubscribed, so coverage ends now, error or not. Seal the capture, then restore the
            // subscription (bounded) and reconnect if that fails.
            endAudioCoverage()
            if let error {
                log(.error, "ble", "audio subscribe failed: \(error.localizedDescription)")
                if subscribeAttempts < Self.maxSubscribeAttempts { requestAudioSubscription() } else { requestReconnect("could not subscribe to audio") }
            } else if audioSubscribeRequested {
                subscribeAttempts = 0
                requestAudioSubscription()
            }
            return
        }
        if let error {
            // Still notifying despite the error: audio flows, so treat it as subscribed.
            log(.warning, "ble", "audio subscribe reported \(error.localizedDescription) but notifications are on")
        }
        if audioSubscribed { return }
        audioSubscribed = true
        subscribeDeadline = nil
        subscribedAtMono = clock.monotonicNanoseconds()
        beginCaptureIfNeeded()
        startConfigurationIfReady()
    }

    private func endAudioCoverage() {
        audioSubscribed = false
        guard recorder.isActive else { return }
        log(.warning, "ble", "audio notifications are off; sealing capture \(recorder.captureId ?? "?")")
        recorder.finish(reason: .bleDisconnected)
        delegate?.sessionDidChange(self)
    }

    private func beginCaptureIfNeeded() {
        guard !recorder.isActive else { return }
        do {
            try recorder.begin(meta: captureMeta())
            if !capturedOnce {
                connectedAt = recorder.captureStartedAt ?? connectedAt  // the reconnect time (covers_until)
                capturedOnce = true
            }
            delegate?.sessionDidStartCapture(self)
        } catch {
            log(.error, "capture", "could not start live capture: \(error)")
            delegate?.sessionDidHitStorageError(self)
        }
    }

    private func handleAudio(_ value: Data) {
        if case .refused = phase { return }
        beginCaptureIfNeeded()
        // Journal first.
        let ok = recorder.append(value)
        let now = clock.monotonicNanoseconds()
        let wokeFromSilence = lastNotificationMono.map { now &- $0 >= Self.silenceWakeThreshold } ?? false
        lastNotificationMono = now
        if info.noAudioYet { info.noAudioYet = false }
        if let h = AudioPacketHeader(value) { loss.record(h.sequence) }
        recentNotificationMonos.append(now)
        stats.received = loss.received
        stats.lost = loss.lost
        stats.lossPercent = loss.lossPercent
        stats.lastNotificationAt = clock.wallNow()
        onAudioNotification?()
        if !ok, recorder.outOfSpace { delegate?.sessionDidHitStorageError(self) }
        if wokeFromSilence { delegate?.sessionDidWakeAfterSilence(self) }
    }

    private func updateRate(now: UInt64) {
        let window: UInt64 = 5_000_000_000
        recentNotificationMonos.removeAll { now &- $0 > window }
        stats.notificationsPerSecond = Double(recentNotificationMonos.count) / 5
    }

    // MARK: Configuration

    private func startConfigurationIfReady() {
        guard discoveryComplete, audioSubscribed, !configureStarted else { return }
        configureStarted = true
        phase = .configuring
        if available.contains(.timeSyncWrite) {
            let secs = UInt32(clamping: Int64(clock.wallNow().timeIntervalSince1970))
            let payload = withUnsafeBytes(of: secs.littleEndian) { Data($0) }
            enqueue(.write(payload, .timeSyncWrite) { error in
                if let error { log(.warning, "ble", "time sync write failed: \(error.localizedDescription)") }
            })
            if available.contains(.timeSyncRead) {
                enqueue(.read(.timeSyncRead) { [weak self] data, _ in
                    guard let self, let data, data.count >= 4 else { return }
                    var raw: UInt32 = 0
                    for (i, byte) in data.prefix(4).enumerated() { raw |= UInt32(byte) << (8 * UInt32(i)) }
                    let phoneSeconds = Int64(self.clock.wallNow().timeIntervalSince1970)
                    let drift = Int(Int64(raw) - phoneSeconds)
                    self.info.clockDriftSeconds = drift
                    log(abs(drift) > 2 ? .warning : .info, "ble", "device clock readback drift \(drift) s")
                })
            }
        }
        readCodec()
    }

    private func readCodec() {
        codecAttempts += 1
        enqueue(.read(.audioCodec) { [weak self] data, error in
            guard let self else { return }
            switch OmiCodec.evaluate(error == nil ? data : nil) {
            case .supported(let codec):
                self.info.codec = codec
                self.onCodecLearned?(codec)
                self.recorder.updateMeta(self.captureMeta())
                log(.info, "ble", "codec \(codec.rawValue) (\(codec.label))")
                self.configureRest()
            case .unsupported(let id):
                self.refuse("unsupported audio codec \(id) — only Opus 20/21 are supported")
            case .unreadable:
                if self.codecAttempts < 2 { self.readCodec() } else { self.refuse("audio codec unreadable") }
            }
        })
    }

    private func configureRest() {
        for c: OmiCharacteristic in [.modelNumber, .firmwareRevision, .hardwareRevision, .manufacturerName, .serialNumber]
        where available.contains(c) {
            enqueue(.read(c) { [weak self] data, error in self?.storeString(c, data, error) })
        }
        if available.contains(.features) {
            enqueue(.read(.features) { [weak self] data, error in self?.storeFeatures(data, error) })
        }
        if available.contains(.batteryLevel) {
            enqueue(.read(.batteryLevel) { _, _ in })
            enqueueNotify(.batteryLevel)
        }
        if available.contains(.button) { enqueueNotify(.button) }
        if available.contains(.charging) {
            enqueue(.read(.charging) { _, _ in })
            enqueueNotify(.charging)
        }
        enqueue(.barrier { [weak self] in self?.becomeReady() })
    }

    private func storeString(_ c: OmiCharacteristic, _ data: Data?, _ error: Error?) {
        guard let data, error == nil else {
            if c == .firmwareRevision { firmwareReadFailed = true }
            return
        }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        switch c {
        case .modelNumber: info.modelNumber = s
        case .firmwareRevision:
            info.firmwareRevision = s
            firmwareReadFailed = false
        case .hardwareRevision: info.hardwareRevision = s
        case .manufacturerName: info.manufacturer = s
        case .serialNumber: info.serialNumber = s
        default: break
        }
    }

    private func storeFeatures(_ data: Data?, _ error: Error?) {
        if let data, error == nil, let f = DeviceFeatures(data) {
            info.features = f
            featuresReadFailed = false
        } else {
            featuresReadFailed = true
        }
    }

    private func enqueueNotify(_ c: OmiCharacteristic) {
        enqueue(.notify(c, true) { error in
            if let error { log(.warning, "ble", "notify \(c.rawValue) failed: \(error.localizedDescription)") }
        })
    }

    private func becomeReady() {
        guard phase == .configuring else { return }
        phase = .streaming
        log(.info, "ble", "ready: \(info.modelNumber ?? "?") fw \(info.firmwareRevision ?? "?") battery \(info.battery.map(String.init) ?? "?")%")
        ring.onSupportDetermined = { [weak self] support in
            guard let self, support != .unknown else { return }
            self.info.offlineSupport = support
            self.recorder.updateMeta(self.captureMeta())
        }
        evaluateOfflineSupport()
        delegate?.sessionDidBecomeReady(self)
        delegate?.sessionDidChange(self)
    }

    /// Static detection (header `offline_storage`), then ring sync when supported. `.unknown` keeps
    /// the header `null` and is retried later on this connection.
    private func evaluateOfflineSupport() {
        guard phase == .streaming else { return }
        info.offlineSupport = OfflineStorageSupport.staticCheck(
            hasStorageService: hasStorage, firmwareRevision: info.firmwareRevision,
            features: info.features, hasFeaturesCharacteristic: available.contains(.features))
        recorder.updateMeta(captureMeta())
        guard info.offlineSupport == .supported, ringContext == nil, let codec = info.codec else { return }
        let ctx = RingSyncContext(
            meta: captureMeta(), codecId: codec.rawValue, hasStorageService: hasStorage,
            hasFeaturesCharacteristic: available.contains(.features), features: info.features,
            reconnectedAt: connectedAt)
        ringContext = ctx
        ring.start(ctx)
        delegate?.sessionDidChange(self)
    }

    private var hasStorage: Bool { available.contains(.storageControl) && available.contains(.storageStatus) }

    public func captureMeta() -> CaptureDeviceMeta {
        CaptureDeviceMeta(
            deviceId: deviceId, deviceName: info.name, modelNumber: info.modelNumber,
            firmwareRevision: info.firmwareRevision, hardwareRevision: info.hardwareRevision, codec: info.codec,
            offlineStorage: info.offlineSupport.headerValue)
    }

    private func refuse(_ reason: String) {
        if case .refused = phase { return }
        phase = .refused(reason)
        log(.error, "ble", "refusing to record: \(reason)")
        recorder.abort()
        ring.stop(reason: reason)
        delegate?.session(self, requestsDisconnect: reason, suppressReconnect: true)
        delegate?.sessionDidChange(self)
    }

    // MARK: GATT op queue (serial, one outstanding request)

    private func enqueue(_ op: Op) {
        guard phase != .ended else { fail(op, error: SessionError.disconnected); return }
        ops.append(op)
        pump()
    }

    private func pump() {
        while current == nil, !ops.isEmpty, phase != .ended {
            let op = ops.removeFirst()
            if case .barrier(let body) = op { body(); continue }
            current = (op, clock.monotonicNanoseconds() &+ Self.opTimeout)
            gattLog.append(describe(op))
            switch op {
            case .read(let c, _): transport.read(c)
            case .write(let d, let c, _): transport.write(d, to: c)
            case .notify(let c, let on, _):
                notifyOrder.append(c)
                transport.setNotify(on, for: c)
            case .barrier: break
            }
        }
    }

    private func fail(_ op: Op, error: Error) {
        switch op {
        case .read(_, let done): done(nil, error)
        case .write(_, _, let done): done(error)
        case .notify(_, _, let done): done(error)
        case .barrier: break
        }
    }

    private func describe(_ op: Op) -> String {
        switch op {
        case .read(let c, _): return "read \(c.rawValue)"
        case .write(let d, let c, _): return "write \(c.rawValue) [\(d.map { String(format: "%02x", $0) }.joined())]"
        case .notify(let c, let on, _): return "notify \(c.rawValue) \(on)"
        case .barrier: return "barrier"
        }
    }
}

public enum SessionError: Error, LocalizedError {
    case disconnected, timeout
    public var errorDescription: String? {
        switch self {
        case .disconnected: return "disconnected"
        case .timeout: return "timed out"
        }
    }
}
