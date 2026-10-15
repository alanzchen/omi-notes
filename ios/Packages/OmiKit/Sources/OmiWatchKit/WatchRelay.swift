import CryptoKit
import Foundation

// Apple Watch recordings relayed through the iPhone (capture-format-v1.md, "Apple Watch"). The Watch
// keeps every segment until the phone says it has it durably; the phone keeps it (as an outbox
// envelope) until the server has it. Shared by both apps; no WatchConnectivity here.

/// One recorded segment (about 60 s of AAC audio) and what the phone needs to place it.
public struct WatchSegment: Codable, Equatable, Sendable {
    public var recordingId: String
    public var index: Int
    public var deviceId: String
    public var deviceName: String
    /// The phone install this recording belongs to (never relayed to another).
    public var binding: String
    /// Wall clock when the recording started (Watch clock).
    public var recordingStartedAt: Date
    /// Monotonic offsets from the recording's start (Watch uptime), microseconds.
    public var startOffsetUs: Int64
    public var endOffsetUs: Int64
    public var bytes: Int
    public var sha256: String

    public var id: String { "\(recordingId)-\(index)" }

    public init(recordingId: String, index: Int, deviceId: String, deviceName: String, binding: String,
                recordingStartedAt: Date, startOffsetUs: Int64, endOffsetUs: Int64, bytes: Int, sha256: String) {
        self.recordingId = recordingId
        self.index = index
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.binding = binding
        self.recordingStartedAt = recordingStartedAt
        self.startOffsetUs = startOffsetUs
        self.endOffsetUs = endOffsetUs
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// A recording ended: after its last segment (index `lastIndex`, -1 for none) the phone seals it.
public struct WatchRecordingEnd: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case userStopped = "user_stopped", appRecovered = "app_recovered" }
    public var recordingId: String
    public var deviceId: String
    public var binding: String
    public var lastIndex: Int
    public var endOffsetUs: Int64
    public var endedAt: Date
    public var reason: Reason

    public var id: String { "\(recordingId)-end" }

    public init(recordingId: String, deviceId: String, binding: String, lastIndex: Int, endOffsetUs: Int64, endedAt: Date, reason: Reason) {
        self.recordingId = recordingId
        self.deviceId = deviceId
        self.binding = binding
        self.lastIndex = lastIndex
        self.endOffsetUs = endOffsetUs
        self.endedAt = endedAt
        self.reason = reason
    }
}

/// What the Watch app last said about itself (sent as its application context: only the latest
/// counts). A statement as of `at`, not proof of what it is doing now.
public struct WatchReport: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case recording, paused, idle }
    public var state: State
    /// When the current recording started (recording or paused).
    public var since: Date?
    /// Audio parts on the Watch the phone hasn't acknowledged yet.
    public var waitingParts: Int
    public var at: Date
    /// Counters since the Watch app launched (transfers, resends, capture buffer allocations…), to
    /// compare builds; absent from older Watch apps.
    public var stats: [String: Int]?

    public init(state: State, since: Date?, waitingParts: Int, at: Date, stats: [String: Int]? = nil) {
        self.state = state
        self.since = since
        self.waitingParts = waitingParts
        self.at = at
        self.stats = stats
    }
}

/// WatchConnectivity payload keys (property-list values only).
public enum WatchWire {
    public static let kind = "kind", manifest = "manifest", acks = "acks", rejects = "rejects", binding = "binding"
    public static let segment = "segment", end = "end", report = "report", perf = "perf"

    public static func encode<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = .sortedKeys
        return (try? e.encode(v)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return try? d.decode(type, from: data)
    }
}

public enum WatchRelayError: Error, Equatable, LocalizedError {
    case damaged(String), wrongPhone
    public var errorDescription: String? {
        switch self {
        case .damaged(let s): return "segment damaged in transfer (\(s))"
        case .wrongPhone: return "the recording belongs to another iPhone"
        }
    }
}

enum Files {
    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Atomic, durable: write a temporary file, fsync it, rename, fsync the directory.
    static func durableWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tmp)
        try fsync(tmp)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        try fsync(url.deletingLastPathComponent())
    }

    static func durableCopy(_ from: URL, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        _ = try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: from, to: tmp)
        try fsync(tmp)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        try fsync(url.deletingLastPathComponent())
    }

    static func fsync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        _ = Darwin.fsync(fd)
    }

    static func names(_ dir: URL, suffix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }
    }
}

// MARK: - Watch side

/// Segments and recording ends waiting for the phone. Nothing is deleted until the phone has
/// acknowledged it (after storing it durably and checking its hash).
public final class WatchOutbox: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var segmentsDir: URL { root.appendingPathComponent("segments", isDirectory: true) }
    private var endsDir: URL { root.appendingPathComponent("ends", isDirectory: true) }
    /// What is on disk, read once per launch and then kept current by `add` and `acknowledge`: the
    /// sync loop asks for the queue after every part, and reading every manifest each time grew
    /// with the backlog (a day away from the iPhone is over a thousand files). The files stay the
    /// truth; only this process changes them.
    private var segmentIndex: [String: WatchSegment]?
    private var endIndex: [String: WatchRecordingEnd]?
    /// Manifests read from disk (to compare builds; flat after the first read).
    public private(set) var manifestReads = 0

    public init(root: URL) {
        self.root = root
        for d in [segmentsDir, endsDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// Takes a finished segment file (moved in) and its manifest.
    public func add(segmentFile: URL, segment: WatchSegment) throws {
        lock.lock(); defer { lock.unlock() }
        let audio = segmentsDir.appendingPathComponent("\(segment.id).m4a")
        if segmentFile != audio {
            _ = try? FileManager.default.removeItem(at: audio)
            try FileManager.default.moveItem(at: segmentFile, to: audio)
        }
        try Files.fsync(audio)
        try Files.durableWrite(WatchWire.encode(segment), to: segmentsDir.appendingPathComponent("\(segment.id).json"))
        loadSegments()
        segmentIndex?[segment.id] = segment
    }

    public func add(end: WatchRecordingEnd) throws {
        lock.lock(); defer { lock.unlock() }
        try Files.durableWrite(WatchWire.encode(end), to: endsDir.appendingPathComponent("\(end.id).json"))
        loadEnds()
        endIndex?[end.id] = end
    }

    /// Called with `lock` held.
    private func loadSegments() {
        guard segmentIndex == nil else { return }
        var index: [String: WatchSegment] = [:]
        for name in Files.names(segmentsDir, suffix: ".json") {
            manifestReads += 1
            guard let s = WatchWire.decode(WatchSegment.self, try? Data(contentsOf: segmentsDir.appendingPathComponent(name))),
                  FileManager.default.fileExists(atPath: segmentsDir.appendingPathComponent("\(s.id).m4a").path) else { continue }
            index[s.id] = s
        }
        segmentIndex = index
    }

    private func loadEnds() {
        guard endIndex == nil else { return }
        var index: [String: WatchRecordingEnd] = [:]
        for name in Files.names(endsDir, suffix: ".json") {
            manifestReads += 1
            if let e = WatchWire.decode(WatchRecordingEnd.self, try? Data(contentsOf: endsDir.appendingPathComponent(name))) { index[e.id] = e }
        }
        endIndex = index
    }

    public func segments() -> [(segment: WatchSegment, file: URL)] {
        lock.lock(); defer { lock.unlock() }
        loadSegments()
        return (segmentIndex ?? [:]).values
            .sorted { ($0.recordingStartedAt, $0.index) < ($1.recordingStartedAt, $1.index) }
            .map { ($0, segmentsDir.appendingPathComponent("\($0.id).m4a")) }
    }

    public func ends() -> [WatchRecordingEnd] {
        lock.lock(); defer { lock.unlock() }
        loadEnds()
        return Array((endIndex ?? [:]).values)
    }

    /// The phone has these (segment or end ids): only now are they removed from the Watch.
    public func acknowledge(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        for id in ids {
            for url in [segmentsDir.appendingPathComponent("\(id).m4a"), segmentsDir.appendingPathComponent("\(id).json"),
                        endsDir.appendingPathComponent("\(id).json")] {
                _ = try? FileManager.default.removeItem(at: url)
            }
            segmentIndex?[id] = nil
            endIndex?[id] = nil
        }
    }

    public var pendingCount: Int { segments().count + ends().count }

    /// Bytes of audio waiting for the phone.
    public var waitingBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        loadSegments()
        return (segmentIndex ?? [:]).values.reduce(0) { $0 + Int64($1.bytes) }
    }
}

// MARK: - Phone side

/// What the phone has received from the Watch, stored durably before it is acknowledged, then
/// converted into upload envelopes. Receiving the same segment again is acknowledged again and
/// changes nothing.
public final class PhoneWatchInbox: @unchecked Sendable {
    public let root: URL
    public let binding: String
    private let lock = NSLock()
    private var inboxDir: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    private var endsDir: URL { root.appendingPathComponent("ends", isDirectory: true) }
    private var doneDir: URL { root.appendingPathComponent("done", isDirectory: true) }

    public init(root: URL, binding: String) {
        self.root = root
        self.binding = binding
        for d in [inboxDir, endsDir, doneDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// Stores a received segment (copied from WatchConnectivity's temporary file before the
    /// callback returns). Returns normally only when it is durable and matches its hash.
    public func accept(file: URL, segment: WatchSegment) throws {
        guard segment.binding == binding else { throw WatchRelayError.wrongPhone }
        lock.lock(); defer { lock.unlock() }
        if isDone(segment.id) || FileManager.default.fileExists(atPath: inboxDir.appendingPathComponent("\(segment.id).json").path) { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
        guard size == segment.bytes else { throw WatchRelayError.damaged("size \(size) ≠ \(segment.bytes)") }
        guard try Files.sha256(file) == segment.sha256 else { throw WatchRelayError.damaged("SHA-256") }
        let audio = inboxDir.appendingPathComponent("\(segment.id).m4a")
        try Files.durableCopy(file, to: audio)
        try Files.durableWrite(WatchWire.encode(segment), to: inboxDir.appendingPathComponent("\(segment.id).json"))
    }

    public func accept(end: WatchRecordingEnd) throws {
        guard end.binding == binding else { throw WatchRelayError.wrongPhone }
        lock.lock(); defer { lock.unlock() }
        if isDone(end.id) { return }
        try Files.durableWrite(WatchWire.encode(end), to: endsDir.appendingPathComponent("\(end.id).json"))
    }

    /// Received segments not yet converted, in recording order.
    public func pending() -> [(segment: WatchSegment, file: URL)] {
        lock.lock(); defer { lock.unlock() }
        return Files.names(inboxDir, suffix: ".json").compactMap { name in
            guard let s = WatchWire.decode(WatchSegment.self, try? Data(contentsOf: inboxDir.appendingPathComponent(name))) else { return nil }
            return (s, inboxDir.appendingPathComponent("\(s.id).m4a"))
        }
        .sorted { ($0.segment.recordingStartedAt, $0.segment.index) < ($1.segment.recordingStartedAt, $1.segment.index) }
    }

    /// Ends whose every segment is converted, with the end offset of the last converted chunk.
    public func readyEnds() -> [(end: WatchRecordingEnd, lastChunkEndUs: Int64?)] {
        lock.lock(); defer { lock.unlock() }
        return Files.names(endsDir, suffix: ".json").compactMap { name -> (WatchRecordingEnd, Int64?)? in
            guard let e = WatchWire.decode(WatchRecordingEnd.self, try? Data(contentsOf: endsDir.appendingPathComponent(name))) else { return nil }
            guard e.lastIndex < 0 || (0...e.lastIndex).allSatisfy({ isDone("\(e.recordingId)-\($0)") }) else { return nil }
            let last = e.lastIndex < 0 ? nil : (try? String(contentsOf: doneDir.appendingPathComponent("\(e.recordingId)-\(e.lastIndex)"), encoding: .utf8)).flatMap { Int64($0) }
            return (e, last)
        }
    }

    /// The segment is now in the upload outbox: keep only a small marker (for idempotency).
    public func markConverted(_ segment: WatchSegment, chunkEndUs: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try Files.durableWrite(Data(String(chunkEndUs).utf8), to: doneDir.appendingPathComponent(segment.id))
        for url in [inboxDir.appendingPathComponent("\(segment.id).m4a"), inboxDir.appendingPathComponent("\(segment.id).json")] {
            _ = try? FileManager.default.removeItem(at: url)
        }
    }

    public func markSealed(_ end: WatchRecordingEnd) throws {
        lock.lock(); defer { lock.unlock() }
        try Files.durableWrite(Data(), to: doneDir.appendingPathComponent(end.id))
        _ = try? FileManager.default.removeItem(at: endsDir.appendingPathComponent("\(end.id).json"))
    }

    /// A segment that couldn't be converted is set aside (kept), not retried forever or deleted.
    public func quarantine(_ segment: WatchSegment, reason: String) {
        lock.lock(); defer { lock.unlock() }
        let q = root.appendingPathComponent("quarantine", isDirectory: true)
        try? FileManager.default.createDirectory(at: q, withIntermediateDirectories: true)
        for ext in ["m4a", "json"] {
            let from = inboxDir.appendingPathComponent("\(segment.id).\(ext)")
            try? FileManager.default.moveItem(at: from, to: q.appendingPathComponent("\(segment.id).\(ext)"))
        }
        try? Data(reason.utf8).write(to: q.appendingPathComponent("\(segment.id).reason"))
        // counted as handled so the recording can still be sealed
        try? Files.durableWrite(Data(), to: doneDir.appendingPathComponent(segment.id))
    }

    private func isDone(_ id: String) -> Bool { FileManager.default.fileExists(atPath: doneDir.appendingPathComponent(id).path) }

    public var pendingCount: Int { pending().count }

    /// Keeps the Watch's latest report (newer than the stored one only).
    public func saveReport(_ report: WatchReport) {
        lock.lock(); defer { lock.unlock() }
        let url = root.appendingPathComponent("report.json")
        if let old = WatchWire.decode(WatchReport.self, try? Data(contentsOf: url)), old.at >= report.at { return }
        try? Files.durableWrite(WatchWire.encode(report), to: url)
    }

    public var latestReport: WatchReport? {
        lock.lock(); defer { lock.unlock() }
        return WatchWire.decode(WatchReport.self, try? Data(contentsOf: root.appendingPathComponent("report.json")))
    }

    /// The Watch recordings this phone has queued audio of (one upload capture each).
    public func recordingIds() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(Files.names(doneDir, suffix: "").compactMap { name in name.lastIndex(of: "-").map { String(name[..<$0]) } })
    }

    /// Segments received and handed on so far (kept as small markers), and when the latest was.
    public func receivedSummary() -> (count: Int, last: Date?) {
        lock.lock(); defer { lock.unlock() }
        let names = Files.names(doneDir, suffix: "").filter { !$0.hasSuffix("-end") }
        let dates = names.compactMap { (try? FileManager.default.attributesOfItem(atPath: doneDir.appendingPathComponent($0).path))?[.modificationDate] as? Date }
        return (names.count, dates.max())
    }
}
