import Foundation
import OmiProtocol

/// Holds a live capture's chunks from the voice-enrollment start until the server has acknowledged
/// the `voice_enrollment_start` event (docs/speaker-learning.md, "Enrollment"). Otherwise a chunk
/// could reach the server first and the wearer's enrollment reading would be transcribed as an
/// ordinary conversation. The matching `voice_enrollment_end` event is held too, so the server never
/// sees an end before its start. Holds are persisted, so a relaunch keeps holding.
///
/// A start event that disappeared without being acknowledged is unexplained state: the audio stays
/// held and the start event is written again (`reemitStart`) from what the hold remembers.
///
/// If the start event is permanently rejected (quarantined), the hold is released: the hold covers
/// every later chunk of the capture, and holding all of it forever would be worse than the reading
/// being transcribed. The app only starts an enrollment against a server that advertises
/// `voice_enrollment` in `/v1/status`, so a rejection means a server bug, not an old server.
public final class EnrollmentGate: UploadGate, @unchecked Sendable {
    public struct Hold: Codable, Equatable, Sendable {
        public var enrollmentId: String
        public var captureId: String
        /// First chunk sequence that may contain enrollment audio (the chunk open at the start).
        public var fromSequence: Int
        public var startEventId: String
        public var endEventId: String?
        /// What the start event said, so a lost one can be written again.
        public var deviceId: String?
        public var startAt: String?
        public var startOffsetUs: Int64?

        public init(enrollmentId: String, captureId: String, fromSequence: Int, startEventId: String, endEventId: String? = nil,
                    deviceId: String? = nil, startAt: String? = nil, startOffsetUs: Int64? = nil) {
            self.enrollmentId = enrollmentId
            self.captureId = captureId
            self.fromSequence = fromSequence
            self.startEventId = startEventId
            self.endEventId = endEventId
            self.deviceId = deviceId
            self.startAt = startAt
            self.startOffsetUs = startOffsetUs
        }
    }

    private let url: URL
    private let outbox: Outbox
    private let lock = NSLock()
    private var holds: [Hold]
    /// Writes a hold's start event again and returns the new event id (set by the engine).
    public var reemitStart: (@Sendable (Hold) throws -> String)? {
        get { lock.lock(); defer { lock.unlock() }; return _reemitStart }
        set { lock.lock(); _reemitStart = newValue; lock.unlock() }
    }
    private var _reemitStart: (@Sendable (Hold) throws -> String)?

    public init(stateDir: URL, outbox: Outbox) {
        url = stateDir.appendingPathComponent("enrollment-holds.json")
        self.outbox = outbox
        holds = JSONFile.load([Hold].self, from: url) ?? []
    }

    public var snapshot: [Hold] {
        lock.lock(); defer { lock.unlock() }
        return holds
    }

    public func hold(_ hold: Hold) throws {
        lock.lock(); defer { lock.unlock() }
        holds.removeAll { $0.enrollmentId == hold.enrollmentId }
        holds.append(hold)
        try persistLocked()
    }

    public func attachEndEvent(enrollmentId: String, endEventId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let i = holds.firstIndex(where: { $0.enrollmentId == enrollmentId }) else { return }
        holds[i].endEventId = endEventId
        try? persistLocked()
    }

    // MARK: UploadGate

    public func mayUpload(_ item: OutboxItem) -> Bool { heldReason(item) == nil }

    public func heldReason(_ item: OutboxItem) -> String? {
        releaseSettled()
        let current = snapshot
        switch item.kind {
        case .chunk(let captureId, let sequence):
            guard let h = current.first(where: { $0.captureId == captureId && sequence >= $0.fromSequence }) else { return nil }
            return "waits for the server to acknowledge voice enrollment \(h.enrollmentId.prefix(8))"
        case .event(let eventId):
            guard let h = current.first(where: { $0.endEventId == eventId }) else { return nil }
            return "enrollment end waits for its start event (\(h.enrollmentId.prefix(8)))"
        default:
            return nil
        }
    }

    public func didAcknowledge(_ item: OutboxItem) {
        guard case .event = item.kind else { return }
        releaseSettled()
    }

    /// Drops holds whose start event is acknowledged or quarantined; writes a lost one again.
    private func releaseSettled() {
        lock.lock()
        let before = holds.count
        var missing: [Hold] = []
        holds.removeAll { h in
            let kind = OutboxKind.event(eventId: h.startEventId)
            if outbox.isAcknowledged(kind) { return true }
            if outbox.quarantined().contains(where: { $0.kind == kind }) {
                log(.warning, "enrollment", "start event of \(h.enrollmentId) was rejected; releasing its audio")
                return true
            }
            if outbox.locate(kind) == nil { missing.append(h) }
            return false
        }
        if holds.count != before { try? persistLocked() }
        let reemit = _reemitStart
        lock.unlock()
        guard !missing.isEmpty else { return }
        // Outside the lock: writing to the outbox may call back into the gate.
        var rewritten: [String: String] = [:]
        for h in missing {
            do {
                guard let reemit else { throw EnrollmentGateError.cannotRewrite }
                rewritten[h.enrollmentId] = try reemit(h)
                log(.warning, "enrollment", "start event of \(h.enrollmentId) was lost; wrote it again, audio stays held")
            } catch {
                log(.error, "enrollment", "start event of \(h.enrollmentId) is lost and could not be written again (\(error)); audio stays held")
            }
        }
        guard !rewritten.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for i in holds.indices {
            if let id = rewritten[holds[i].enrollmentId] { holds[i].startEventId = id }
        }
        try? persistLocked()
    }

    private func persistLocked() throws {
        try JSONFile.save(holds, to: url)
    }
}

enum EnrollmentGateError: Error { case cannotRewrite }

/// Every gate must allow an item; acknowledgements go to all of them.
public final class CompositeUploadGate: UploadGate, @unchecked Sendable {
    public let gates: [UploadGate]
    public init(_ gates: [UploadGate]) { self.gates = gates }

    public func mayUpload(_ item: OutboxItem) -> Bool { gates.allSatisfy { $0.mayUpload(item) } }
    public func heldReason(_ item: OutboxItem) -> String? { gates.lazy.compactMap { $0.heldReason(item) }.first }
    public func didAcknowledge(_ item: OutboxItem) { gates.forEach { $0.didAcknowledge(item) } }
}
