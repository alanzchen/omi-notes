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

    /// Saved copies are encrypted at rest until the phone is first unlocked after a restart ("until
    /// first unlock", like the rest of the app's data). Complete protection made every save while
    /// the phone was locked fail (an atomic save creates a new file, which that class forbids then).
    /// macOS, where OmiKit's tests run, refuses protection classes for an ordinary process (EPERM),
    /// so there they are written without one.
    static let writeOptions: Data.WritingOptions = {
        #if os(macOS)
        return [.atomic]
        #else
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #endif
    }()

    private static var directoryAttributes: [FileAttributeKey: Any] {
        #if os(macOS)
        return [:]
        #else
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #endif
    }

    private let root: URL
    private let lock = NSLock()
    /// Moves one item an earlier build wrote with complete protection to the current class.
    var setProtection: (URL) throws -> Void = { url in
        #if !os(macOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
        #endif
    }
    private var migrated = false

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

    /// The same vault at another address (or pairing): the saved copies become that scope's. Only a vault's own
    /// copies move. The directory is renamed first, then the scope pointer replaced; false when either step failed
    /// (nothing is deleted either way). A rename that happened without its pointer is completed by `completeMove`,
    /// which the next adopt calls (ASTRA-20261122-IT3-02).
    @discardableResult
    public func move(to next: Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = read(Scope.self, pointerURL), current.vaultId == next.vaultId else { return false }
        if current == next { return true }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dir(current).path), !fm.fileExists(atPath: dir(next).path) {
                try fm.moveItem(at: dir(current), to: dir(next))
            }  // a copy already under the new scope (an earlier, interrupted move) is kept as it is: nothing deleted
            try writePointer(next)
            return true
        } catch {
            OmiLog.shared.log(.warning, "cache", "couldn't finish keeping the saved notes for the new address: \(error)")
            return false
        }
    }

    /// An interrupted `move` to `next`: the copies were renamed to `next`'s folder but the pointer still names the old
    /// scope (its folder gone). Point at them and keep them. The folder name hashes address, pairing generation and
    /// vault, so only a move to exactly this configuration and vault can have made it. True when `next` is current.
    public func completeMove(to next: Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = read(Scope.self, pointerURL) else { return false }
        if current == next { return true }
        let fm = FileManager.default
        guard current.vaultId == next.vaultId, fm.fileExists(atPath: dir(next).path), !fm.fileExists(atPath: dir(current).path)
        else { return false }
        do {
            try writePointer(next)
            return true
        } catch {
            OmiLog.shared.log(.warning, "cache", "couldn't complete keeping the saved notes: \(error)")
            return false
        }
    }

    /// `completeMove(to:)` found exactly that interrupted move but couldn't write the pointer yet: the copies are kept
    /// and the completion is retried (ASTRA-20261122-IT5-01).
    public func awaitsPointer(to next: Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = read(Scope.self, pointerURL), current != next, current.vaultId == next.vaultId else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: dir(next).path) && !fm.fileExists(atPath: dir(current).path)
    }

    private func writePointer(_ scope: Scope) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        try e.encode(scope).write(to: pointerURL, options: Self.writeOptions)
    }

    // MARK: Plumbing

    private func write<T: Encodable>(_ value: T, to url: URL, scope: Scope) {
        lock.lock(); defer { lock.unlock() }
        do {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .secondsSince1970
            migrateProtection()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: Self.directoryAttributes)
            try e.encode(value).write(to: url, options: Self.writeOptions)
            if read(Scope.self, pointerURL) != scope {
                try e.encode(scope).write(to: pointerURL, options: Self.writeOptions)
            }
        } catch {
            OmiLog.shared.log(.warning, "cache", "couldn't save a note for offline reading: \(error)")
        }
    }

    /// Once per launch: the folder and every file in it to the current protection class. A failure
    /// (still locked, say) is tried again on the next save; the save itself doesn't depend on it.
    private func migrateProtection() {
        guard !migrated, FileManager.default.fileExists(atPath: root.path) else { return }
        var items = [root]
        if let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walk { items.append(url) }
        }
        do {
            for url in items { try setProtection(url) }
            migrated = true
        } catch {
            OmiLog.shared.log(.info, "cache", "saved copies keep their old protection for now: \((error as NSError).code)")
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
