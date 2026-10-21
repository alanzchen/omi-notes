import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Logging

public struct LogLine: Sendable, Identifiable, Equatable {
    public enum Level: String, Sendable { case debug, info, warning, error }
    public let id: Int
    public let date: Date
    public let level: Level
    public let category: String
    public let message: String
}

/// App log: os.Logger plus an in-memory ring buffer for the Debug screen.
/// Every message passes through `redact` first — tokens never reach a log.
public final class OmiLog: @unchecked Sendable {
    public static let shared = OmiLog()

    private let lock = NSLock()
    private var lines: [LogLine] = []
    private var nextId = 0
    private let capacity = 1500
    private let logger = Logger(subsystem: "omi-notes", category: "app")
    private var secrets: [String] = []

    public init() {}

    /// Registers a secret (the server token) to be masked wherever it appears.
    public func registerSecret(_ secret: String?) {
        guard let secret, secret.count >= 4 else { return }
        lock.lock(); defer { lock.unlock() }
        if !secrets.contains(secret) { secrets.append(secret) }
    }

    public func log(_ level: LogLine.Level, _ category: String, _ message: String) {
        lock.lock()
        let secretsCopy = secrets
        lock.unlock()
        var text = Self.redact(message)
        for s in secretsCopy { text = text.replacingOccurrences(of: s, with: "‹redacted›") }
        lock.lock()
        let line = LogLine(id: nextId, date: Date(), level: level, category: category, message: text)
        nextId += 1
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        lock.unlock()
        switch level {
        case .debug: logger.debug("[\(category, privacy: .public)] \(text, privacy: .public)")
        case .info: logger.info("[\(category, privacy: .public)] \(text, privacy: .public)")
        case .warning: logger.warning("[\(category, privacy: .public)] \(text, privacy: .public)")
        case .error: logger.error("[\(category, privacy: .public)] \(text, privacy: .public)")
        }
    }

    public func recent(limit: Int = 500) -> [LogLine] {
        lock.lock(); defer { lock.unlock() }
        return Array(lines.suffix(limit))
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        lines.removeAll()
    }

    /// Masks `token=…` query values and `Bearer …` credentials.
    public static func redact(_ s: String) -> String {
        var out = s
        let patterns = [
            #"(?i)(token=)[^&\s"']+"#,
            #"(?i)(bearer\s+)[A-Za-z0-9\-\._~\+/=]+"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p) {
                out = re.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1‹redacted›")
            }
        }
        return out
    }
}

@inline(__always)
func log(_ level: LogLine.Level, _ category: String, _ message: @autoclosure () -> String) {
    OmiLog.shared.log(level, category, message())
}

// MARK: - Clock

/// Wall clock + monotonic clock. Captures anchor once to wall time and measure everything
/// else on the monotonic clock (`mach_continuous_time`, which keeps counting while asleep).
public protocol CaptureClock: Sendable {
    func monotonicNanoseconds() -> UInt64
    func wallNow() -> Date
}

public struct SystemClock: CaptureClock {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    public init() {}

    public func monotonicNanoseconds() -> UInt64 {
        let t = mach_continuous_time()
        let (n, d) = Self.timebase
        if n == d { return t }
        return t / d * n + (t % d) * n / d
    }

    public func wallNow() -> Date { Date() }
}

/// One wall-clock anchor + monotonic offsets.
public struct CaptureAnchor: Codable, Equatable, Sendable {
    public var wall: Date
    public var monoNs: UInt64

    public init(wall: Date, monoNs: UInt64) {
        self.wall = wall
        self.monoNs = monoNs
    }

    public func offsetUs(_ monoNs: UInt64) -> Int64 {
        monoNs >= self.monoNs ? Int64((monoNs - self.monoNs) / 1000) : 0
    }

    public func wallDate(offsetUs: Int64) -> Date { wall.addingTimeInterval(Double(offsetUs) / 1_000_000) }
}

// MARK: - Server endpoint

public struct ServerEndpoint: Sendable, Equatable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// `path` starts with "/", e.g. `/v1/status`. Preserves any path prefix of the base URL.
    public func url(_ path: String, query: String? = nil) -> URL? {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        s += path
        if let query { s += "?" + query }
        return URL(string: s)
    }
}

// MARK: - File I/O

public enum FileIOError: Error, CustomStringConvertible {
    case posix(String, Int32)
    public var description: String {
        switch self {
        case .posix(let op, let code): return "\(op): \(String(cString: strerror(code)))"
        }
    }
    public var isOutOfSpace: Bool {
        if case .posix(_, let code) = self { return code == ENOSPC || code == EDQUOT }
        return false
    }
}

public enum FileIO {
    /// Creates a directory whose files stay readable after first unlock (background BLE / uploads).
    public static func ensureDirectory(_ url: URL) throws {
        var attrs: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        attrs[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attrs)
    }

    /// temp file in the same directory → write → fsync (F_FULLFSYNC) → rename → fsync directory.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString.lowercased())-\(url.lastPathComponent)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw FileIOError.posix("open \(tmp.lastPathComponent)", errno) }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        do {
            defer { close(fd) }
            try writeAll(fd: fd, data: data)
            if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
                throw FileIOError.posix("fsync", errno)
            }
        }
        guard rename(tmp.path, url.path) == 0 else { throw FileIOError.posix("rename", errno) }
        ok = true
        fsyncDirectory(dir)
    }

    public static func fsyncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, p, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FileIOError.posix("write", errno)
                }
                remaining -= n
                p = p.advanced(by: n)
            }
        }
    }

    public static func fileSize(_ url: URL) -> Int64 {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        return Int64(st.st_size)
    }

    public static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Free space usable for important (user-initiated) data.
    public static func freeBytes(at url: URL) -> Int64? {
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = v.volumeAvailableCapacityForImportantUsage {
            return cap
        }
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]), let cap = v.volumeAvailableCapacity {
            return Int64(cap)
        }
        return nil
    }

    public static func contents(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    public static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

/// Append-only file on a POSIX descriptor.
public final class AppendFile {
    public let url: URL
    private var fd: Int32
    public private(set) var size: Int64
    public private(set) var dirty = false

    public init(url: URL) throws {
        self.url = url
        fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { throw FileIOError.posix("open \(url.lastPathComponent)", errno) }
        size = FileIO.fileSize(url)
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    public func append(_ data: Data) throws {
        do {
            try FileIO.writeAll(fd: fd, data: data)
        } catch {
            // Drop a partially written record so the file stays a clean prefix.
            _ = ftruncate(fd, off_t(size))
            throw error
        }
        size += Int64(data.count)
        dirty = true
    }

    /// fsync (flushes to the drive). Cheap enough for the ≥ 1×/s journal cadence.
    public func sync() throws {
        guard dirty else { return }
        guard fsync(fd) == 0 else { throw FileIOError.posix("fsync", errno) }
        dirty = false
    }

    /// F_FULLFSYNC (flushes the drive cache), falling back to fsync.
    public func fullSync() throws {
        if fcntl(fd, F_FULLFSYNC) != 0 {
            guard fsync(fd) == 0 else { throw FileIOError.posix("fsync", errno) }
        }
        dirty = false
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}

// MARK: - Directory layout

/// ```
/// <root>/journal/live/<capture_id>/{capture.json, chunk-000003.journal}
/// <root>/journal/ring/<capture_id>/{capture.json, chunk-000000.journal}
/// <root>/outbox/{pending,sent,quarantine}/
/// <root>/state/
/// ```
public struct CaptureDirectories: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public var journalLive: URL { root.appendingPathComponent("journal/live", isDirectory: true) }
    public var journalRing: URL { root.appendingPathComponent("journal/ring", isDirectory: true) }
    /// Journal directories recovery could not interpret (e.g. corrupt manifest). Kept, never deleted.
    public var journalQuarantine: URL { root.appendingPathComponent("journal/quarantine", isDirectory: true) }
    public var outboxPending: URL { root.appendingPathComponent("outbox/pending", isDirectory: true) }
    public var outboxSent: URL { root.appendingPathComponent("outbox/sent", isDirectory: true) }
    public var outboxQuarantine: URL { root.appendingPathComponent("outbox/quarantine", isDirectory: true) }
    public var state: URL { root.appendingPathComponent("state", isDirectory: true) }

    public func create() throws {
        for d in [journalLive, journalRing, journalQuarantine, outboxPending, outboxSent, outboxQuarantine, state] {
            try FileIO.ensureDirectory(d)
        }
    }

    /// Default location: Application Support/OmiNotes (excluded from backups).
    public static func appDefault() -> CaptureDirectories {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("OmiNotes", isDirectory: true)
        try? FileIO.ensureDirectory(url)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return CaptureDirectories(root: url)
    }
}

// MARK: - Fault injection (tests)

/// Test seam: lets regression tests make specific durable steps fail. Nil in production.
final class FaultInjector: @unchecked Sendable {
    var manifestSave: (() throws -> Void)?
    var journalSync: (() throws -> Void)?
    init() {}
}

struct InjectedFault: Error, CustomStringConvertible {
    let what: String
    var description: String { "injected fault: \(what)" }
}

// MARK: - Small JSON state files

public enum JSONFile {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(T.self, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        try FileIO.atomicWrite(try e.encode(value), to: url)
    }
}
