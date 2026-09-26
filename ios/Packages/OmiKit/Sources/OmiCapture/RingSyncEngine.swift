import Foundation
import OmiProtocol

/// What the ring sync needs from the BLE connection. Results come back through the engine's
/// `handle…` methods (possibly synchronously).
public protocol RingTransport: AnyObject {
    /// Read `30295782` → `handleStatusRead`.
    func ringReadStatus()
    /// Subscribe to `30295781` → `handleNotificationsEnabled`.
    func ringEnableNotifications()
    /// Write to `30295781` (with response) → `handleWriteResult`.
    func ringWrite(_ command: Data)
}

public struct RingSyncContext: Sendable {
    public var meta: CaptureDeviceMeta
    public var codecId: Int
    /// Storage service and both characteristics exist.
    public var hasStorageService: Bool
    public var hasFeaturesCharacteristic: Bool
    public var features: DeviceFeatures?
    /// When the live connection that started this sync began (`covers_until`).
    public var reconnectedAt: Date

    public init(meta: CaptureDeviceMeta, codecId: Int, hasStorageService: Bool, hasFeaturesCharacteristic: Bool, features: DeviceFeatures?, reconnectedAt: Date) {
        self.meta = meta
        self.codecId = codecId
        self.hasStorageService = hasStorageService
        self.hasFeaturesCharacteristic = hasFeaturesCharacteristic
        self.features = features
        self.reconnectedAt = reconnectedAt
    }
}

public enum RingSyncState: Equatable, Sendable {
    case idle
    case detecting
    case unsupported(String)
    case requestingInfo
    case starting
    case receiving(received: Int, total: Int)
    case complete(records: Int)
    case interrupted(String)
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .detecting, .requestingInfo, .starting, .receiving: return true
        default: return false
        }
    }
}

/// Offline ring sync over an abstract transport (device-protocol.md "Offline storage").
///
/// Detection order — nothing is written until all of these pass: storage service present,
/// firmware ≥ 3.0.20 and features bit 6, status read of exactly 16 bytes. Then INFO (record size
/// must be 444) → READ(read_seq, 0) → reassemble → drop seq ≤ last persisted → journal + fsync
/// ≥ 1×/s → on DONE status 0: fsync, ADVANCE(next_seq), seal `sync_complete` with ring evidence.
/// Disconnect / error / timeout: keep what is persisted, seal `sync_interrupted`.
///
/// Confined to the engine queue.
public final class RingSyncEngine {
    enum Phase: Equatable {
        case idle, awaitingStatus, awaitingNotifyEnable, awaitingInfo, awaitingReadBegin, receiving, finished
    }

    public struct Timeouts: Sendable {
        public var status: TimeInterval = 10
        public var info: TimeInterval = 15
        public var readBegin: TimeInterval = 15
        public var dataIdle: TimeInterval = 20
        public init() {}
    }

    public let writer: RingCaptureWriter
    public let cursors: RingCursorStore
    public weak var transport: RingTransport?
    public var timeouts = Timeouts()
    public var onStateChange: ((RingSyncState) -> Void)?
    public var onStatus: ((RingProtocol.Status) -> Void)?
    public var onSupportDetermined: ((OfflineStorageSupport) -> Void)?

    public private(set) var state: RingSyncState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public private(set) var status: RingProtocol.Status?
    public private(set) var info: RingProtocol.Info?
    public private(set) var duplicatesDropped = 0
    public private(set) var recordsPersisted = 0
    /// Commands written this session (tests assert that unsupported devices get none).
    public private(set) var commandsWritten: [Data] = []

    private var phase: Phase = .idle
    private var ctx: RingSyncContext?
    private var cursor = RingCursor()
    private var reassembler = RingRecordReassembler()
    private var startSeq: UInt64 = 0
    private var reassembled = 0
    private var expectedTotal = 0
    private var deadline: UInt64?
    private var clock: CaptureClock { writer.env.clock }

    public init(writer: RingCaptureWriter, cursors: RingCursorStore) {
        self.writer = writer
        self.cursors = cursors
    }

    public var isBusy: Bool { phase != .idle && phase != .finished }

    public func start(_ context: RingSyncContext) {
        resetSession()
        ctx = context
        let support = OfflineStorageSupport.staticCheck(
            hasStorageService: context.hasStorageService, firmwareRevision: context.meta.firmwareRevision,
            features: context.features, hasFeaturesCharacteristic: context.hasFeaturesCharacteristic)
        onSupportDetermined?(support)
        switch support {
        case .supported: break
        case .unsupported(let why):
            unsupported(why)
            return
        case .unknown:
            // Metadata unreadable: touch nothing; the session retries detection later.
            state = .idle
            return
        }
        cursor = cursors.load(context.meta.deviceId)
        phase = .awaitingStatus
        state = .detecting
        arm(timeouts.status)
        transport?.ringReadStatus()
    }

    // MARK: Transport callbacks

    public func handleStatusRead(_ data: Data?, error: Error?) {
        guard phase == .awaitingStatus else { return }
        guard let data, error == nil else {
            fail("storage status read failed\(error.map { ": \($0.localizedDescription)" } ?? "")")
            return
        }
        switch RingProtocol.parseStatus(data) {
        case .legacy:
            unsupported("legacy storage protocol (8-byte status)")
        case .invalid(let n):
            unsupported("unexpected storage status length \(n)")
        case .ring(let s):
            status = s
            onStatus?(s)
            phase = .awaitingNotifyEnable
            arm(timeouts.status)
            transport?.ringEnableNotifications()
        }
    }

    public func handleNotificationsEnabled(error: Error?) {
        guard phase == .awaitingNotifyEnable else { return }
        if let error {
            fail("storage notifications unavailable: \(error.localizedDescription)")
            return
        }
        phase = .awaitingInfo
        state = .requestingInfo
        arm(timeouts.info)
        write(RingProtocol.infoCommand())
    }

    public func handleWriteResult(error: Error?) {
        guard let error else { return }
        switch phase {
        case .awaitingInfo: fail("INFO write failed: \(error.localizedDescription)")
        case .awaitingReadBegin, .receiving: interrupt("READ write failed: \(error.localizedDescription)", sendStop: false)
        default: log(.warning, "ring", "storage write error: \(error.localizedDescription)")
        }
    }

    public func handleNotification(_ data: Data) {
        switch RingProtocol.parseNotification(data) {
        case .info(let i):
            guard phase == .awaitingInfo else { log(.debug, "ring", "ignoring late INFO"); return }
            guard Int(i.recordSize) == RingProtocol.recordSize else {
                unsupported("record size \(i.recordSize) ≠ 444")
                return
            }
            handleInfo(i)
        case .ack(let s):
            switch phase {
            case .awaitingInfo:
                if s != RingProtocol.StatusCode.ok { fail("INFO rejected: \(RingProtocol.StatusCode.describe(s))") }
            case .awaitingReadBegin, .receiving:
                if s != RingProtocol.StatusCode.ok {
                    interrupt("READ rejected: \(RingProtocol.StatusCode.describe(s))", sendStop: false)
                }
            default:
                log(.info, "ring", "ACK \(RingProtocol.StatusCode.describe(s))")
            }
        case .readBegin(let rb):
            guard phase == .awaitingReadBegin else { return }
            guard let info, rb.startSeq == startSeq, UInt64(rb.count) == info.writeSeq &- startSeq else {
                interrupt("READ_BEGIN [\(rb.startSeq), +\(rb.count)) does not match the requested range [\(startSeq), \(info?.writeSeq ?? 0))", sendStop: true)
                return
            }
            expectedTotal = Int(rb.count)
            phase = .receiving
            state = .receiving(received: 0, total: expectedTotal)
            arm(timeouts.dataIdle)
        case .data(let bytes):
            guard phase == .awaitingReadBegin || phase == .receiving else { return }
            if phase == .awaitingReadBegin {
                phase = .receiving  // READ_BEGIN missing: records start at the requested read_seq
            }
            receive(bytes)
        case .done(let d):
            guard phase == .receiving || phase == .awaitingReadBegin else { return }
            let expectedNext = startSeq &+ UInt64(reassembled)
            if d.status != RingProtocol.StatusCode.ok {
                interrupt("DONE with \(RingProtocol.StatusCode.describe(d.status))", sendStop: false)
            } else if reassembler.pendingBytes != 0 {
                interrupt("DONE with \(reassembler.pendingBytes) stray bytes", sendStop: false)
            } else if d.nextSeq != expectedNext {
                interrupt("DONE next_seq \(d.nextSeq) ≠ expected \(expectedNext)", sendStop: false)
            } else if let info, d.nextSeq < info.writeSeq {
                // The firmware doesn't write to storage while connected, so a complete transfer
                // reaches the INFO snapshot's write_seq; anything short of it is a partial sync.
                interrupt("transfer ended at \(d.nextSeq) before INFO write_seq \(info.writeSeq)", sendStop: false)
            } else {
                complete(nextSeq: d.nextSeq)
            }
        case .malformed(let op, let len):
            log(.warning, "ring", "malformed storage notification op=\(op.map { String($0) } ?? "nil") len=\(len)")
        }
    }

    public func handleDisconnect() {
        switch phase {
        case .awaitingReadBegin, .receiving:
            interrupt("disconnected", sendStop: false)
        case .awaitingStatus, .awaitingNotifyEnable, .awaitingInfo:
            phase = .idle
            state = .interrupted("disconnected before sync started")
        default:
            break
        }
    }

    /// User disconnect / storage guard: stop cleanly.
    public func stop(reason: String) {
        switch phase {
        case .awaitingReadBegin, .receiving: interrupt(reason, sendStop: true)
        case .awaitingStatus, .awaitingNotifyEnable, .awaitingInfo:
            phase = .idle
            state = .interrupted(reason)
        default: break
        }
    }

    /// 1 Hz: fsync cadence + timeouts.
    public func tick() {
        if phase == .receiving || phase == .awaitingReadBegin {
            do { try persistIfDue(force: false) } catch {
                interrupt("could not persist offline audio: \(error)", sendStop: true)
                return
            }
        }
        guard let deadline, clock.monotonicNanoseconds() >= deadline else { return }
        switch phase {
        case .awaitingStatus: fail("storage status read timed out")
        case .awaitingNotifyEnable: fail("storage notification subscribe timed out")
        case .awaitingInfo: fail("no INFO response")
        case .awaitingReadBegin: interrupt("no data after READ", sendStop: true)
        case .receiving: interrupt("data stalled", sendStop: true)
        default: self.deadline = nil
        }
    }

    // MARK: Internals

    private func handleInfo(_ i: RingProtocol.Info) {
        guard let ctx else { return }
        info = i
        onSupportDetermined?(.supported)
        if cursor.observe(info: i) {
            log(.warning, "ring", "ring sequences went backwards (write \(i.writeSeq)); generation → \(cursor.generation)")
        }
        if let lp = cursor.lastPersistedSeq, i.readSeq > lp &+ 1 {
            log(.warning, "ring", "gap: device read_seq \(i.readSeq) > last persisted \(lp) + 1 (\(i.readSeq - lp - 1) records never received)")
        }
        if i.dropped > 0 { log(.warning, "ring", "device reports \(i.dropped) records overwritten before sync") }
        do { try cursors.save(cursor, deviceId: ctx.meta.deviceId) } catch {
            fail("could not persist ring cursor: \(error)")
            return
        }
        let wctx = RingCaptureWriter.Context(
            meta: ctx.meta, codecId: ctx.codecId, info: i, generation: cursor.generation,
            rtcValid: status?.rtcValid ?? false, coversUntil: ctx.reconnectedAt)
        do {
            try writer.begin(wctx)
        } catch {
            fail("could not start ring capture: \(error)")
            return
        }
        if i.unread == 0 {
            // Nothing recorded while disconnected: an empty sync_complete capture resolves the gap now.
            do {
                try writer.finish(reason: .syncComplete, doneNextSeq: i.writeSeq)
                phase = .finished
                deadline = nil
                state = .complete(records: 0)
            } catch {
                fail("could not seal empty ring capture: \(error)")
            }
            return
        }
        startSeq = i.readSeq
        expectedTotal = Int(i.unread)
        phase = .awaitingReadBegin
        state = .starting
        arm(timeouts.readBegin)
        write(RingProtocol.readCommand(startSeq: i.readSeq, count: 0))
    }

    private func receive(_ bytes: Data) {
        for record in reassembler.append(bytes) {
            let seq = startSeq &+ UInt64(reassembled)
            reassembled += 1
            if cursor.isDuplicate(seq) {
                duplicatesDropped += 1
                continue
            }
            do {
                try writer.append(seq: seq, record: record)
                recordsPersisted += 1
            } catch {
                interrupt("journal write failed: \(error)", sendStop: true)
                return
            }
        }
        do { try persistIfDue(force: false) } catch {
            interrupt("could not persist offline audio: \(error)", sendStop: true)
            return
        }
        arm(timeouts.dataIdle)
        state = .receiving(received: reassembled, total: max(expectedTotal, reassembled))
    }

    /// fsync the journal (when due) and then persist the dedupe cursor — never ahead of the data.
    private func persistIfDue(force: Bool) throws {
        guard let ctx, writer.isActive else { return }
        if let durable = try writer.syncIfDue(force: force) {
            cursor.notePersisted(durable)
            try cursors.save(cursor, deviceId: ctx.meta.deviceId)
        }
    }

    /// ADVANCE is sent only after the whole transferred prefix is durable and the final envelope and
    /// the `sync_complete` seal are written. Any failure → `sync_interrupted`, no ADVANCE.
    private func complete(nextSeq: UInt64) {
        do {
            try persistIfDue(force: true)
            let lastNeeded = nextSeq &- 1
            let durable = recordsPersisted > 0 ? writer.lastDurableSeq : cursor.lastPersistedSeq
            guard nextSeq == startSeq || (durable.map { $0 >= lastNeeded } ?? false) else {
                interrupt("transferred records not durable (need \(lastNeeded), have \(durable.map(String.init) ?? "none"))", sendStop: false)
                return
            }
            try writer.finish(reason: .syncComplete, doneNextSeq: nextSeq)
        } catch {
            interrupt("could not finish ring capture: \(error)", sendStop: false)
            return
        }
        write(RingProtocol.advanceCommand(newReadSeq: nextSeq))
        phase = .finished
        deadline = nil
        state = .complete(records: recordsPersisted)
        log(.info, "ring", "sync complete: \(recordsPersisted) records, \(duplicatesDropped) duplicates dropped, next_seq \(nextSeq)")
    }

    private func interrupt(_ reason: String, sendStop: Bool) {
        if sendStop { write(RingProtocol.stopCommand()) }
        do { try persistIfDue(force: true) } catch {
            log(.error, "ring", "persist during interrupt failed: \(error)")
        }
        if writer.isActive {
            do { try writer.finish(reason: .syncInterrupted, doneNextSeq: nil) } catch {
                log(.error, "ring", "could not seal interrupted ring capture: \(error)")
            }
        }
        phase = .idle
        deadline = nil
        state = .interrupted(reason)
        log(.warning, "ring", "sync interrupted: \(reason) (\(recordsPersisted) records kept)")
    }

    private func fail(_ reason: String) {
        if writer.isActive {
            _ = try? writer.finish(reason: .syncInterrupted, doneNextSeq: nil)
        }
        phase = .idle
        deadline = nil
        state = .failed(reason)
        log(.warning, "ring", "offline sync failed: \(reason)")
    }

    private func unsupported(_ reason: String) {
        phase = .idle
        deadline = nil
        state = .unsupported(reason)
        onSupportDetermined?(.unsupported(reason))
        log(.info, "ring", "offline sync unsupported: \(reason)")
    }

    private func write(_ command: Data) {
        commandsWritten.append(command)
        transport?.ringWrite(command)
    }

    private func arm(_ seconds: TimeInterval) {
        deadline = clock.monotonicNanoseconds() &+ UInt64(seconds * 1_000_000_000)
    }

    private func resetSession() {
        phase = .idle
        status = nil
        info = nil
        duplicatesDropped = 0
        recordsPersisted = 0
        commandsWritten = []
        reassembler.reset()
        startSeq = 0
        reassembled = 0
        expectedTotal = 0
        deadline = nil
        state = .idle
    }
}
