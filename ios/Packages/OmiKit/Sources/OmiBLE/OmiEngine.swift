import Foundation
import OmiCapture
import OmiProtocol

/// `UIApplication.beginBackgroundTask` abstraction (UIKit lives in the app target).
public protocol BackgroundTaskProviding: AnyObject, Sendable {
    func beginTask(name: String, expiration: @escaping @Sendable () -> Void) -> Int?
    func endTask(_ id: Int)
}

public enum ConnectionPhase: Equatable, Sendable {
    case noDevice
    case bluetoothUnavailable(String)
    case waitingForDevice
    case settingUp
    case streaming
    case refused(String)
    case paused(String)

    public var title: String {
        switch self {
        case .noDevice: return "No device paired"
        case .bluetoothUnavailable(let s): return "Bluetooth \(s)"
        case .waitingForDevice: return "Waiting for device"
        case .settingUp: return "Connecting…"
        case .streaming: return "Recording"
        case .refused: return "Unsupported device"
        case .paused: return "Paused"
        }
    }
}

public struct LiveSnapshot: Equatable, Sendable {
    public var captureId: String?
    public var chunkSequence = 0
    public var chunkRecords = 0
    public var totalRecords = 0
    public var notificationsPerSecond: Double = 0
    public var lossPercent: Double = 0
    public var received = 0
    public var lost = 0
    public var lastNotificationAt: Date?
}

public struct EngineSnapshot: Equatable, Sendable {
    public var bluetooth: CentralState = .unknown
    public var connection: ConnectionPhase = .noDevice
    public var simulated = false
    public var rememberedDeviceId: String?
    public var rememberedDeviceName: String?
    public var device: DeviceSession.Info?
    public var live: LiveSnapshot?
    public var offline: RingSyncState = .idle
    public var outbox = OutboxStats()
    public var upload = UploaderStatus()
    public var freeBytes: Int64?
    public var storageTripped = false
    public var scanning = false
    public var scanResults: [ScanCandidate] = []
    public var attention: [String] = []
    public var serverConfigured = false
    public var lastButton: String?
    public var recoveredCaptures = 0
    public var quarantined: [String] = []
    /// Voice enrollment window currently open on the live capture, if any.
    public var activeEnrollmentId: String?

    public init() {}
}

public struct EngineConfiguration: Sendable {
    public var dirs: CaptureDirectories
    public var clock: CaptureClock
    public var appVersion: String?
    public var timezone: String?
    public var simulatedTrace: SimulatedTrace?
    public var useCoreBluetooth: Bool
    public var tickInterval: TimeInterval
    /// Test hook: runs on the engine queue right before launch recovery.
    public var testBeforeRecovery: (@Sendable () -> Void)?
    /// Test hook: a central backend (fake) instead of CoreBluetooth.
    public var testCentralBackend: (@Sendable (CentralBackendEvents) -> CentralBackend)?
    public var storagePolicy = StorageGuardPolicy()

    public init(dirs: CaptureDirectories, clock: CaptureClock = SystemClock(), appVersion: String?, timezone: String? = TimeZone.current.identifier, simulatedTrace: SimulatedTrace? = nil, useCoreBluetooth: Bool = true, tickInterval: TimeInterval = 1) {
        self.dirs = dirs
        self.clock = clock
        self.appVersion = appVersion
        self.timezone = timezone
        self.simulatedTrace = simulatedTrace
        self.useCoreBluetooth = useCoreBluetooth
        self.tickInterval = tickInterval
    }
}

/// The app's single coordinator. Everything below runs on one serial queue, which is also the
/// CoreBluetooth delegate queue and the upload session's delegate queue.
public final class OmiEngine: CentralControllerDelegate, DeviceSessionDelegate, @unchecked Sendable {
    public let queue = DispatchQueue(label: "omi-notes.engine", qos: .userInitiated)
    public let settings: SettingsStore
    public let config: EngineConfiguration

    public private(set) var env: CaptureEnvironment!
    public private(set) var outbox: Outbox!
    public private(set) var recorder: LiveCaptureRecorder!
    public private(set) var ring: RingSyncEngine!
    public private(set) var uploader: Uploader!
    private var ringWriter: RingCaptureWriter!
    public private(set) var ledger: RingCaptureLedger!
    public private(set) var enrollmentGate: EnrollmentGate!
    /// Recording and uploads are gated on launch recovery.
    public private(set) var recoveryComplete = false
    private var cursors: RingCursorStore!
    private var deviceMemory: DeviceMemory!
    private var events: EventWriter!
    private var backgroundTransport: BackgroundSessionTransport?
    private var central: CentralController?
    private var simulated: SimulatedDevice?
    public private(set) var session: DeviceSession?
    private weak var background: BackgroundTaskProviding?

    private var snapshotSink: (@Sendable (EngineSnapshot) -> Void)?
    private var snapshotPending = false
    private var reconcilePending = false
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var btState: CentralState = .unknown
    private var scanResults: [UUID: ScanCandidate] = [:]
    private var scanning = false
    private var attention: [String] = []
    private var refusal: String?
    private var storageTripped = false
    private var freeBytes: Int64?
    private var outboxStats = OutboxStats()
    private var quarantined: [String] = []
    private var pendingDisconnectReason: SealReason?
    private var appActive = true
    private var lastHeartbeatMono: UInt64 = 0
    private var keepAliveTask: Int?
    private var lastAudioMono: UInt64 = 0
    private var keepAliveSinceMono: UInt64 = 0
    private var lastButton: String?
    private var recoveredCaptures = 0
    private var processedThrough: [String: Int] = [:]
    private var simReconnectWork: DispatchWorkItem?
    private struct ActiveEnrollment { var id: String; var captureId: String; var deviceId: String }
    private var activeEnrollment: ActiveEnrollment?

    public var storagePolicy: StorageGuardPolicy { config.storagePolicy }
    public var retentionPolicy = RetentionPolicy()
    public static let heartbeatInterval: UInt64 = 600_000_000_000
    public static let keepAliveAfterAudio: UInt64 = 10_000_000_000

    public init(config: EngineConfiguration, settings: SettingsStore, uploadTransport: UploadTransport? = nil, background: BackgroundTaskProviding? = nil) {
        self.config = config
        self.settings = settings
        self.background = background
        queue.sync { setUp(uploadTransport: uploadTransport) }
    }

    // MARK: Setup

    private func setUp(uploadTransport: UploadTransport?) {
        let dirs = config.dirs
        do { try dirs.create() } catch { log(.error, "engine", "cannot create data directories: \(error)") }
        outbox = Outbox(dirs: dirs)
        env = CaptureEnvironment(dirs: dirs, outbox: outbox, clock: config.clock, appVersion: config.appVersion, timezone: config.timezone)
        deviceMemory = DeviceMemory(stateDir: dirs.state)
        cursors = RingCursorStore(stateDir: dirs.state)
        ledger = RingCaptureLedger(dirs: dirs, outbox: outbox)
        enrollmentGate = EnrollmentGate(stateDir: dirs.state, outbox: outbox)
        let writer = EventWriter(outbox: outbox, clock: config.clock)
        enrollmentGate.reemitStart = { h in
            guard let deviceId = h.deviceId, let offset = h.startOffsetUs else { throw EnrollmentError.writeFailed("hold predates rewriting") }
            let item = try writer.voiceEnrollmentStart(enrollmentId: h.enrollmentId, deviceId: deviceId, captureId: h.captureId,
                                                       offsetUs: offset, at: h.startAt)
            guard case .event(let id) = item.kind else { throw EnrollmentError.writeFailed("unexpected outbox item") }
            return id
        }
        processedThrough = JSONFile.load([String: Int].self, from: processedURL) ?? [:]

        // Capture pipeline (objects only; no scanning here).
        let memory = deviceMemory!
        recorder = LiveCaptureRecorder(env: env)
        recorder.codecFallback = { memory.codec(for: $0) }
        recorder.onChunkFinalized = { [weak self] _ in self?.scheduleReconcile() }
        recorder.onSealWritten = { [weak self] _ in self?.scheduleReconcile() }
        ringWriter = RingCaptureWriter(env: env)
        ringWriter.ledger = ledger
        ringWriter.onChunkFinalized = { [weak self] _ in self?.scheduleReconcile() }
        ringWriter.onSealWritten = { [weak self] _ in self?.scheduleReconcile() }
        ring = RingSyncEngine(writer: ringWriter, cursors: cursors)
        ring.onStateChange = { [weak self] _ in self?.scheduleSnapshot() }
        events = EventWriter(outbox: outbox, clock: config.clock)

        let transport: UploadTransport
        if let uploadTransport {
            transport = uploadTransport
        } else {
            let bg = BackgroundSessionTransport(queue: queue)
            backgroundTransport = bg
            transport = bg
        }
        let settings = self.settings
        uploader = Uploader(
            outbox: outbox, state: UploadStateStore(url: dirs.state.appendingPathComponent("upload-state.json")),
            transport: transport, queue: queue, config: { settings.serverConfig() })
        uploader.gate = CompositeUploadGate([ledger, enrollmentGate])
        uploader.enabled = false  // until recovery completes
        uploader.onStatusChange = { [weak self] in self?.scheduleSnapshot() }
        backgroundTransport?.onCompletion = { [weak self] id, status, body, error in
            self?.uploader.handleCompletion(identifier: id, statusCode: status, body: body, error: error)
        }

        // 1. Recovery runs first on the serial engine queue: every Bluetooth and upload callback is
        //    delivered on this queue and therefore queued behind it, but launch is not blocked.
        queue.async { self.runLaunchRecovery() }

        // 2. Restoration infrastructure, synchronously: iOS may have relaunched us for it.
        var suppression: Set<ReconnectSuppression> = []
        if settings.userDisconnected { suppression.insert(.userDisconnected) }
        if settings.simulatedMode { suppression.insert(.simulatedMode) }
        let remembered = settings.rememberedDeviceId.flatMap { $0 == SimulatedDevice.deviceIdentifier ? nil : $0 }
        if let makeBackend = config.testCentralBackend {
            let c = CentralController(queue: queue, rememberedId: remembered, suppression: suppression, backend: makeBackend)
            c.delegate = self
            central = c
        } else if config.useCoreBluetooth {
            let c = CentralController(queue: queue, rememberedId: remembered, suppression: suppression)
            c.delegate = self
            central = c
        }
    }

    private func runLaunchRecovery() {
        config.testBeforeRecovery?()
        let memory = deviceMemory!
        let report = CaptureRecovery.run(env: env, codecFallback: { memory.codec(for: $0) })
        recoveredCaptures = report.liveRecovered.count + report.ringRecovered.count
        for mark in report.ringDurable {
            var c = cursors.load(mark.deviceId)
            if c.generation == mark.generation {
                c.notePersisted(mark.seq)
                try? cursors.save(c, deviceId: mark.deviceId)
            }
        }
        if recoveredCaptures > 0 { log(.warning, "engine", "recovered \(recoveredCaptures) unsealed capture(s) from a previous run") }
        if !report.quarantined.isEmpty {
            addAttention("\(report.quarantined.count) capture journal(s) could not be recovered automatically and were kept in journal/quarantine (nothing was deleted).")
        }
        ledger.prune()
        recoveryComplete = true
        uploader.enabled = true

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + config.tickInterval, repeating: config.tickInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        refreshOutboxStats()
        checkStorage()
        if settings.simulatedMode, settings.rememberedDeviceId == SimulatedDevice.deviceIdentifier, !settings.userDisconnected {
            startSimulatedDevice()
        }
        central?.ensureConnected()
        uploader.reconcile()
        scheduleSnapshot()
    }

    /// Test access to the central's backend event entry points.
    var centralEventsForTesting: CentralBackendEvents? { central }

    private var processedURL: URL { config.dirs.state.appendingPathComponent("processed-through.json") }

    // MARK: Public API (thread-safe)

    public func setSnapshotSink(_ sink: @escaping @Sendable (EngineSnapshot) -> Void) {
        queue.async {
            self.snapshotSink = sink
            sink(self.buildSnapshot())
        }
    }

    public func startScan() {
        queue.async {
            self.scanResults.removeAll()
            self.scanning = true
            if self.settings.simulatedMode {
                self.scanResults[SimulatedDevice.deviceIdentifier] = ScanCandidate(
                    id: SimulatedDevice.deviceIdentifier, name: "Omi (Simulated)", rssi: -42, lastSeen: Date())
            }
            self.central?.startScan()
            self.scheduleSnapshot()
        }
    }

    public func stopScan() {
        queue.async {
            self.scanning = false
            self.central?.stopScan()
            self.scheduleSnapshot()
        }
    }

    /// Remember a device and connect to it.
    public func pair(id: UUID, name: String?) {
        queue.async {
            self.scanning = false
            self.central?.stopScan()
            self.settings.rememberedDeviceId = id
            self.settings.rememberedDeviceName = name
            self.settings.userDisconnected = false
            self.refusal = nil
            for r in [ReconnectSuppression.userDisconnected, .pairingLost, .unsupportedDevice] { self.central?.unsuppress(r) }
            if id == SimulatedDevice.deviceIdentifier {
                self.startSimulatedDevice()
            } else {
                self.central?.rememberedId = id
                self.central?.connect(to: id)
            }
            log(.info, "engine", "paired with \(name ?? id.uuidString)")
            self.scheduleSnapshot()
        }
    }

    public func disconnect() {
        queue.async {
            self.settings.userDisconnected = true
            self.central?.suppress(.userDisconnected)
            self.simReconnectWork?.cancel()
            self.stopSession(reason: .userStopped, why: "user disconnected")
            self.scheduleSnapshot()
        }
    }

    public func reconnect() {
        queue.async {
            self.settings.userDisconnected = false
            self.refusal = nil
            for r in [ReconnectSuppression.userDisconnected, .pairingLost, .unsupportedDevice] { self.central?.unsuppress(r) }
            self.attention.removeAll { $0.contains("pairing") }
            if self.settings.rememberedDeviceId == SimulatedDevice.deviceIdentifier, self.settings.simulatedMode {
                self.connectSimulated(after: 0.3)
            } else {
                self.central?.ensureConnected()
            }
            self.scheduleSnapshot()
        }
    }

    public func forgetDevice() {
        queue.async {
            self.simReconnectWork?.cancel()
            self.stopSession(reason: .deviceForgotten, why: "device forgotten")
            self.central?.forget()
            self.simulated = nil
            self.settings.rememberedDeviceId = nil
            self.settings.rememberedDeviceName = nil
            self.settings.userDisconnected = false
            self.refusal = nil
            for r in [ReconnectSuppression.userDisconnected, .pairingLost, .unsupportedDevice] { self.central?.unsuppress(r) }
            self.scheduleSnapshot()
        }
    }

    public func setSimulatedMode(_ on: Bool) {
        queue.async {
            guard on != self.settings.simulatedMode else { return }
            self.settings.simulatedMode = on
            if on {
                self.central?.suppress(.simulatedMode)
                self.stopSession(reason: .userStopped, why: "switched to simulated device")
                self.settings.rememberedDeviceId = SimulatedDevice.deviceIdentifier
                self.settings.rememberedDeviceName = "Omi (Simulated)"
                self.settings.userDisconnected = false
                self.startSimulatedDevice()
            } else {
                self.simReconnectWork?.cancel()
                if self.session?.transport.isSimulated == true {
                    self.stopSession(reason: .userStopped, why: "simulated device off")
                }
                self.simulated = nil
                if self.settings.rememberedDeviceId == SimulatedDevice.deviceIdentifier {
                    self.settings.rememberedDeviceId = nil
                    self.settings.rememberedDeviceName = nil
                }
                self.central?.unsuppress(.simulatedMode)
                self.central?.rememberedId = self.settings.rememberedDeviceId
                self.central?.ensureConnected()
            }
            self.scheduleSnapshot()
        }
    }

    /// Debug: the simulated device walks out of range (auto-returns after `returnAfter` seconds).
    public func simulateOutOfRange(returnAfter: TimeInterval = 15) {
        queue.async {
            guard let sim = self.simulated, self.session?.transport === sim else { return }
            sim.linkDown()
            self.endSession(reason: .bleDisconnected)
            self.connectSimulated(after: returnAfter)
        }
    }

    public func simulateButton(code: Int32) {
        queue.async { self.simulated?.press(code) }
    }

    public func forceRotate() {
        queue.async {
            self.withBackgroundTask("rotate") { self.recorder.rotateNow(reason: .forced) }
        }
    }

    public func configureServer(url: URL, token: String) throws {
        try settings.setServer(url: url, token: token)
        log(.info, "engine", "server set to \(url.absoluteString)")
        queue.async {
            self.uploader.serverConfigurationChanged()
            self.scheduleSnapshot()
        }
    }

    public func retryUploads() {
        queue.async { self.uploader.retryNow() }
    }

    public func requeueQuarantined() {
        queue.async {
            for item in self.outbox.quarantined() { try? self.outbox.requeueQuarantined(item.name) }
            self.refreshOutboxStats()
            self.uploader.retryNow()
        }
    }

    public func clearAttention() {
        queue.async {
            self.attention.removeAll()
            self.uploader.clearAttention()
            self.scheduleSnapshot()
        }
    }

    public func runRetentionNow() { queue.async { self.runRetention() } }

    // MARK: Voice enrollment (docs/speaker-learning.md, "Enrollment")

    public enum EnrollmentError: Error, LocalizedError, Equatable {
        case notRecording, alreadyRunning, writeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notRecording: return "The pendant isn't streaming audio yet. Wear it, wait for Recording, then try again."
            case .alreadyRunning: return "A voice enrollment is already running."
            case .writeFailed(let why): return "Could not start enrollment: \(why)"
            }
        }
    }

    /// Opens an enrollment window on the live capture: journals `voice_enrollment_start` and holds
    /// the capture's chunks from here until the server acknowledges it. Returns the enrollment id.
    public func startVoiceEnrollment() throws -> String {
        try queue.sync { try self.startEnrollment() }
    }

    private func startEnrollment() throws -> String {
        do {
            guard activeEnrollment == nil else { throw EnrollmentError.alreadyRunning }
            guard let s = session, recorder.isActive, let captureId = recorder.captureId, let offset = recorder.nowOffsetUs() else {
                throw EnrollmentError.notRecording
            }
            let id = UUID().uuidString.lowercased()
            let at = ISO8601UTC.format(config.clock.wallNow())
            do {
                let item = try events.voiceEnrollmentStart(enrollmentId: id, deviceId: s.deviceId, captureId: captureId, offsetUs: offset, at: at)
                guard case .event(let eventId) = item.kind else { throw EnrollmentError.writeFailed("unexpected outbox item") }
                try enrollmentGate.hold(.init(
                    enrollmentId: id, captureId: captureId, fromSequence: recorder.stats.chunkSequence,
                    startEventId: eventId, endEventId: nil, deviceId: s.deviceId, startAt: at, startOffsetUs: offset))
            } catch let e as EnrollmentError {
                throw e
            } catch {
                throw EnrollmentError.writeFailed("\(error)")
            }
            activeEnrollment = ActiveEnrollment(id: id, captureId: captureId, deviceId: s.deviceId)
            log(.info, "enrollment", "voice enrollment \(id) started at \(offset) µs of \(captureId)")
            scheduleReconcile()
            scheduleSnapshot()
            return id
        }
    }

    /// Closes the window (`voice_enrollment_end`) and rotates the chunk so the audio uploads.
    public func finishVoiceEnrollment(outcome: VoiceEnrollmentEndData.Outcome) {
        queue.async { self.finishEnrollment(outcome: outcome) }
    }

    private func finishEnrollment(outcome: VoiceEnrollmentEndData.Outcome) {
        guard let e = activeEnrollment else { return }
        activeEnrollment = nil
        guard recorder.captureId == e.captureId, let end = recorder.nowOffsetUs() else {
            log(.warning, "enrollment", "capture of enrollment \(e.id) already ended; no end event")
            return
        }
        do {
            let item = try events.voiceEnrollmentEnd(
                enrollmentId: e.id, deviceId: e.deviceId, captureId: e.captureId, endOffsetUs: end, outcome: outcome)
            if case .event(let eventId) = item.kind { enrollmentGate.attachEndEvent(enrollmentId: e.id, endEventId: eventId) }
        } catch {
            log(.error, "enrollment", "end event write failed: \(error)")
        }
        if outcome != .interrupted {
            withBackgroundTask("enrollment-rotate") { recorder.rotateNow(reason: .forced) }
        }
        log(.info, "enrollment", "voice enrollment \(e.id) ended (\(outcome.rawValue)) at \(end) µs")
        scheduleReconcile()
        scheduleSnapshot()
    }

    public func sendHeartbeatNow() { queue.async { self.writeHeartbeat(reason: "manual") } }

    // MARK: Lifecycle

    public func appDidBecomeActive() {
        queue.async {
            self.appActive = true
            self.endKeepAlive()
            self.central?.ensureConnected()  // re-kick a pending connect on foreground
            self.uploader.reconcile()
            if self.session?.phase == .streaming { self.writeHeartbeat(reason: "foreground") }
            self.checkStorage()
            self.runRetention()
            self.scheduleSnapshot()
        }
    }

    public func appDidEnterBackground() {
        queue.async {
            self.appActive = false
            self.recorder.syncNow()
            guard self.session != nil else { return }
            // iOS may suspend us right away (e.g. during a silent stretch, when no notification will
            // wake us for the idle rotation). Close the open chunk now so the background URLSession
            // owns its upload, and stay awake briefly so the hand-off completes.
            self.beginKeepAlive()
            if self.recorder.stats.chunkRecords > 0 {
                self.withBackgroundTask("lifecycle-rotate") { self.recorder.rotateNow(reason: .lifecycle) }
            }
            self.refreshOutboxStats()
            self.uploader.reconcile()
        }
    }

    public func appWillTerminate() {
        queue.sync {
            self.withBackgroundTask("terminate") {
                self.session?.prepareForDisconnect(reason: "app terminating")
                self.endSession(reason: .bleDisconnected)
            }
        }
    }

    /// Stores UIKit's completion handler; it is called exactly once on main when the session has
    /// delivered its events (even if that already happened before registration).
    public func handleBackgroundSessionEvents(identifier: String, completion: @escaping @Sendable () -> Void) {
        guard identifier == BackgroundSessionTransport.sessionIdentifier, let bg = backgroundTransport else {
            DispatchQueue.main.async { completion() }
            return
        }
        bg.eventsLatch.register(completion)
    }

    /// Protected data became available (first unlock): retry a Keychain read that failed earlier.
    public func protectedDataDidBecomeAvailable() {
        settings.invalidateTokenCache()
        queue.async { self.uploader.reconcile() }
    }

    // MARK: Session management

    private func startSession(_ transport: DeviceTransport) {
        guard recoveryComplete, !storageTripped else {
            log(.warning, "engine", "refusing session: \(storageTripped ? "storage guard tripped" : "recovery not finished")")
            if transport.isSimulated { simulated?.linkDown() } else { central?.disconnect() }
            return
        }
        if let old = session { old.end(reason: .bleDisconnected) }
        let s = DeviceSession(transport: transport, recorder: recorder, ring: ring, clock: config.clock)
        s.delegate = self
        let memory = deviceMemory!
        let id = s.deviceId
        s.onCodecLearned = { memory.remember(codec: $0.rawValue, for: id) }
        s.onAudioNotification = { [weak self] in self?.noteAudio() }
        session = s
        refusal = nil
        pendingDisconnectReason = nil
        s.start()
        uploader.reconcile()
        scheduleSnapshot()
    }

    private func endSession(reason: SealReason) {
        guard let s = session else { return }
        // Close an open enrollment window while the capture (and its clock) still exists.
        finishEnrollment(outcome: .interrupted)
        let r = pendingDisconnectReason ?? reason
        pendingDisconnectReason = nil
        session = nil
        withBackgroundTask("seal") { s.end(reason: r) }
        refreshOutboxStats()
        scheduleSnapshot()
    }

    /// Deliberate stop: interrupt ring sync, seal the capture, then drop the link.
    private func stopSession(reason: SealReason, why: String) {
        session?.prepareForDisconnect(reason: why)
        let transport = session?.transport
        endSession(reason: reason)
        if let transport, transport.isSimulated {
            simulated?.linkDown()
        } else {
            central?.disconnect()
        }
    }

    private func startSimulatedDevice() {
        if simulated == nil {
            let trace = config.simulatedTrace ?? SimulatedTrace.synthetic()
            simulated = SimulatedDevice(queue: queue, clock: config.clock, trace: trace)
        }
        connectSimulated(after: 0.5)
    }

    private func connectSimulated(after delay: TimeInterval) {
        simReconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let sim = self.simulated, self.settings.simulatedMode, !self.settings.userDisconnected,
                  !self.storageTripped, self.session == nil else { return }
            sim.linkUp()
            self.startSession(sim)
        }
        simReconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: CentralControllerDelegate

    public func centralDidUpdateState(_ state: CentralState) {
        btState = state
        if state != .poweredOn, let s = session, !s.transport.isSimulated { endSession(reason: .bleDisconnected) }
        scheduleSnapshot()
    }

    public func centralDidDiscover(_ candidate: ScanCandidate) {
        guard scanning else { return }
        scanResults[candidate.id] = candidate
        scheduleSnapshot()
    }

    public func centralDidConnect(_ transport: DeviceTransport) {
        if settings.simulatedMode || storageTripped {
            log(.warning, "engine", "dropping accepted link (\(storageTripped ? "storage guard" : "simulated mode"))")
            central?.disconnect()
            return
        }
        startSession(transport)
    }

    public func centralDidDisconnect(_ identifier: UUID, error: Error?, pairingLost: Bool) {
        if let s = session, s.transport.identifier == identifier, !s.transport.isSimulated {
            endSession(reason: .bleDisconnected)
        }
        if pairingLost { notePairingLost() }
        scheduleSnapshot()
    }

    public func centralDidFailToConnect(_ identifier: UUID, error: Error?, pairingLost: Bool) {
        if pairingLost { notePairingLost() }
        scheduleSnapshot()
    }

    private func notePairingLost() {
        addAttention("iOS reports the device's pairing information was removed. Open Settings › Bluetooth, forget the Omi, then tap Reconnect.")
    }

    // MARK: DeviceSessionDelegate

    public func sessionDidChange(_ session: DeviceSession) { scheduleSnapshot() }

    public func sessionDidStartCapture(_ session: DeviceSession) { scheduleSnapshot() }

    public func sessionDidBecomeReady(_ session: DeviceSession) {
        if settings.rememberedDeviceName == nil { settings.rememberedDeviceName = session.info.name }
        writeHeartbeat(reason: "connect")
        scheduleSnapshot()
    }

    public func session(_ session: DeviceSession, didReceiveButton event: ButtonEvent) {
        guard let code = event.uploadCode else {
            log(.debug, "engine", "button event \(event) ignored")
            return
        }
        do {
            try events.button(code: code, deviceId: session.deviceId, captureId: recorder.captureId, offsetUs: recorder.nowOffsetUs())
        } catch {
            log(.error, "engine", "button event write failed: \(error)")
        }
        if event == .doubleTap {
            withBackgroundTask("double-tap") { recorder.rotateNow(reason: .doubleTap) }
        }
        lastButton = "\(code == 1 ? "Bookmark" : "End conversation") at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"
        log(.info, "engine", "button \(code == 1 ? "single tap (bookmark)" : "double tap (split)")")
        scheduleReconcile()
    }

    public func session(_ session: DeviceSession, requestsDisconnect reason: String, suppressReconnect: Bool) {
        refusal = reason
        if suppressReconnect { central?.suppress(.unsupportedDevice) }
        addAttention("Not recording: \(reason)")
        pendingDisconnectReason = .userStopped
        let transport = session.transport
        endSession(reason: .userStopped)
        if transport.isSimulated { simulated?.linkDown() } else { central?.disconnect() }
    }

    public func sessionDidHitStorageError(_ session: DeviceSession) {
        tripStorageGuard(reason: "a journal write failed (out of space)")
    }

    public func sessionDidWakeAfterSilence(_ session: DeviceSession) {
        writeHeartbeat(reason: "wake")
    }

    public func session(_ session: DeviceSession, requestsReconnect reason: String) {
        addAttention("Reconnecting to the device: \(reason)")
        let transport = session.transport
        pendingDisconnectReason = .bleDisconnected
        endSession(reason: .bleDisconnected)
        if transport.isSimulated {
            simulated?.linkDown()
            connectSimulated(after: 1)
        } else {
            central?.disconnect()  // not suppressed: the central reconnects 200 ms after didDisconnect
        }
    }

    // MARK: Events / heartbeats

    private func writeHeartbeat(reason: String) {
        let deviceId = session?.deviceId ?? settings.rememberedDeviceId?.uuidString.lowercased()
        guard let deviceId else { return }
        let info = session?.info
        refreshOutboxStats()
        let data = HeartbeatData(
            battery: info?.battery, charging: info?.charging, firmwareRevision: info?.firmwareRevision,
            modelNumber: info?.modelNumber, rtcValid: info?.rtcValid, offlineUnread: info?.offlineUnread,
            outboxChunks: outboxStats.pendingChunks, outboxBytes: outboxStats.pendingBytes,
            appState: appActive ? "foreground" : "background", coverage: recorder.coverage())
        do {
            try events.heartbeat(deviceId: deviceId, data: data)
            lastHeartbeatMono = config.clock.monotonicNanoseconds()
            log(.debug, "engine", "heartbeat (\(reason))")
        } catch {
            log(.error, "engine", "heartbeat write failed: \(error)")
        }
        scheduleReconcile()
    }

    // MARK: Keep-alive (background)

    private func noteAudio() {
        lastAudioMono = config.clock.monotonicNanoseconds()
        // Stay awake a little past the last notification so the 5 s idle rotation can run.
        if !appActive, keepAliveTask == nil { beginKeepAlive() }
    }

    private func beginKeepAlive() {
        keepAliveSinceMono = config.clock.monotonicNanoseconds()
        guard keepAliveTask == nil else { return }
        keepAliveTask = background?.beginTask(name: "omi-keepalive") { [weak self] in
            guard let self else { return }
            self.queue.async { self.endKeepAlive() }
        }
    }

    private func endKeepAlive() {
        if let id = keepAliveTask { background?.endTask(id) }
        keepAliveTask = nil
    }

    private func withBackgroundTask(_ name: String, _ body: () -> Void) {
        let id = background?.beginTask(name: name) {}
        body()
        if let id { background?.endTask(id) }
    }

    // MARK: Tick

    private func tick() {
        tickCount += 1
        let now = config.clock.monotonicNanoseconds()
        session?.tick()
        if keepAliveTask != nil, now &- max(lastAudioMono, keepAliveSinceMono) >= Self.keepAliveAfterAudio {
            recorder.syncNow()
            endKeepAlive()
        }
        if session?.phase == .streaming, now &- lastHeartbeatMono >= Self.heartbeatInterval {
            writeHeartbeat(reason: "periodic")
        }
        if tickCount % 30 == 0 { checkStorage() }
        if tickCount % 5 == 0 { refreshOutboxStats() }
        if tickCount % 3600 == 0 { runRetention() }
        if session != nil || tickCount % 5 == 0 { scheduleSnapshot() }
    }

    // MARK: Storage guard

    private func checkStorage() {
        freeBytes = FileIO.freeBytes(at: config.dirs.root)
        switch storagePolicy.evaluate(freeBytes: freeBytes, tripped: storageTripped) {
        case .trip: tripStorageGuard(reason: "less than 200 MB free")
        case .recover:
            storageTripped = false
            attention.removeAll { $0.hasPrefix("Phone storage low") }
            central?.unsuppress(.storageLow)
            log(.info, "engine", "storage recovered; reconnecting")
            if settings.simulatedMode { connectSimulated(after: 0.5) } else { central?.ensureConnected() }
        case .ok, .stayTripped: break
        }
    }

    private func tripStorageGuard(reason: String) {
        guard !storageTripped else { return }
        storageTripped = true
        log(.error, "engine", "storage guard: \(reason); stopping capture so the device buffers to its own storage")
        addAttention("Phone storage low (\(reason)). Recording paused; the device keeps audio on its own storage until space is freed.")
        applyRetention()
        central?.suppress(.storageLow)
        stopSession(reason: .userStopped, why: "phone storage low")
    }

    // MARK: Retention

    private func sentFiles() -> [RetentionPolicy.SentFile] {
        outbox.sent().map { .init(name: $0.name, kind: $0.kind, size: $0.size, sentAt: $0.modified) }
    }

    private func runRetention() {
        let sent = sentFiles()
        let need = retentionPolicy.capturesNeedingStatus(sent: sent, known: processedThrough, now: config.clock.wallNow())
        guard let endpoint = settings.endpoint, !need.isEmpty else {
            applyRetention()
            return
        }
        let ids = Array(need.prefix(40))
        Task.detached { [weak self] in
            let api = APIClient(endpoint: endpoint)
            var results: [String: Int] = [:]
            for id in ids {
                if let s = try? await api.captureStatus(id) { results[id] = s.processedThrough }
            }
            let found = results
            guard let engine = self else { return }
            engine.queue.async {
                engine.processedThrough.merge(found) { _, new in new }
                engine.applyRetention()
            }
        }
    }

    private func applyRetention() {
        let pins = CaptureRecovery.retentionPins(env: env)
        let sent = sentFiles().filter { !CaptureRecovery.isPinned($0.kind, pins: pins) }
        let names = retentionPolicy.filesToDelete(sent: sent, processedThrough: processedThrough, now: config.clock.wallNow())
        for n in names { outbox.deleteSent(n) }
        if !names.isEmpty { log(.info, "retention", "deleted \(names.count) acknowledged file(s) from sent/") }
        let live = Set(outbox.sent().compactMap { $0.kind.captureId })
        processedThrough = processedThrough.filter { live.contains($0.key) }
        try? JSONFile.save(processedThrough, to: processedURL)
        refreshOutboxStats()
    }

    // MARK: Snapshot

    private func addAttention(_ message: String) {
        if !attention.contains(message) { attention.append(message) }
        scheduleSnapshot()
    }

    private func refreshOutboxStats() {
        outboxStats = outbox.stats()
        quarantined = outbox.quarantined().map { item in
            "\(item.name): \(outbox.quarantineReason(item.name) ?? "kept")"
        }
    }

    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.reconcilePending = false
            self.refreshOutboxStats()
            self.uploader.reconcile()
            self.scheduleSnapshot()
        }
    }

    private func scheduleSnapshot() {
        guard !snapshotPending, snapshotSink != nil else { return }
        snapshotPending = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.snapshotPending = false
            self.snapshotSink?(self.buildSnapshot())
        }
    }

    /// Current state (call on the engine queue; tests use `snapshotNow()`).
    func buildSnapshot() -> EngineSnapshot {
        var s = EngineSnapshot()
        s.bluetooth = btState
        s.simulated = settings.simulatedMode
        s.rememberedDeviceId = settings.rememberedDeviceId?.uuidString.lowercased()
        s.rememberedDeviceName = settings.rememberedDeviceName
        s.device = session?.info
        if let sess = session {
            var l = LiveSnapshot()
            l.captureId = recorder.captureId
            l.chunkSequence = recorder.stats.chunkSequence
            l.chunkRecords = recorder.stats.chunkRecords
            l.totalRecords = recorder.stats.totalRecords
            l.notificationsPerSecond = sess.stats.notificationsPerSecond
            l.lossPercent = sess.stats.lossPercent
            l.received = sess.stats.received
            l.lost = sess.stats.lost
            l.lastNotificationAt = sess.stats.lastNotificationAt
            s.live = l
        }
        s.offline = ring.state
        s.outbox = outboxStats
        s.upload = uploader.status
        s.freeBytes = freeBytes
        s.storageTripped = storageTripped
        s.scanning = scanning
        s.scanResults = scanResults.values.sorted { $0.rssi > $1.rssi }
        s.attention = attention + uploader.status.attention
        s.serverConfigured = settings.endpoint != nil
        s.lastButton = lastButton
        s.recoveredCaptures = recoveredCaptures
        s.quarantined = quarantined
        s.activeEnrollmentId = activeEnrollment?.id
        s.connection = connectionPhase()
        return s
    }

    public func snapshotNow() -> EngineSnapshot { queue.sync { buildSnapshot() } }

    private func connectionPhase() -> ConnectionPhase {
        if let refusal { return .refused(refusal) }
        if let sess = session {
            switch sess.phase {
            case .streaming: return .streaming
            case .refused(let r): return .refused(r)
            case .ended: break
            default: return .settingUp
            }
        }
        if settings.rememberedDeviceId == nil { return .noDevice }
        if storageTripped { return .paused("phone storage low") }
        if settings.userDisconnected { return .paused("disconnected by you") }
        if settings.simulatedMode { return .waitingForDevice }
        switch btState {
        case .poweredOn: break
        case .unknown: return .bluetoothUnavailable("starting")
        case .poweredOff: return .bluetoothUnavailable("off")
        case .unauthorized: return .bluetoothUnavailable("not allowed — enable it in Settings")
        case .unsupported: return .bluetoothUnavailable("unsupported (Simulator? use the simulated device)")
        case .resetting: return .bluetoothUnavailable("resetting")
        }
        if central?.suppression.contains(.pairingLost) == true { return .paused("pairing information removed") }
        return .waitingForDevice
    }
}
