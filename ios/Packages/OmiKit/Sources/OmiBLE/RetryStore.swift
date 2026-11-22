import Foundation
import OmiCapture
import OmiProtocol

/// Retries and keeps this phone asked a server for (capture-format-v1.md, "POST /v1/conversations/{id}/retry"
/// and "/keep"); at most one unsettled request per conversation.
///
/// An entry is written durably (atomic write + full fsync) *before* the request is sent and kept
/// until the server's answer settles it, so a lost response, a timeout or a 5xx is retried with the
/// same request id (the server returns the same operation) instead of starting a second retry.
/// Entries belong to one server and vault (`server`); nothing here is shown for another.
public final class RetryStore: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var requestId: String
        public var conversationId: String
        public var server: String
        public var createdAt: Date
        /// `keep`, or nil for a retry (entries saved before keeps existed are retries).
        public var kind: String?
        /// The last answer, once there was one.
        public var operation: RetryOperation?
    }

    public enum StoreError: Error, LocalizedError {
        case unreadable
        public var errorDescription: String? {
            "The list of retries on this phone can't be read, so no new retry is sent (the file is kept for diagnosis)."
        }
    }

    private let url: URL
    private let lock = NSLock()
    /// Migrations attempted (tests: once per address/vault change, not per refresh; IT2-04).
    var moveCalls = 0
    private var entries: [Entry]
    /// The file exists but can't be read: it is kept (never overwritten) and nothing new is sent,
    /// since a new request id could start a second retry of something already asked for.
    public private(set) var unreadable = false

    public init(url: URL) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            if let loaded = JSONFile.load([Entry].self, from: url) {
                entries = loaded
            } else {
                entries = []
                unreadable = true
                OmiLog.shared.log(.error, "retry", "app-retries.json is unreadable; keeping it and not sending new retries")
            }
        } else {
            entries = []
        }
    }

    public static func serverKey(baseURL: URL, vaultId: String) -> String { "\(baseURL.absoluteString)|\(vaultId)" }

    /// The vault part of a key: everything after the first "|" (a URL's absolute string never holds a raw "|"), so a
    /// malformed vault id containing "|" can't pass for another's suffix (IT2-03).
    static func vault(ofKey key: String) -> String? {
        key.firstIndex(of: "|").map { String(key[key.index(after: $0)...]) }
    }

    /// The same vault answered at another address (the server moved): its unsettled requests are this address's now,
    /// with their request ids, so they are sent there instead of stranded under the old key (2026-11-22). A
    /// conversation that already has one under the new key keeps that one; nothing is deleted.
    @discardableResult
    public func move(vaultId: String, to server: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !unreadable, VaultIdentity.valid(vaultId) != nil, Self.vault(ofKey: server) == vaultId else { return false }
        moveCalls += 1
        var next = entries
        var changed = false
        var taken = Set(next.filter { $0.server == server }.map(\.conversationId))  // linear, not a search per entry (IT2-04)
        for i in next.indices where next[i].server != server && Self.vault(ofKey: next[i].server) == vaultId
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
            OmiLog.shared.log(.warning, "retry", "couldn't move saved decisions to the new address: \(error)")
            return false
        }
    }

    public func entry(conversationId: String, server: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.conversationId == conversationId && $0.server == server }
    }

    public func entries(server: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.server == server }
    }

    /// The entry to send for this conversation: the unsettled one if any, else a new one, saved first.
    public func begin(conversationId: String, server: String, kind: String? = nil, now: Date = Date()) throws -> Entry {
        lock.lock(); defer { lock.unlock() }
        if unreadable { throw StoreError.unreadable }
        if let existing = entries.first(where: { $0.conversationId == conversationId && $0.server == server }) {
            return existing
        }
        let entry = Entry(requestId: UUID().uuidString.lowercased(), conversationId: conversationId, server: server,
                          createdAt: now, kind: kind)
        try persist(entries + [entry])
        return entry
    }

    public func record(_ operation: RetryOperation, for requestId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.requestId == requestId }) else { return }
        var next = entries
        if operation.isFinished {
            next.remove(at: i)
        } else {
            next[i].operation = operation
        }
        try? persist(next)
    }

    /// The server settled it without an operation (e.g. `409 not_failed`): nothing to repeat.
    public func settle(_ requestId: String) {
        lock.lock(); defer { lock.unlock() }
        try? persist(entries.filter { $0.requestId != requestId })
    }

    private func persist(_ next: [Entry]) throws {
        if unreadable { throw StoreError.unreadable }
        try FileIO.ensureDirectory(url.deletingLastPathComponent())
        try JSONFile.save(next, to: url)
        entries = next
    }
}

/// A vault identity the app may compare: nonempty, bounded, no "|" (the key separator), no whitespace or control
/// characters. The server writes UUIDs; anything else is unknown, never "the same server" (ASTRA-20261122-IT2-03).
public enum VaultIdentity {
    public static func valid(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= 128, !id.contains("|"),
              id.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return id
    }
}
