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
    /// Audio parts on the Watch the phone hasn't acknowledged yet, and their recorded length in
    /// seconds (absent from older Watch apps).
    public var waitingParts: Int
    public var waitingSeconds: Int?
    /// The Watch's device id (as in its chunks and samples); absent from older Watch apps.
    public var deviceId: String?
    public var at: Date
    /// Counters since the Watch app launched (transfers, resends, capture buffer allocations…), to
    /// compare builds; absent from older Watch apps.
    public var stats: [String: Int]?
    /// The Watch app's build (`CFBundleVersion`); nil from older Watch apps: unknown.
    public var appBuild: Int?
    /// Audio parts kept on the Watch that it can't send (no manifest matches them; `orphan_parts`).
    /// nil when the report doesn't say (older Watch apps): unknown, never taken as none.
    public var keptParts: Int? { stats?["orphan_parts"] }
    /// Of the waiting parts, those being re-checked: audio an older iPhone build already converted, which
    /// the Watch sends again after any new audio (`recheck_parts`, `recheck_s`; absent from older Watch apps).
    public var recheckParts: Int { stats?["recheck_parts"] ?? 0 }
    public var recheckSeconds: Int { stats?["recheck_s"] ?? 0 }

    public init(state: State, since: Date?, waitingParts: Int, waitingSeconds: Int? = nil, at: Date, deviceId: String? = nil,
                stats: [String: Int]? = nil, appBuild: Int? = nil) {
        self.deviceId = deviceId
        self.appBuild = appBuild
        self.state = state
        self.since = since
        self.waitingParts = waitingParts
        self.waitingSeconds = waitingSeconds
        self.at = at
        self.stats = stats
    }
}

/// One Watch's app build as this iPhone learned it: from a status report (`appBuild`) or, for Watch apps that don't
/// report it, from a performance sample's `app` ("0.1.0 (49)"). Kept per Watch (its device id); for each, the
/// observation with the later Watch time wins (a later lower build too: a reinstall), never the larger build.
public struct WatchAppBuild: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case report, telemetry }
    public var build: Int
    /// When the Watch said so (its own clock).
    public var at: Date
    public var deviceId: String
    public var source: Source
    /// When this iPhone received it (its clock).
    public var receivedAt: Date

    /// A Watch time further ahead of this iPhone's than this isn't used: it would outrank every later observation
    /// until the time came (ASTRA-20261116-IT1-02).
    public static let futureSkew: TimeInterval = 10 * 60

    public init(build: Int, at: Date, deviceId: String, source: Source, receivedAt: Date) {
        self.build = build
        self.at = at
        self.deviceId = deviceId
        self.source = source
        self.receivedAt = receivedAt
    }

    /// The build in a performance sample's `app` ("0.1.0 (49)" → 49); nil when there is none ("0.1.0 (?)").
    public static func parse(app: String) -> Int? {
        guard let open = app.lastIndex(of: "("), app.hasSuffix(")") else { return nil }
        return Int(app[app.index(after: open)..<app.index(before: app.endIndex)])
    }

    /// The Watch's build when it is older than this iPhone's app; nil when it is the same or newer, or either is
    /// unknown (an unknown build is never called up to date, nor out of date).
    public static func behind(watch: Int?, phone: Int?) -> Int? {
        guard let watch, let phone, watch < phone else { return nil }
        return watch
    }

    /// The Apple Watch page's one problem line when the Watch runs an older build than this iPhone; nil otherwise.
    public static func outdatedLine(watch: Int?, phone: Int?) -> String? {
        behind(watch: watch, phone: phone).map { "手表上的 Omi 不是最新版本（\($0)）· 在手表上更新" }
    }
}

/// WatchConnectivity payload keys (property-list values only).
/// One part the Watch asks about: its id and the SHA-256 of its bytes (an acknowledgement must be
/// for these bytes, not merely this id).
public struct WatchInventoryItem: Codable, Equatable, Sendable {
    public var id: String
    public var sha256: String
    public init(id: String, sha256: String) {
        self.id = id
        self.sha256 = sha256
    }
}

public enum WatchWire {
    public static let kind = "kind", manifest = "manifest", acks = "acks", rejects = "rejects", binding = "binding"
    public static let segment = "segment", end = "end", report = "report", perf = "perf"
    /// Watch → iPhone (kind `inventory`): `inventory_items` (`[{id, sha256}]` of delivered parts still
    /// waiting for an ack) and `inventory_id`; `inventory` (their ids) is informational. iPhone → Watch:
    /// `missing` (those it doesn't hold with that checksum) and the same `inventory_id`, beside the usual
    /// `acks` for the ones it holds. Older builds ignore all of these.
    public static let inventory = "inventory", missing = "missing", inventoryItems = "inventory_items", inventoryId = "inventory_id"
    /// iPhone → Watch, in an inventory answer: the parts it holds, as `[{id, sha256}]` (the only thing
    /// in an answer that lets the Watch delete anything).
    public static let inventoryAcks = "inventory_acks"
    /// Watch → iPhone while recording (kind `sync`, a `sendMessage` with a reply): `inventory_items` of parts
    /// waiting for a receipt. The reply carries `inventory_acks` for those the iPhone holds; it names no
    /// question, so nothing in it makes the Watch resend anything.
    public static let sync = "sync"

    public static func syncPing(items: [WatchInventoryItem], binding: String) -> [String: Any] {
        [kind: sync, inventoryItems: inventoryItems(items), self.binding: binding]
    }

    /// The Watch's question: checksummed items only (no id-only list an older phone might answer by filename).
    public static func inventoryQuestion(id: String, items: [WatchInventoryItem], binding: String) -> [String: Any] {
        [kind: inventory, inventoryId: id, inventoryItems: inventoryItems(items), self.binding: binding]
    }

    /// iPhone → Watch, beside the plain `acks`: `[{id, sha256}]` for each audio part it stored (what lets
    /// a current Watch delete the part; an older Watch reads only `acks`).
    public static let receipts = "receipts"

    /// What the iPhone sends after storing items: the unchanged plain acks (ids), plus a checksum receipt
    /// for each audio part.
    public static func acknowledgement(ids: [String], receipts: [WatchInventoryItem]) -> [String: Any] {
        var fields: [String: Any] = [acks: ids]
        if !receipts.isEmpty { fields[self.receipts] = inventoryItems(receipts) }
        return fields
    }

    public static func inventoryItems(_ items: [WatchInventoryItem]) -> [[String: String]] {
        items.map { ["id": $0.id, "sha256": $0.sha256] }
    }

    public static func inventoryItems(from value: Any?) -> [WatchInventoryItem] {
        (value as? [[String: String]] ?? []).compactMap { d in d["id"].flatMap { id in d["sha256"].map { WatchInventoryItem(id: id, sha256: $0) } } }
    }

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
    case damaged(String), wrongPhone, identityUnreadable
    public var errorDescription: String? {
        switch self {
        case .damaged(let s): return "segment damaged in transfer (\(s))"
        case .wrongPhone: return "the recording belongs to another iPhone"
        case .identityUnreadable: return "this iPhone hasn't been unlocked since it restarted"
        }
    }
}

#if DEBUG
/// Tests only: these paths (and, unless `exactly`, everything under them) fail fsync, to show what a failed sync does
/// (ASTRA-20261117-IT2-02). A rule can let `after` syncs succeed first, fail only `times` times, and give the errno.
enum SyncFaults {
    private struct Rule {
        var exactly: Bool
        var after: Int
        var times: Int?
        var code: Int32
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var rules: [String: Rule] = [:]

    static func set(_ url: URL, failing: Bool, exactly: Bool = false, after: Int = 0, times: Int? = nil, errno code: Int32 = EIO) {
        let path = url.standardizedFileURL.path
        lock.withLock { rules[path] = failing ? Rule(exactly: exactly, after: after, times: times, code: code) : nil }
    }

    /// The errno this sync of `url` fails with, or nil (it goes ahead).
    static func fault(_ url: URL) -> Int32? {
        let path = url.standardizedFileURL.path
        return lock.withLock {
            guard let key = rules.keys.first(where: { $0 == path || (!rules[$0]!.exactly && path.hasPrefix($0 + "/")) }),
                  var rule = rules[key] else { return nil }
            defer { rules[key] = rule }
            if rule.after > 0 { rule.after -= 1; return nil }
            if let t = rule.times {
                guard t > 0 else { return nil }
                rule.times = t - 1
            }
            return rule.code
        }
    }

    static func failing(_ url: URL) -> Bool { fault(url) != nil }
}
#endif

/// A file operation that failed: which one, on which file, and errno (ASTRA-20261117-IT3-02).
struct DurableFileError: Error, CustomStringConvertible {
    let operation: String
    let file: String
    let code: Int32
    var description: String { "\(operation) \(file) failed: errno \(code) (\(String(cString: strerror(code))))" }
}

enum Files {
    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Atomic, durable: write a temporary file, fsync it, rename, fsync the directory. Throws if any step fails,
    /// a sync included (ASTRA-20261117-IT2-02): a temporary file that didn't sync is removed, never renamed into place,
    /// so nothing (a receipt, an acknowledgement) can stand for bytes that may not be on disk.
    static func durableWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tmp)
        try place(tmp, at: url)
    }

    static func durableCopy(_ from: URL, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        _ = try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: from, to: tmp)
        try place(tmp, at: url)
    }

    /// Syncs the temporary file, then renames it over `url`; on any failure only the temporary file is removed.
    private static func place(_ tmp: URL, at url: URL) throws {
        do {
            #if os(iOS) || os(watchOS)
            // readable after first unlock, like everything written in the background (a copy keeps its source's class)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: tmp.path)
            #endif
            try fsync(tmp)
        } catch {
            _ = try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        try replace(url, with: tmp)
    }

    /// rename(2): the name holds the old file or the new one, never nothing, even across a crash
    /// (ASTRA-20261117-IT1-01; removing first left a moment with no manifest, receipt or audio copy at all).
    /// A failed directory sync is an error too: the rename may not survive a crash, so the write isn't reported durable.
    static func replace(_ url: URL, with tmp: URL) throws {
        guard rename(tmp.path, url.path) == 0 else { throw DurableFileError(operation: "rename", file: url.lastPathComponent, code: errno) }
        try fsync(url.deletingLastPathComponent())
    }

    /// fsync(2), retried when interrupted (EINTR); any other failure throws with its errno (ASTRA-20261117-IT3-02).
    static func fsync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw DurableFileError(operation: "open", file: url.lastPathComponent, code: errno) }
        defer { close(fd) }
        while true {
            #if DEBUG
            let injected = SyncFaults.fault(url)
            #else
            let injected: Int32? = nil
            #endif
            let code: Int32 = injected ?? (Darwin.fsync(fd) == 0 ? 0 : errno)
            if code == 0 { return }
            if code != EINTR { throw DurableFileError(operation: "fsync", file: url.lastPathComponent, code: code) }
        }
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
    private var segmentIndex: [String: WatchSegment]? { didSet { segmentList = nil } }
    /// `segments()`'s answer, kept until the index changes: with hundreds of parts waiting, sorting them and
    /// building their URLs on every call (several per send loop) used up the 2 s background CPU allowance.
    private var segmentList: [(segment: WatchSegment, file: URL)]?
    /// Times that list was built (for tests).
    public private(set) var segmentListBuilds = 0
    private var endIndex: [String: WatchRecordingEnd]?
    /// Audio under segments/ with no manifest that matches it (an older build ended between moving a
    /// part in and publishing its manifest, or the metadata is damaged): id → bytes. Kept, never sent
    /// or deleted, counted in `waitingBytes`; a person can recover it from the files.
    public var orphans: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        loadSegments()
        return orphanIndex
    }
    private var orphanIndex: [String: Int] = [:]
    /// Manifests read from disk (to compare builds; flat after the first read).
    public private(set) var manifestReads = 0

    public init(root: URL) {
        self.root = root
        for d in [segmentsDir, endsDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// Takes a finished segment file (moved in) and its manifest.
    /// The manifest is written first as an intent, so a part whose manifest isn't published (a failed
    /// write, or the app ending in between) is published again from it on the next load.
    public func add(segmentFile: URL, segment: WatchSegment) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            try publish(segmentFile: segmentFile, segment: segment)
        } catch {
            // whatever got written (intent, audio) is found by the next read, which reloads and republishes it from its
            // intent, not only after a relaunch (ASTRA-20261117-IT3-03)
            segmentIndex = nil
            throw error
        }
    }

    /// Called with `lock` held.
    private func publish(segmentFile: URL, segment: WatchSegment) throws {
        let intent = segmentsDir.appendingPathComponent("\(segment.id).intent")
        try Files.durableWrite(WatchWire.encode(segment), to: intent)
        let audio = segmentsDir.appendingPathComponent("\(segment.id).m4a")
        if segmentFile != audio {
            _ = try? FileManager.default.removeItem(at: audio)
            try FileManager.default.moveItem(at: segmentFile, to: audio)
        }
        try Files.fsync(audio)
        try Files.durableWrite(WatchWire.encode(segment), to: segmentsDir.appendingPathComponent("\(segment.id).json"))
        _ = try? FileManager.default.removeItem(at: intent)
        loadSegments()
        segmentIndex?[segment.id] = segment
        orphanIndex[segment.id] = nil
    }

    public func add(end: WatchRecordingEnd) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            try Files.durableWrite(WatchWire.encode(end), to: endsDir.appendingPathComponent("\(end.id).json"))
        } catch {
            endIndex = nil  // an end that was renamed in is read again (ASTRA-20261117-IT3-03)
            throw error
        }
        loadEnds()
        endIndex?[end.id] = end
    }

    /// Called with `lock` held.
    private func loadSegments() {
        guard segmentIndex == nil else { return }
        var index: [String: WatchSegment] = [:]
        let audio = Set(Files.names(segmentsDir, suffix: ".m4a"))  // one listing, not a lookup per part
        for name in Files.names(segmentsDir, suffix: ".json") {
            manifestReads += 1
            guard let s = WatchWire.decode(WatchSegment.self, try? Data(contentsOf: segmentsDir.appendingPathComponent(name))),
                  audio.contains("\(s.id).m4a") else { continue }
            index[s.id] = s
        }
        reconcile(&index)
        segmentIndex = index
    }

    /// Audio without a published manifest: published again from its intent when the intent is readable
    /// and the audio still matches it (size and SHA-256); otherwise kept and counted as an orphan.
    /// An intent left without audio (the move never happened) is only metadata and is removed.
    private func reconcile(_ index: inout [String: WatchSegment]) {
        orphanIndex = [:]
        for name in Files.names(segmentsDir, suffix: ".m4a") {
            let id = String(name.dropLast(4))
            guard index[id] == nil else { continue }
            let audio = segmentsDir.appendingPathComponent(name), intent = segmentsDir.appendingPathComponent("\(id).intent")
            let size = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int) ?? -1
            if let s = WatchWire.decode(WatchSegment.self, try? Data(contentsOf: intent)), s.id == id, s.bytes == size,
               (try? Files.sha256(audio)) == s.sha256,
               (try? Files.durableWrite(WatchWire.encode(s), to: segmentsDir.appendingPathComponent("\(id).json"))) != nil {
                _ = try? FileManager.default.removeItem(at: intent)
                index[id] = s
            } else {
                orphanIndex[id] = max(0, size)
            }
        }
        for name in Files.names(segmentsDir, suffix: ".intent") {
            let id = String(name.dropLast(7))
            if !FileManager.default.fileExists(atPath: segmentsDir.appendingPathComponent("\(id).m4a").path) {
                _ = try? FileManager.default.removeItem(at: segmentsDir.appendingPathComponent(name))
            }
        }
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
        if let segmentList { return segmentList }
        let list = (segmentIndex ?? [:]).values
            .sorted { ($0.recordingStartedAt, $0.index) < ($1.recordingStartedAt, $1.index) }
            .map { ($0, segmentsDir.appendingPathComponent("\($0.id).m4a")) }
        segmentList = list
        segmentListBuilds += 1
        return list
    }

    public func ends() -> [WatchRecordingEnd] {
        lock.lock(); defer { lock.unlock() }
        loadEnds()
        return Array((endIndex ?? [:]).values)
    }

    /// Plain acks (ids): they remove recording-end markers only, never anything under `segments/`.
    /// Returns the ends removed.
    @discardableResult
    public func acknowledgeEnds(_ ids: [String]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var removed: [String] = []
        for id in ids where !id.contains("/") {
            let url = endsDir.appendingPathComponent("\(id).json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            _ = try? FileManager.default.removeItem(at: url)
            endIndex?[id] = nil
            removed.append(id)
        }
        return removed
    }

    /// Checksum receipts from the phone: a part's audio and manifest go only when its own manifest,
    /// read from disk now, names this id and this checksum. A missing or unreadable manifest, another
    /// checksum or an unknown id keeps the audio. Returns the parts removed.
    @discardableResult
    public func retire(receipts: [WatchInventoryItem]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var removed: [String] = []
        for receipt in receipts where !receipt.id.contains("/") {
            let manifest = segmentsDir.appendingPathComponent("\(receipt.id).json")
            guard let s = WatchWire.decode(WatchSegment.self, try? Data(contentsOf: manifest)),
                  s.id == receipt.id, s.sha256 == receipt.sha256 else { continue }
            _ = try? FileManager.default.removeItem(at: segmentsDir.appendingPathComponent("\(receipt.id).m4a"))
            _ = try? FileManager.default.removeItem(at: manifest)
            segmentIndex?[receipt.id] = nil
            removed.append(receipt.id)
        }
        return removed
    }

    /// Whether audio is still kept under this id (manifest readable or not).
    public func holdsAudio(_ id: String) -> Bool {
        !id.contains("/") && FileManager.default.fileExists(atPath: segmentsDir.appendingPathComponent("\(id).m4a").path)
    }

    public var pendingCount: Int { segments().count + ends().count }

    /// Bytes of audio waiting for the phone.
    public var waitingBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        loadSegments()
        return (segmentIndex ?? [:]).values.reduce(0) { $0 + Int64($1.bytes) } + orphanIndex.values.reduce(0) { $0 + Int64($1) }
    }
}

// MARK: - Phone side

/// What the phone has received from the Watch, stored durably before it is acknowledged, then
/// converted into upload envelopes. Receiving the same segment again is acknowledged again and
/// changes nothing.
public final class PhoneWatchInbox: @unchecked Sendable {
    public let root: URL
    /// This iPhone's identity, read at each use; nil while unreadable (nothing is accepted then).
    private let binding: () -> String?
    private let lock = NSLock()
    /// Files (by path) whose sync and directory sync succeeded in this run: what "held" may rest on. Not saved: after a
    /// relaunch each is synced again before it is trusted.
    private var synced: Set<String> = []
    private var inboxDir: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    private var endsDir: URL { root.appendingPathComponent("ends", isDirectory: true) }
    private var doneDir: URL { root.appendingPathComponent("done", isDirectory: true) }
    private var receiptsDir: URL { root.appendingPathComponent("receipts", isDirectory: true) }
    private var quarantineDir: URL { root.appendingPathComponent("quarantine", isDirectory: true) }

    public convenience init(root: URL, binding: String) {
        self.init(root: root, currentBinding: { binding })
    }

    public init(root: URL, currentBinding: @escaping () -> String?) {
        self.root = root
        self.binding = currentBinding
        for d in [inboxDir, endsDir, doneDir, receiptsDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// Stores a received segment (copied from WatchConnectivity's temporary file before the
    /// callback returns). Returns normally only when it is durable and matches its hash.
    public func accept(file: URL, segment: WatchSegment) throws {
        guard let binding = binding() else { throw WatchRelayError.identityUnreadable }
        guard segment.binding == binding else { throw WatchRelayError.wrongPhone }
        lock.lock(); defer { lock.unlock() }
        // acknowledged again only if these very bytes are already held here; other bytes under the same
        // id are refused (never acknowledged); anything else (no copy, a damaged one, a receipt from
        // before receipts had checksums) is stored again and acknowledged once durable
        if holds(segment.id, sha256: segment.sha256, binding: binding) { return }
        if let held = heldChecksum(segment.id), held != segment.sha256 {
            throw WatchRelayError.damaged("different bytes are already stored under \(segment.id)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
        guard size == segment.bytes else { throw WatchRelayError.damaged("size \(size) ≠ \(segment.bytes)") }
        guard try Files.sha256(file) == segment.sha256 else { throw WatchRelayError.damaged("SHA-256") }
        let audio = inboxDir.appendingPathComponent("\(segment.id).m4a"), manifest = inboxDir.appendingPathComponent("\(segment.id).json")
        synced.subtract([audio.path, manifest.path])
        try Files.durableCopy(file, to: audio)
        synced.insert(audio.path)
        try Files.durableWrite(WatchWire.encode(segment), to: manifest)
        synced.insert(manifest.path)
    }

    /// The one rule for every answer that says "held" (a repeat accept, the inventory answer, a sync-ping receipt):
    /// each file, and its directory, synced successfully, in this run or now. Caller holds the lock.
    private func durable(_ files: [URL]) -> Bool {
        for url in files where !synced.contains(url.path) {
            guard (try? Files.fsync(url)) != nil, (try? Files.fsync(url.deletingLastPathComponent())) != nil else { return false }
            synced.insert(url.path)
        }
        return true
    }

    /// What a conversion leaves behind: the bytes it converted (checksum, size) for this iPhone.
    struct Receipt: Codable {
        var sha256: String
        var bytes: Int
        var binding: String
    }

    /// This iPhone durably holds these bytes under `id` (caller holds the lock): converted with a
    /// matching receipt, or a readable copy in the inbox or kept aside whose audio still hashes to it.
    private func holds(_ id: String, sha256: String, binding: String) -> Bool {
        let receipt = receiptsDir.appendingPathComponent("\(id).json")
        if let r = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receipt)) {
            // a receipt not known durable falls through to a copy still in the inbox (kept until the receipt is written)
            if r.sha256 == sha256, r.binding == binding, durable([receipt]) { return true }
            if r.sha256 != sha256 || r.binding != binding { return false }
        }
        for dir in [inboxDir, quarantineDir] {
            let manifest = dir.appendingPathComponent("\(id).json")
            guard let s = WatchWire.decode(WatchSegment.self, try? Data(contentsOf: manifest)),
                  s.id == id, s.binding == binding, s.sha256 == sha256 else { continue }
            let audio = dir.appendingPathComponent("\(id).m4a")
            let size = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int) ?? -1
            if size == s.bytes, (try? Files.sha256(audio)) == sha256, durable([audio, manifest]) { return true }
        }
        return false
    }

    /// The checksum of bytes recorded under `id` (receipt or readable manifest), if any (caller holds the lock).
    private func heldChecksum(_ id: String) -> String? {
        if let r = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptsDir.appendingPathComponent("\(id).json"))) { return r.sha256 }
        for dir in [inboxDir, quarantineDir] {
            if let s = WatchWire.decode(WatchSegment.self, try? Data(contentsOf: dir.appendingPathComponent("\(id).json"))), s.id == id {
                return s.sha256
            }
        }
        return nil
    }

    /// Which of the Watch's waiting parts this iPhone holds, bytes and all (see `holds`): those are
    /// acknowledged again; every other one is missing (sent again), never acknowledged on a filename.
    /// Another iPhone's question is refused.
    public func answer(items: [WatchInventoryItem], binding asked: String?) throws -> (acks: [String], missing: [String]) {
        guard let binding = binding() else { throw WatchRelayError.identityUnreadable }
        guard asked == binding else { throw WatchRelayError.wrongPhone }
        lock.lock(); defer { lock.unlock() }
        var acks: [String] = [], missing: [String] = []
        for item in items where !item.id.isEmpty && !item.id.contains("/") && item.sha256.count == 64 {
            if holds(item.id, sha256: item.sha256, binding: binding) { acks.append(item.id) } else { missing.append(item.id) }
        }
        return (acks, missing)
    }

    /// Receipts for a sync ping: only the (id, sha256) pairs this phone holds with that checksum. An id asked
    /// with two different checksums gets no receipt at all (the Watch can't have both), and each pair is
    /// returned once.
    public func receipts(items: [WatchInventoryItem], binding asked: String?) throws -> [WatchInventoryItem] {
        var hashes: [String: Set<String>] = [:]
        for item in items { hashes[item.id, default: []].insert(item.sha256) }
        let unique = hashes.compactMap { id, set in set.count == 1 ? WatchInventoryItem(id: id, sha256: set.first!) : nil }
            .sorted { $0.id < $1.id }
        let held = Set(try answer(items: unique, binding: asked).acks)
        return unique.filter { held.contains($0.id) }
    }

    public func accept(end: WatchRecordingEnd) throws {
        guard let binding = binding() else { throw WatchRelayError.identityUnreadable }
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
        // the receipt (which bytes were converted) first: it is what a later acknowledgement relies on
        let receipt = receiptsDir.appendingPathComponent("\(segment.id).json")
        synced.remove(receipt.path)
        try Files.durableWrite(try JSONEncoder().encode(Receipt(sha256: segment.sha256, bytes: segment.bytes, binding: segment.binding)),
                               to: receipt)
        synced.insert(receipt.path)
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
        let q = quarantineDir
        try? FileManager.default.createDirectory(at: q, withIntermediateDirectories: true)
        for ext in ["m4a", "json"] {
            let from = inboxDir.appendingPathComponent("\(segment.id).\(ext)")
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            let to = q.appendingPathComponent("\(segment.id).\(ext)")
            _ = try? FileManager.default.replaceItemAt(to, withItemAt: from)  // a newer copy replaces an older one
            if FileManager.default.fileExists(atPath: from.path) { try? FileManager.default.moveItem(at: from, to: to) }
        }
        try? Data(reason.utf8).write(to: q.appendingPathComponent("\(segment.id).reason"))
        // counted as handled so the recording can still be sealed
        try? Files.durableWrite(Data(), to: doneDir.appendingPathComponent(segment.id))
    }

    private func isDone(_ id: String) -> Bool { FileManager.default.fileExists(atPath: doneDir.appendingPathComponent(id).path) }

    public var pendingCount: Int { pending().count }

    /// A report with the Watch change count it was received at: one file, replaced atomically, so an interrupted save
    /// can't pair an old report with a new count (ASTRA-20261117-IT1-01).
    struct ReportRecord: Codable {
        var report: WatchReport
        var generation: Int
    }

    /// Keeps the Watch's latest report (newer than the stored one only), with the Watch change it came after. A stored
    /// one dated more than `WatchAppBuild.futureSkew` ahead of now (ASTRA-20261116-IT3-01), from before the paired Watch
    /// last changed (ASTRA-20261116-IT4-01), or saved without a count doesn't hold off a new one.
    public func saveReport(_ report: WatchReport, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let generation = changeGeneration()
        let (old, oldGeneration) = storedReport()
        if let old, old.at >= report.at, old.at <= now.addingTimeInterval(WatchAppBuild.futureSkew), oldGeneration == generation { return }
        try? Files.durableWrite(WatchWire.encode(ReportRecord(report: report, generation: generation)),
                                to: root.appendingPathComponent("report-record.json"))
    }

    /// Keeps what a Watch said its app build is: per Watch, newer (by Watch time) than its stored observation only.
    /// One dated ahead of `receivedAt` by more than `futureSkew` is dropped (unknown, never pinned).
    public func saveAppBuild(_ build: WatchAppBuild) {
        guard build.at <= build.receivedAt.addingTimeInterval(WatchAppBuild.futureSkew) else { return }
        lock.lock(); defer { lock.unlock() }
        var all = appBuilds()
        if let old = all[build.deviceId], old.at >= build.at { return }
        all[build.deviceId] = build
        // a few Watches at most; the longest unheard ones go
        for id in all.values.sorted(by: { $0.receivedAt > $1.receivedAt }).dropFirst(8).map(\.deviceId) { all[id] = nil }
        try? Files.durableWrite(WatchWire.encode(all), to: root.appendingPathComponent("app-builds.json"))
    }

    private func appBuilds() -> [String: WatchAppBuild] {
        WatchWire.decode([String: WatchAppBuild].self, try? Data(contentsOf: root.appendingPathComponent("app-builds.json"))) ?? [:]
    }

    /// What this Watch said its build is; nil when it hasn't, or when no Watch is named.
    public func appBuild(for deviceId: String?) -> WatchAppBuild? {
        guard let deviceId else { return nil }
        lock.lock(); defer { lock.unlock() }
        return appBuilds()[deviceId]
    }

    /// The build of the Watch whose report is the latest (the one in use): another Watch's is never taken for it
    /// (ASTRA-20261116-IT1-01). None when that report is dated more than `futureSkew` ahead (its time can't be used,
    /// even one saved by an earlier run), from before the paired Watch last changed (ASTRA-20261116-IT3-01), or saved
    /// without its change count (by an earlier build).
    public var appBuild: WatchAppBuild? { appBuild(now: Date()) }

    public func appBuild(now: Date) -> WatchAppBuild? {
        // one lock for the report, its count, the current count and the build: a save between separate reads could
        // pair an old report with the new count (ASTRA-20261117-IT1-02)
        lock.lock(); defer { lock.unlock() }
        let (report, generation) = storedReport()
        guard let report, report.at <= now.addingTimeInterval(WatchAppBuild.futureSkew), let generation,
              generation == changeGeneration(), let id = report.deviceId else { return nil }
        return appBuilds()[id]
    }

    /// The paired Watch changed (another Watch, or none): until a report received after this, no Watch is the one in
    /// use. Counted on this iPhone, never compared with a Watch's clock (ASTRA-20261116-IT4-01). Only that pointer is
    /// cleared; what each Watch said stays.
    public func watchChanged(at: Date) {
        lock.lock(); defer { lock.unlock() }
        try? Files.durableWrite(WatchWire.encode(["generation": changeGeneration() + 1]), to: root.appendingPathComponent("watch-changed.json"))
    }

    /// How many Watch changes this iPhone has seen (0: none). A file without a count (written by build 57, which kept
    /// the change's time) counts as one. Called with the lock held.
    private func changeGeneration() -> Int {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("watch-changed.json")) else { return 0 }
        return WatchWire.decode([String: Int].self, data)?["generation"] ?? 1
    }

    /// The stored report and the change count it was received at; a `report.json` from an earlier build has no count
    /// (nil). Called with the lock held.
    private func storedReport() -> (WatchReport?, Int?) {
        if let record = WatchWire.decode(ReportRecord.self, try? Data(contentsOf: root.appendingPathComponent("report-record.json"))) {
            return (record.report, record.generation)
        }
        return (WatchWire.decode(WatchReport.self, try? Data(contentsOf: root.appendingPathComponent("report.json"))), nil)
    }

    public var latestReport: WatchReport? {
        lock.lock(); defer { lock.unlock() }
        return storedReport().0
    }

    /// How a recording's parts go to the server, decided once and kept: `aac` (the Watch's file,
    /// unchanged) or `pcm` (decoded here, for servers without `watch_aac`). A recording this phone
    /// already started converting to PCM (an earlier version) stays PCM.
    public func format(of recordingId: String, choosing preferred: () -> String) -> String {
        lock.lock(); defer { lock.unlock() }
        let url = root.appendingPathComponent("formats", isDirectory: true).appendingPathComponent(recordingId)
        if let kept = try? String(contentsOf: url, encoding: .utf8), !kept.isEmpty { return kept }
        let converted = Files.names(doneDir, suffix: "").contains { $0.hasPrefix(recordingId + "-") && !$0.hasSuffix("-end") }
        let chosen = converted ? "pcm" : preferred()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Files.durableWrite(Data(chosen.utf8), to: url)
        return chosen
    }

    /// The Watch recordings this phone has queued audio of (one upload capture each).
    public func recordingIds() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(Files.names(doneDir, suffix: "").compactMap { name in name.lastIndex(of: "-").map { String(name[..<$0]) } })
    }

    /// Segments received and handed on so far (kept as small markers), and when the latest was.
    public func receivedSummary() -> (count: Int, last: Date?) {
        lock.lock(); defer { lock.unlock() }
        // Thousands of parts: stat each one only when the folder changed (it is read for every snapshot).
        var st = stat()
        let stamp = stat(doneDir.path, &st) == 0 ? [Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec), Int(st.st_ino)] : nil
        if let stamp, let cached = summaryCache, cached.stamp == stamp { return cached.value }
        // unreadable: report what was read but never cache it (the next call reads again)
        guard let listed = try? FileManager.default.contentsOfDirectory(atPath: doneDir.path) else {
            summaryCache = nil
            return (0, nil)
        }
        let names = listed.filter { !$0.hasPrefix(".") && !$0.hasSuffix("-end") }
        let dates = names.compactMap { (try? FileManager.default.attributesOfItem(atPath: doneDir.appendingPathComponent($0).path))?[.modificationDate] as? Date }
        let value = (names.count, dates.max())
        summaryCache = stamp.map { (stamp: $0, value: value) }
        return value
    }
    private var summaryCache: (stamp: [Int], value: (count: Int, last: Date?))?
}
