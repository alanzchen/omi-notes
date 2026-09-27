import Foundation
import OmiCapture
import OmiProtocol

/// Retries this phone asked a server for (capture-format-v1.md, "POST /v1/conversations/{id}/retry").
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

    public func entry(conversationId: String, server: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.conversationId == conversationId && $0.server == server }
    }

    public func entries(server: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.server == server }
    }

    /// The entry to send for this conversation: the unsettled one if any, else a new one, saved first.
    public func begin(conversationId: String, server: String, now: Date = Date()) throws -> Entry {
        lock.lock(); defer { lock.unlock() }
        if unreadable { throw StoreError.unreadable }
        if let existing = entries.first(where: { $0.conversationId == conversationId && $0.server == server }) {
            return existing
        }
        let entry = Entry(requestId: UUID().uuidString.lowercased(), conversationId: conversationId, server: server, createdAt: now)
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
