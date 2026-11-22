import Foundation
import OmiCapture
import OmiProtocol

/// The owner's priority choices not yet confirmed by the server (`PUT …/priority`). One per
/// conversation: a newer choice replaces the older one before anything is sent, so an old request
/// can never be sent after a newer choice. Saved (atomic + fsync) before sending, kept until the
/// server answers, given up after a bounded number of tries.
public final class PriorityStore: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var conversationId: String
        public var server: String
        public var state: String
        public var requestId: String
        /// When the owner chose: the server keeps the later choice by this time.
        public var setAt: Date
        public var attempts: Int
    }

    public static let maxAttempts = 8
    public static let maxAge: TimeInterval = 3 * 86400

    private let url: URL
    private let lock = NSLock()
    /// Migrations attempted (tests: once per address/vault change, not per refresh; IT2-04).
    var moveCalls = 0
    private var entries: [Entry]
    /// The one scope (server address, pairing generation, vault) whose server last confirmed it
    /// supports value notes, so saved notes of exactly that scope can still be marked offline.
    private let capabilityURL: URL
    private var capableScope: String?

    public init(url: URL) {
        self.url = url
        entries = JSONFile.load([Entry].self, from: url) ?? []
        capabilityURL = url.deletingLastPathComponent().appendingPathComponent("app-value-notes-scope.json")
        capableScope = JSONFile.load(String.self, from: capabilityURL)
    }

    /// What the live server just said for this scope (nil scope: nothing known any more).
    public func remember(scope: String?, supportsValueNotes: Bool) {
        lock.lock(); defer { lock.unlock() }
        let next = supportsValueNotes ? scope : nil
        guard next != capableScope else { return }
        capableScope = next
        if let next { try? JSONFile.save(next, to: capabilityURL) } else { try? FileManager.default.removeItem(at: capabilityURL) }
    }

    public func confirmedCapable(scope: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return capableScope == scope
    }

    /// The same vault answered at another address (the server moved): its unconfirmed choices move to that address,
    /// keeping their request ids and times. A conversation that already has one under the new key keeps that one
    /// (2026-11-22).
    @discardableResult
    public func move(vaultId: String, to server: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard VaultIdentity.valid(vaultId) != nil, RetryStore.vault(ofKey: server) == vaultId else { return false }
        moveCalls += 1
        var next = entries
        var changed = false
        var taken = Set(next.filter { $0.server == server }.map(\.conversationId))  // linear (IT2-04)
        for i in next.indices where next[i].server != server && RetryStore.vault(ofKey: next[i].server) == vaultId
            && !taken.contains(next[i].conversationId) {
            next[i].server = server
            taken.insert(next[i].conversationId)
            changed = true
        }
        guard changed else { return true }
        do {
            try persist(next)
            return true
        } catch {
            OmiLog.shared.log(.warning, "priority", "couldn't move saved decisions to the new address: \(error)")
            return false
        }
    }

    public func entries(server: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.server == server }
    }

    public func pending(_ conversationId: String, server: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.conversationId == conversationId && $0.server == server }
    }

    /// A new choice: replaces any unconfirmed one for the same conversation.
    @discardableResult
    public func choose(_ conversationId: String, state: String, server: String, now: Date = Date()) throws -> Entry {
        lock.lock(); defer { lock.unlock() }
        let entry = Entry(conversationId: conversationId, server: server, state: state,
                          requestId: UUID().uuidString.lowercased(), setAt: now, attempts: 0)
        try persist(entries.filter { !($0.conversationId == conversationId && $0.server == server) } + [entry])
        return entry
    }

    /// Answered (or refused): remove it, unless a newer choice replaced it meanwhile.
    public func settle(_ requestId: String) {
        lock.lock(); defer { lock.unlock() }
        try? persist(entries.filter { $0.requestId != requestId })
    }

    /// Another failed try. True when it is given up (too many tries, or too old).
    public func failed(_ requestId: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.requestId == requestId }) else { return false }
        var next = entries
        next[i].attempts += 1
        let giveUp = next[i].attempts >= Self.maxAttempts || now.timeIntervalSince(next[i].setAt) > Self.maxAge
        if giveUp { next.remove(at: i) }
        try? persist(next)
        return giveUp
    }

    private func persist(_ next: [Entry]) throws {
        try FileIO.ensureDirectory(url.deletingLastPathComponent())
        try JSONFile.save(next, to: url)
        entries = next
    }
}
