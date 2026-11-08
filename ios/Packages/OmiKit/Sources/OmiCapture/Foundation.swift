import Foundation
import OmiProtocol
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
    private var persistURL: URL?
    private let fileLock = NSLock()

    public init() {}

    /// Also keeps diagnostic lines (`isDiagnostic`) in a small rolling file, so a launch that ends
    /// before anyone looks still leaves its lines for the phone-log upload. App only.
    /// Starts keeping diagnostic lines in `url`, first re-sanitizing what an older build wrote there
    /// (it may hold raw, percent-encoded links).
    public func persist(to url: URL) {
        lock.lock()
        persistURL = url
        lock.unlock()
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        var changed = false
        let rows = data.split(separator: 0x0A).compactMap { raw -> Data? in
            guard var line = try? decoder.decode(PhoneLogLine.self, from: Data(raw)) else { changed = true; return nil }
            let clean = sanitize(line.message)
            if clean != line.message { line.message = clean; changed = true }
            return try? encoder.encode(line)
        }
        guard changed else { return }
        lock.lock(); defer { lock.unlock() }
        try? Data(rows.map { $0 + Data([0x0A]) }.joined()).write(to: url, options: .atomic)
    }

    /// What may leave the phone: upload, Watch, Bluetooth, Live Activity, engine and app lines, and
    /// any warning or error. Note, transcript and audio content isn't logged in the first place.
    public static func isDiagnostic(_ level: LogLine.Level, _ category: String) -> Bool {
        level == .warning || level == .error || ["upload", "watch", "ble", "liveactivity", "app", "engine"].contains(category)
    }

    static let persistMaxBytes = 512_000

    private func persistLine(_ line: LogLine, to url: URL) {
        let record = PhoneLogLine(at: ISO8601UTC.format(line.date), level: line.level.rawValue, category: line.category,
                                  message: String(line.message.prefix(300)))
        guard var data = try? JSONEncoder().encode(record) else { return }
        data.append(0x0A)
        fileLock.lock(); defer { fileLock.unlock() }
        guard let h = FileHandle(forWritingAtPath: url.path) else {
            try? data.write(to: url, options: .atomic)
            return
        }
        let end = (try? h.seekToEnd()) ?? 0
        if end > UInt64(Self.persistMaxBytes) {  // keep the newer half
            try? h.close()
            if let all = try? Data(contentsOf: url) {
                var tail = all.suffix(Self.persistMaxBytes / 2)
                if let nl = tail.firstIndex(of: 0x0A) { tail = tail[(nl + 1)...] }
                try? (Data(tail) + data).write(to: url, options: .atomic)
            }
            return
        }
        try? h.write(contentsOf: data)
        try? h.close()
    }

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
        let text = Self.sanitize(message, secrets: secretsCopy)
        lock.lock()
        let line = LogLine(id: nextId, date: Date(), level: level, category: category, message: text)
        nextId += 1
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        let persistTo = persistURL
        lock.unlock()
        if let persistTo, Self.isDiagnostic(level, category) { persistLine(line, to: persistTo) }
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

    /// `message` as it may be logged or leave the phone: `redact` plus every registered secret.
    public func sanitize(_ message: String) -> String {
        lock.lock()
        let secretsCopy = secrets
        lock.unlock()
        return Self.sanitize(message, secrets: secretsCopy)
    }

    static func sanitize(_ message: String, secrets: [String]) -> String {
        var text = redact(message)
        for s in secrets where !s.isEmpty {
            text = text.replacingOccurrences(of: s, with: "‹redacted›")
            if decodedFully(text).contains(s) {  // hidden by percent-encoding: keep the decoded form, masked
                text = redact(decodedFully(text)).replacingOccurrences(of: s, with: "‹redacted›")
            }
        }
        return text
    }

    /// Masks credential query values (`token=…`, `access_token=…`, `secret=…`, `password=…`,
    /// `api_key=…`) and `Bearer …` credentials, also when percent-encoding (even nested, or next to
    /// malformed escapes) hides the name or the value: then the decoded text is what gets masked.
    public static func redact(_ s: String) -> String {
        let plain = mask(s)
        let decoded = decodedFully(s)
        guard decoded != s else { return plain }
        let maskedDecoded = mask(decoded)
        return maskedDecoded == decoded ? plain : maskedDecoded
    }

    private static let patterns: [NSRegularExpression] = [
        #"(?i)((?:token|secret|password|passwd|api[_-]?key)[A-Za-z0-9_\-]*=)[^&\s"'#]+"#,
        #"(?i)((?:token|secret|password)"?\s*:\s*"?)[^"&\s,}]+"#,
        #"(?i)(bearer\s+)[A-Za-z0-9\-\._~\+/=]+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static func mask(_ s: String) -> String {
        var out = s
        for re in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1‹redacted›")
        }
        return out
    }

    /// One pass of %XX decoding that keeps malformed escapes as they are (unlike
    /// `removingPercentEncoding`, which gives up on the whole string).
    public static func percentDecoded(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x37
            case 0x61...0x66: return b - 0x57
            default: return nil
            }
        }
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decoded until nothing changes (nested encodings), at most a few rounds.
    static func decodedFully(_ s: String) -> String {
        var cur = s
        for _ in 0..<4 {
            let next = percentDecoded(cur)
            if next == cur { break }
            cur = next
        }
        return cur
    }
}

/// One persisted diagnostic line (also the phone-log upload's line shape).
public struct PhoneLogLine: Codable, Sendable, Equatable {
    public var at: String
    public var level: String
    public var category: String
    public var message: String
    public init(at: String, level: String, category: String, message: String) {
        self.at = at
        self.level = level
        self.category = category
        self.message = message
    }
}

public enum PhoneLogTail {
    /// The encoded request body's bound (the server refuses more than 64 KiB).
    public static let maxBodyBytes = 60_000
    /// The server keeps at most this many characters of a message.
    public static let maxMessage = 500

    /// Persisted lines newer than `after` (an `at` value), at most `limit` lines whose encoded size
    /// stays within `maxBytes`, keeping the newest when there are more. Each message is sanitized
    /// again (an older build may have written it) and shortened as the server would.
    public static func lines(at url: URL, after cursor: String?, limit: Int = 400, maxBytes: Int = maxBodyBytes - 1_000,
                             sanitize: (String) -> String = OmiLog.shared.sanitize) -> [PhoneLogLine] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        var all = data.split(separator: 0x0A).compactMap { try? decoder.decode(PhoneLogLine.self, from: Data($0)) }
        if let cursor { all = all.filter { $0.at > cursor } }
        var out: [PhoneLogLine] = [], bytes = 0
        for var line in all.reversed() {
            line.message = String(sanitize(line.message).prefix(maxMessage))
            bytes += ((try? encoder.encode(line).count) ?? maxBytes) + 1
            guard out.count < limit, bytes <= maxBytes else { break }
            out.append(line)
        }
        return out.reversed()
    }

    /// The upload's exact JSON body and the lines in it: the oldest lines that fit within `maxBytes`
    /// (so a cursor set to the last one skips nothing).
    public static func body(deviceId: String, appVersion: String?, lines: [PhoneLogLine], maxBytes: Int = maxBodyBytes) -> (Data, [PhoneLogLine]) {
        struct Body: Encodable { let device_id: String; let app_version: String?; let lines: [PhoneLogLine] }
        let encoder = JSONEncoder()
        func encode(_ n: Int) -> Data { (try? encoder.encode(Body(device_id: deviceId, app_version: appVersion, lines: Array(lines.prefix(n))))) ?? Data() }
        var n = lines.count
        var data = encode(n)
        while n > 0, data.count > maxBytes {
            n = max(0, min(n - 1, n * maxBytes / max(data.count, 1)))
            data = encode(n)
        }
        return (data, Array(lines.prefix(n)))
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
