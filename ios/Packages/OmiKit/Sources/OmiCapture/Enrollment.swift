import Foundation
import OmiProtocol

/// Holds a live capture's chunks from the voice-enrollment start until the server has acknowledged
/// the `voice_enrollment_start` event (docs/speaker-learning.md, "Enrollment"). Otherwise a chunk
/// could reach the server first and the wearer's enrollment reading would be transcribed as an
/// ordinary conversation. The matching `voice_enrollment_end` event is held too, so the server never
/// sees an end before its start. Holds are persisted, so a relaunch keeps holding.
///
/// If the start event is permanently rejected (quarantined), the hold is released: holding audio
/// forever would be worse than the enrollment speech being transcribed.
public final class EnrollmentGate: UploadGate, @unchecked Sendable {
    public struct Hold: Codable, Equatable, Sendable {
        public var enrollmentId: String
        public var captureId: String
        /// First chunk sequence that may contain enrollment audio (the chunk open at the start).
        public var fromSequence: Int
        public var startEventId: String
        public var endEventId: String?

        public init(enrollmentId: String, captureId: String, fromSequence: Int, startEventId: String, endEventId: String? = nil) {
            self.enrollmentId = enrollmentId
            self.captureId = captureId
            self.fromSequence = fromSequence
            self.startEventId = startEventId
            self.endEventId = endEventId
        }
    }

    private let url: URL
    private let outbox: Outbox
    private let lock = NSLock()
    private var holds: [Hold]

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

    /// Drops holds whose start event is acknowledged (or gone after retention) or quarantined.
    private func releaseSettled() {
        lock.lock(); defer { lock.unlock() }
        let before = holds.count
        holds.removeAll { h in
            let kind = OutboxKind.event(eventId: h.startEventId)
            if outbox.isAcknowledged(kind) || outbox.locate(kind) == nil { return true }
            if outbox.quarantined().contains(where: { $0.kind == kind }) {
                log(.warning, "enrollment", "start event of \(h.enrollmentId) was rejected; releasing its audio")
                return true
            }
            return false
        }
        if holds.count != before { try? persistLocked() }
    }

    private func persistLocked() throws {
        try JSONFile.save(holds, to: url)
    }
}

/// Every gate must allow an item; acknowledgements go to all of them.
public final class CompositeUploadGate: UploadGate, @unchecked Sendable {
    public let gates: [UploadGate]
    public init(_ gates: [UploadGate]) { self.gates = gates }

    public func mayUpload(_ item: OutboxItem) -> Bool { gates.allSatisfy { $0.mayUpload(item) } }
    public func heldReason(_ item: OutboxItem) -> String? { gates.lazy.compactMap { $0.heldReason(item) }.first }
    public func didAcknowledge(_ item: OutboxItem) { gates.forEach { $0.didAcknowledge(item) } }
}
