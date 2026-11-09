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
    /// Audio parts kept on the Watch that it can't send (no manifest matches them; `orphan_parts`).
    /// nil when the report doesn't say (older Watch apps): unknown, never taken as none.
    public var keptParts: Int? { stats?["orphan_parts"] }
    /// Of the waiting parts, those being re-checked: audio an older iPhone build already converted, which
    /// the Watch sends again after any new audio (`recheck_parts`, `recheck_s`; absent from older Watch apps).
    public var recheckParts: Int { stats?["recheck_parts"] ?? 0 }
    public var recheckSeconds: Int { stats?["recheck_s"] ?? 0 }

    public init(state: State, since: Date?, waitingParts: Int, waitingSeconds: Int? = nil, at: Date, deviceId: String? = nil,
                stats: [String: Int]? = nil) {
        self.deviceId = deviceId
        self.state = state
        self.since = since
        self.waitingParts = waitingParts
        self.waitingSeconds = waitingSeconds
        self.at = at
        self.stats = stats
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
        try Files.durableWrite(WatchWire.encode(end), to: endsDir.appendingPathComponent("\(end.id).json"))
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
        let audio = inboxDir.appendingPathComponent("\(segment.id).m4a")
        try Files.durableCopy(file, to: audio)
        try Files.durableWrite(WatchWire.encode(segment), to: inboxDir.appendingPathComponent("\(segment.id).json"))
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
        if let r = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptsDir.appendingPathComponent("\(id).json"))) {
            return r.sha256 == sha256 && r.binding == binding
        }
        for dir in [inboxDir, quarantineDir] {
            guard let s = WatchWire.decode(WatchSegment.self, try? Data(contentsOf: dir.appendingPathComponent("\(id).json"))),
                  s.id == id, s.binding == binding, s.sha256 == sha256 else { continue }
            let audio = dir.appendingPathComponent("\(id).m4a")
            let size = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int) ?? -1
            if size == s.bytes, (try? Files.sha256(audio)) == sha256 { return true }
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
        try Files.durableWrite(try JSONEncoder().encode(Receipt(sha256: segment.sha256, bytes: segment.bytes, binding: segment.binding)),
                               to: receiptsDir.appendingPathComponent("\(segment.id).json"))
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
