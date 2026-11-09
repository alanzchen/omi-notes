import Foundation
import Observation
import OmiCapture
import OmiProtocol

/// The 声纹 review queue: one clip at a time, in batches of ten in the server's order (suspicious
/// first). Every answer goes to the server at once and can be undone for a few seconds through its
/// undo token; "Skip" only moves on in this session. A changed item (`409 stale_review`) is never
/// answered: the queue is fetched again.
@MainActor
@Observable
public final class VoiceReviewQueue {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        /// This batch is done (or the server had nothing left).
        case finished
        case failed(String)
    }

    public enum Decision: String, Sendable {
        case confirm, reject, move
    }

    /// A short word for the toast.
    public enum Notice: Equatable, Sendable {
        /// Something changed on the server meanwhile; the queue was fetched again.
        case refreshed
        case undone
        /// The answer was changed again since (or can't be put back), so it stands.
        case undoFailed
    }

    public struct Done: Equatable, Sendable {
        public var item: ReviewItem
        public var decision: Decision
        public var personId: String?
        public var undoToken: String
    }

    public private(set) var items: [ReviewItem] = []
    public private(set) var index = 0
    public private(set) var phase: Phase = .loading
    /// The last answer, while it can still be undone.
    public private(set) var undoable: Done?
    public private(set) var notice: Notice?
    public private(set) var error: String?
    public private(set) var busy = false
    /// Answers that still stand, this session.
    public private(set) var decided = 0
    public var undoWindow: Duration = .seconds(6)

    private let speakers: SpeakersModel
    /// Skipped this session: not asked again until the screen opens anew.
    private var skipped: Set<String> = []
    private var undoTimer: Task<Void, Never>?

    public init(speakers: SpeakersModel) {
        self.speakers = speakers
    }

    public var current: ReviewItem? { items.indices.contains(index) ? items[index] : nil }

    /// Fetches the next batch.
    public func load() async {
        phase = .loading
        do {
            let fresh = try await speakers.reviewItems(limit: ReviewBatch.size)
            items = ReviewBatch.make(fresh, excluding: skipped)
            index = 0
            phase = items.isEmpty ? .finished : .ready
        } catch {
            phase = .failed(SpeakersModel.describe(error))
        }
    }

    /// Answers the current item; false (and the item stays) if the server didn't take it.
    @discardableResult
    public func decide(_ decision: Decision, personId: String? = nil) async -> Bool {
        guard let item = current, !busy else { return false }
        busy = true
        defer { busy = false }
        let requestId = UUID().uuidString.lowercased()
        let answer: ReviewDecisionAnswer
        do {
            answer = try await speakers.decideReview(item.id, decision: decision.rawValue, personId: personId, requestId: requestId)
        } catch APIError.http(409, let detail) {
            undoable = nil
            error = detail.hasPrefix("consent_required") ? VoiceSamplesModel.consentMessage : nil
            notice = .refreshed
            await load()
            return false
        } catch {
            self.error = "没能保存：\(SpeakersModel.describe(error))"
            return false
        }
        error = nil
        notice = nil
        decided += 1
        let done = Done(item: item, decision: decision, personId: personId, undoToken: answer.undoToken ?? answer.requestId ?? requestId)
        undoable = done
        index += 1
        if index >= items.count { phase = .finished }
        armUndoTimer(for: done)
        return true
    }

    /// Not sure: on to the next one; it isn't sent anywhere.
    public func skip() {
        guard let item = current else { return }
        skipped.insert(item.id)
        index += 1
        error = nil
        if index >= items.count { phase = .finished }
    }

    /// Puts the last answer back. The item's id is bound to its revision, which the undo changes, so
    /// the queue is fetched again (the item comes back with its new id).
    public func undo() async {
        guard let last = undoable, !busy else { return }
        busy = true
        defer { busy = false }
        undoTimer?.cancel()
        do {
            let r = try await speakers.undo(token: last.undoToken)
            undoable = nil
            guard r.undidAnything else {
                notice = .undoFailed
                return
            }
            decided -= 1
            notice = .undone
            error = nil
            await load()
        } catch {
            self.error = "没能撤销：\(SpeakersModel.describe(error))"
            armUndoTimer(for: last)
        }
    }

    public func clearNotice() { notice = nil }

    private func armUndoTimer(for done: Done) {
        undoTimer?.cancel()
        let window = undoWindow
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            if self?.undoable == done { self?.undoable = nil }
        }
    }
}

/// One person's samples by state: listen, remove (restorable), restore, move to someone else, or
/// confirm a flagged one. Each change is sent at once with the revision it was listed at, and the
/// last one can be undone; a refused change lists the samples again.
@MainActor
@Observable
public final class VoiceSamplesModel {
    public enum Tab: String, CaseIterable, Sendable {
        case active, flagged, removed
    }

    public enum Action: Sendable { case remove, restore, move, confirm }

    public struct Done: Equatable, Sendable {
        public var sampleId: String
        public var action: Action
        public var undoToken: String
    }

    public static let consentMessage = "这个人还没有同意识别声音，先在识别设置里确认。"

    public let personId: String
    public var tab: Tab
    public private(set) var samples: [VoiceSample] = []
    public private(set) var loading = false
    public private(set) var loaded = false
    public private(set) var error: String?
    public private(set) var undoable: Done?
    public private(set) var busy = false
    public var undoWindow: Duration = .seconds(6)

    private let speakers: SpeakersModel
    private var undoTimer: Task<Void, Never>?
    /// A newer load (another tab) wins over one still on its way.
    private var generation = 0

    public init(speakers: SpeakersModel, personId: String, tab: Tab = .active) {
        self.speakers = speakers
        self.personId = personId
        self.tab = tab
    }

    public func load() async {
        generation += 1
        let asked = generation
        let state = tab
        loading = true
        defer { if asked == generation { loading = false } }
        do {
            let fresh = try await speakers.samples(personId: personId, state: state.rawValue)
            guard asked == generation else { return }
            samples = fresh
            loaded = true
        } catch {
            guard asked == generation else { return }
            self.error = SpeakersModel.describe(error)
        }
    }

    @discardableResult
    public func remove(_ s: VoiceSample) async -> Bool { await act(s, .remove) }
    @discardableResult
    public func restore(_ s: VoiceSample) async -> Bool { await act(s, .restore) }
    @discardableResult
    public func move(_ s: VoiceSample, to personId: String) async -> Bool { await act(s, .move, personId: personId) }

    /// "是 X": resolves the sample's flag through its review item.
    @discardableResult
    public func confirm(_ s: VoiceSample) async -> Bool {
        guard let reviewId = s.reviewId else { return false }
        return await perform(s, .confirm) { requestId in
            let a = try await self.speakers.decideReview(reviewId, decision: "confirm", personId: nil, requestId: requestId)
            return a.undoToken ?? a.requestId
        }
    }

    public func undo() async {
        guard let last = undoable, !busy else { return }
        busy = true
        defer { busy = false }
        undoTimer?.cancel()
        undoable = nil
        do {
            let r = try await speakers.undo(token: last.undoToken)
            error = r.undidAnything ? nil : "没能撤销：这个样本之后又改过了。"
        } catch {
            self.error = "没能撤销：\(SpeakersModel.describe(error))"
        }
        await load()
    }

    private func act(_ s: VoiceSample, _ action: Action, personId: String? = nil) async -> Bool {
        let name: String
        switch action {
        case .remove: name = "remove"
        case .restore: name = "restore"
        case .move: name = "move"
        case .confirm: return false
        }
        return await perform(s, action) { requestId in
            let a = try await self.speakers.sampleAction(s.id, action: name, personId: personId, expectedRevision: s.revision,
                                                         requestId: requestId)
            return a.undoToken ?? a.requestId
        }
    }

    private func perform(_ s: VoiceSample, _ action: Action, send: (String) async throws -> String?) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        let requestId = UUID().uuidString.lowercased()
        let token: String?
        do {
            token = try await send(requestId)
        } catch APIError.http(409, let detail) {
            error = detail.hasPrefix("consent_required") ? Self.consentMessage : "这个样本刚刚变过，已重新载入。"
            await load()
            return false
        } catch {
            self.error = "没能保存：\(SpeakersModel.describe(error))"
            return false
        }
        error = nil
        // it leaves this tab unless it stays in the same state (a confirm on the active tab)
        if !(action == .confirm && tab == .active) { samples.removeAll { $0.id == s.id } }
        let done = Done(sampleId: s.id, action: action, undoToken: token ?? requestId)
        undoable = done
        undoTimer?.cancel()
        let window = undoWindow
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            if self?.undoable == done { self?.undoable = nil }
        }
        return true
    }
}
