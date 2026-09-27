import CryptoKit
import Foundation
import OmiCapture
import OmiProtocol

/// Notes read on this phone, kept for reading while the server can't be reached.
///
/// A disposable reading cache, never authoritative: it lives in `Library/Caches` (iOS may purge
/// it), is written only after a successful answer, is protected while the phone is locked, and
/// belongs to one server and vault (`Scope`), so another server's notes are never shown. Bounded
/// by count and size; the oldest saved copies go first.
public final class NoteCache: @unchecked Sendable {
    public struct Scope: Codable, Equatable, Sendable {
        public var serverURL: String
        public var generation: Int
        public var vaultId: String

        public init(serverURL: String, generation: Int, vaultId: String) {
            self.serverURL = serverURL
            self.generation = generation
            self.vaultId = vaultId
        }

        var folder: String {
            SHA256.hash(data: Data("\(serverURL)|\(generation)|\(vaultId)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
        }
    }

    public struct Saved<T: Codable & Sendable>: Codable, Sendable {
        public var value: T
        public var savedAt: Date
    }

    public static let maxDetails = 50
    public static let maxBytes: Int64 = 20 * 1024 * 1024

    private let root: URL
    private let lock = NSLock()

    public init(root: URL) { self.root = root }

    public static func appDefault() -> NoteCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return NoteCache(root: caches.appendingPathComponent("omi-notes-cache", isDirectory: true))
    }

    private var pointerURL: URL { root.appendingPathComponent("scope.json") }
    private func dir(_ scope: Scope) -> URL { root.appendingPathComponent(scope.folder, isDirectory: true) }
    private func detailsDir(_ scope: Scope) -> URL { dir(scope).appendingPathComponent("details", isDirectory: true) }

    /// The scope last saved for, so the cache can be read at launch before the server answers.
    public var lastScope: Scope? {
        lock.lock(); defer { lock.unlock() }
        return read(Scope.self, pointerURL)
    }

    // MARK: Writing

    public func saveRecent(_ rows: [ConversationSummary], scope: Scope, at date: Date = Date()) {
        write(Saved(value: rows, savedAt: date), to: dir(scope).appendingPathComponent("recent.json"), scope: scope)
    }

    public func saveDetail(_ detail: ConversationDetail, scope: Scope, at date: Date = Date()) {
        write(Saved(value: detail, savedAt: date), to: detailsDir(scope).appendingPathComponent("\(Self.safe(detail.id)).json"), scope: scope)
        evict(scope)
    }

    // MARK: Reading

    public func recent(scope: Scope) -> Saved<[ConversationSummary]>? {
        lock.lock(); defer { lock.unlock() }
        return read(Saved<[ConversationSummary]>.self, dir(scope).appendingPathComponent("recent.json"))
    }

    public func detail(_ id: String, scope: Scope) -> Saved<ConversationDetail>? {
        lock.lock(); defer { lock.unlock() }
        return read(Saved<ConversationDetail>.self, detailsDir(scope).appendingPathComponent("\(Self.safe(id)).json"))
    }

    /// Every saved conversation of this scope, newest conversation first.
    public func details(scope: Scope) -> [Saved<ConversationDetail>] {
        lock.lock(); defer { lock.unlock() }
        return FileIO.contents(of: detailsDir(scope)).filter { $0.pathExtension == "json" }
            .compactMap { read(Saved<ConversationDetail>.self, $0) }
            .sorted { ($0.value.entry.startedDate ?? .distantPast) > ($1.value.entry.startedDate ?? .distantPast) }
    }

    /// Offline search of the saved copies (their transcripts may be partial).
    public func search(_ query: String, scope: Scope) -> [ConversationDetail] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        return details(scope: scope).map(\.value).filter { d in
            var text = [d.entry.title, d.summary?.overview].compactMap { $0 }
            text += d.speakers.compactMap(\.name)
            text += d.summary?.actionItems.map(\.description) ?? []
            text += d.transcript?.segments.map(\.text) ?? []
            let all = text.joined(separator: "\n").lowercased()
            return terms.allSatisfy { all.contains($0) }
        }
    }

    // MARK: Clearing

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Plumbing

    private func write<T: Encodable>(_ value: T, to url: URL, scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        do {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .secondsSince1970
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try e.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
            if read(Scope.self, pointerURL) != scope {
                try e.encode(scope).write(to: pointerURL, options: [.atomic, .completeFileProtection])
            }
        } catch {
            OmiLog.shared.log(.warning, "cache", "couldn't save a note for offline reading: \(error)")
        }
    }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        // Unreadable (purged, protected while locked, or corrupt): simply not available offline.
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(T.self, from: data)
    }

    private func evict(_ scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        let files = FileIO.contents(of: detailsDir(scope)).filter { $0.pathExtension == "json" }
            .sorted { FileIO.modificationDate($0) > FileIO.modificationDate($1) }
        var total: Int64 = 0
        for (i, file) in files.enumerated() {
            total += FileIO.fileSize(file)
            if i >= Self.maxDetails || total > Self.maxBytes { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func safe(_ id: String) -> String {
        String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.prefix(64))
    }
}
