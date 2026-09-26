import Foundation
import OmiProtocol

// MARK: - Manifest

/// Persistent description of an unsealed capture (`capture.json` in its journal directory).
/// Rewritten atomically at begin, on metadata changes, and at every chunk rotation.
public struct CaptureManifest: Codable, Equatable, Sendable {
    public struct Ring: Codable, Equatable, Sendable {
        public var infoReadSeq: UInt64
        public var infoWriteSeq: UInt64
        public var dropped: UInt64
        public var generation: Int
        public var rtcValid: Bool
        public var coversUntil: String
    }

    public var captureId: String
    public var source: CaptureSource
    public var deviceId: String
    public var deviceName: String?
    public var modelNumber: String?
    public var firmwareRevision: String?
    public var hardwareRevision: String?
    public var codecId: Int?
    public var captureStartedAt: String
    public var anchorWallMs: Int64
    public var timezone: String?
    public var offlineStorage: Bool?
    public var appVersion: String?
    public var openChunkSequence: Int
    public var openChunkStartOffsetUs: Int64
    public var ring: Ring?

    public var anchorWall: Date { Date(timeIntervalSince1970: Double(anchorWallMs) / 1000) }
    public func wallDate(offsetUs: Int64) -> Date { anchorWall.addingTimeInterval(Double(offsetUs) / 1_000_000) }

    static let fileName = "capture.json"

    static func journalName(_ seq: Int) -> String { "chunk-\(String(format: "%06d", seq)).journal" }

    func header(
        chunkSequence: Int, codecId: Int, startUs: Int64, endUs: Int64, recordCount: Int, payloadBytes: Int,
        ringInfo: RingChunkInfo?
    ) -> EnvelopeHeader {
        EnvelopeHeader(
            captureId: captureId, chunkSequence: chunkSequence, deviceId: deviceId, deviceName: deviceName,
            modelNumber: modelNumber, firmwareRevision: firmwareRevision, hardwareRevision: hardwareRevision,
            source: source, payloadFormat: source == .deviceRing ? .ringRecordsV1 : .bleNotificationsV1,
            codecId: codecId, captureStartedAt: captureStartedAt, chunkStartOffsetUs: startUs,
            chunkEndOffsetUs: endUs,
            clockQuality: source == .deviceRing ? ((ring?.rtcValid ?? false) ? .deviceSeconds : .unknown) : .phoneAnchored,
            timezone: timezone, recordCount: recordCount, payloadBytes: payloadBytes,
            offlineStorage: source == .liveBLE ? offlineStorage : nil, ring: ringInfo, appVersion: appVersion)
    }
}

// MARK: - Ring journal records

/// Ring journal on disk: `[seq u64 LE][444-byte record][crc32 u32 LE over the preceding 452]`.
/// The envelope payload strips the seq and CRC; they exist for exact torn-tail recovery.
public enum RingJournal {
    public static let entrySize = 8 + RingProtocol.recordSize + 4

    public static func encode(seq: UInt64, record: Data) -> Data {
        precondition(record.count == RingProtocol.recordSize)
        var out = Data(capacity: entrySize)
        out.append(withUnsafeBytes(of: seq.littleEndian) { Data($0) })
        out.append(record)
        out.append(withUnsafeBytes(of: CRC32.checksum(out).littleEndian) { Data($0) })
        return out
    }

    public static func scan(_ data: Data) -> (entries: [(seq: UInt64, record: Data)], validLength: Int) {
        let b = [UInt8](data)
        var off = 0
        var out: [(UInt64, Data)] = []
        while off + entrySize <= b.count {
            var seq: UInt64 = 0
            for i in (0..<8).reversed() { seq = seq << 8 | UInt64(b[off + i]) }
            let crcOff = off + 8 + RingProtocol.recordSize
            let stored = UInt32(b[crcOff]) | UInt32(b[crcOff + 1]) << 8 | UInt32(b[crcOff + 2]) << 16 | UInt32(b[crcOff + 3]) << 24
            let crc = b.withUnsafeBytes { CRC32.update(0, UnsafeRawBufferPointer(rebasing: $0[off..<crcOff])) }
            guard crc == stored else { break }
            out.append((seq, Data(b[(off + 8)..<crcOff])))
            off += entrySize
        }
        return (out, off)
    }
}

// MARK: - Rotation policy

public enum RotationReason: String, Sendable {
    case maxAge = "max_age", idle, disconnect, doubleTap = "double_tap", lifecycle, forced, recordLimit = "record_limit"
    case discontinuity
}

/// When live chunks close (capture-format-v1.md: ~60 s, 5 s idle, disconnect, double tap, lifecycle).
public struct ChunkRotationPolicy: Sendable, Equatable {
    public var maxChunkDurationUs: Int64 = 60_000_000
    public var idleRotationUs: Int64 = 5_000_000
    /// A chunk must span < 2^32 µs (≈ 4294 s). After a long suspension the open chunk is closed in
    /// pieces no longer than this.
    public var maxChunkSpanUs: Int64 = 4_000_000_000

    public init() {}

    /// Automatic rotation check (timer tick or before appending a record).
    public func automaticReason(chunkAgeUs: Int64, recordCount: Int, sinceLastRecordUs: Int64?) -> RotationReason? {
        if chunkAgeUs >= maxChunkDurationUs { return .maxAge }
        if recordCount > 0, let s = sinceLastRecordUs, s >= idleRotationUs { return .idle }
        return nil
    }

    /// End offsets of the chunks to close so that `[chunkStartUs, nowUs]` is covered with
    /// spans ≤ `maxChunkSpanUs`. The last end is `nowUs`.
    public func closingEnds(chunkStartUs: Int64, nowUs: Int64) -> [Int64] {
        var ends: [Int64] = []
        var start = chunkStartUs
        while nowUs - start > maxChunkSpanUs {
            start += maxChunkSpanUs
            ends.append(start)
        }
        ends.append(max(nowUs, start))
        return ends
    }
}

public struct CaptureDeviceMeta: Equatable, Sendable {
    public var deviceId: String
    public var deviceName: String?
    public var modelNumber: String?
    public var firmwareRevision: String?
    public var hardwareRevision: String?
    public var codec: OmiCodec?
    public var offlineStorage: Bool?

    public init(deviceId: String, deviceName: String? = nil, modelNumber: String? = nil, firmwareRevision: String? = nil, hardwareRevision: String? = nil, codec: OmiCodec? = nil, offlineStorage: Bool? = nil) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.modelNumber = modelNumber
        self.firmwareRevision = firmwareRevision
        self.hardwareRevision = hardwareRevision
        self.codec = codec
        self.offlineStorage = offlineStorage
    }
}

public struct CaptureEnvironment: Sendable {
    public var dirs: CaptureDirectories
    public var outbox: Outbox
    public var clock: CaptureClock
    public var appVersion: String?
    public var timezone: String?
    public var idGenerator: @Sendable () -> UUID

    /// Test-only fault injection.
    var faults: FaultInjector?

    public init(dirs: CaptureDirectories, outbox: Outbox, clock: CaptureClock, appVersion: String?, timezone: String?, idGenerator: @escaping @Sendable () -> UUID = { UUID() }) {
        self.dirs = dirs
        self.outbox = outbox
        self.clock = clock
        self.appVersion = appVersion
        self.timezone = timezone
        self.idGenerator = idGenerator
    }

    func saveManifest(_ m: CaptureManifest, in dir: URL) throws {
        try faults?.manifestSave?()
        try JSONFile.save(m, to: dir.appendingPathComponent(CaptureManifest.fileName))
    }

    func sync(_ journal: AppendFile, full: Bool) throws {
        try faults?.journalSync?()
        if full { try journal.fullSync() } else { try journal.sync() }
    }

    func newId() -> String { idGenerator().uuidString.lowercased() }

    /// Anchor with wall time truncated to milliseconds, so `capture_started_at` is exact.
    func makeAnchor() -> CaptureAnchor {
        let mono = clock.monotonicNanoseconds()
        let wallMs = (clock.wallNow().timeIntervalSince1970 * 1000).rounded(.down)
        return CaptureAnchor(wall: Date(timeIntervalSince1970: wallMs / 1000), monoNs: mono)
    }
}

// MARK: - Live capture

/// One live capture = one BLE connection (subscribe → disconnect).
/// Every notification is journaled (same record format as the envelope payload) before anything
/// else; the journal is fsync'd at least once per second. Chunks rotate per `ChunkRotationPolicy`
/// into immutable envelopes in `outbox/pending`.
///
/// Rotation order (crash- and error-safe): fsync the segment → publish its envelope (an existing
/// identity is never overwritten) → freeze the segment (never appended again) and open the next
/// one → commit the manifest. If the manifest commit fails it is retried on every tick; recovery
/// reconstructs uncommitted rotations from the published envelopes.
///
/// Not thread-safe: confine to the engine queue.
public final class LiveCaptureRecorder {
    public struct Stats: Equatable, Sendable {
        public var captureId: String?
        public var chunkSequence = 0
        public var chunkRecords = 0
        public var totalRecords = 0
        public var totalBytes: Int64 = 0
        public var chunksFinalized = 0
    }

    public let env: CaptureEnvironment
    public var policy: ChunkRotationPolicy
    /// Codec to assume when a capture ends before the codec read completed (last known per device).
    public var codecFallback: (String) -> Int? = { _ in nil }
    public var onChunkFinalized: ((OutboxItem) -> Void)?
    public var onSealWritten: ((OutboxItem) -> Void)?

    private var manifest: CaptureManifest?
    private var anchor: CaptureAnchor?
    private var journal: AppendFile?
    private var dir: URL?
    private var chunkRecordCount = 0
    private var lastRecordOffsetUs: Int64?
    private var sessionStartPending = false
    private var lastSyncMono: UInt64 = 0
    private(set) var manifestDirty = false
    public private(set) var stats = Stats()
    public private(set) var lastError: String?
    /// Set when a write failed for lack of space; the engine's storage guard reacts.
    public private(set) var outOfSpace = false

    public init(env: CaptureEnvironment, policy: ChunkRotationPolicy = ChunkRotationPolicy()) {
        self.env = env
        self.policy = policy
    }

    public var isActive: Bool { manifest != nil }
    public var captureId: String? { manifest?.captureId }
    public var captureStartedAt: Date? { manifest?.anchorWall }

    public func nowOffsetUs() -> Int64? {
        anchor.map { $0.offsetUs(env.clock.monotonicNanoseconds()) }
    }

    /// Starts a capture at the moment the audio subscription became effective.
    @discardableResult
    public func begin(meta: CaptureDeviceMeta) throws -> String {
        if isActive { _ = finish(reason: .bleDisconnected) }
        let id = env.newId()
        let a = env.makeAnchor()
        let d = env.dirs.journalLive.appendingPathComponent(id, isDirectory: true)
        try FileIO.ensureDirectory(d)
        let m = CaptureManifest(
            captureId: id, source: .liveBLE, deviceId: meta.deviceId, deviceName: meta.deviceName,
            modelNumber: meta.modelNumber, firmwareRevision: meta.firmwareRevision,
            hardwareRevision: meta.hardwareRevision, codecId: meta.codec?.rawValue,
            captureStartedAt: ISO8601UTC.format(a.wall), anchorWallMs: Int64(a.wall.timeIntervalSince1970 * 1000),
            timezone: env.timezone, offlineStorage: meta.offlineStorage, appVersion: env.appVersion,
            openChunkSequence: 0, openChunkStartOffsetUs: 0, ring: nil)
        do {
            try env.saveManifest(m, in: d)
            journal = try AppendFile(url: d.appendingPathComponent(CaptureManifest.journalName(0)))
        } catch {
            try? FileManager.default.removeItem(at: d)
            throw error
        }
        manifest = m
        anchor = a
        dir = d
        chunkRecordCount = 0
        lastRecordOffsetUs = nil
        sessionStartPending = true
        lastSyncMono = a.monoNs
        outOfSpace = false
        manifestDirty = false
        stats = Stats(captureId: id)
        log(.info, "capture", "live capture \(id) started for device \(meta.deviceId)")
        return id
    }

    /// Updates header metadata (codec, DIS strings, offline_storage) as the connection sequence learns it.
    public func updateMeta(_ meta: CaptureDeviceMeta) {
        guard var m = manifest else { return }
        let before = m
        m.deviceName = meta.deviceName ?? m.deviceName
        m.modelNumber = meta.modelNumber ?? m.modelNumber
        m.firmwareRevision = meta.firmwareRevision ?? m.firmwareRevision
        m.hardwareRevision = meta.hardwareRevision ?? m.hardwareRevision
        if let c = meta.codec { m.codecId = c.rawValue }
        if meta.offlineStorage != nil { m.offlineStorage = meta.offlineStorage }
        guard m != before else { return }
        manifest = m  // later chunk headers use it even if the commit below fails
        manifestDirty = true
        commitManifest()
    }

    /// The next record gets SESSION_START (the subscription was re-established).
    public func markResubscribed() { sessionStartPending = true }

    /// Journals one audio notification. Returns false if it could not be written.
    @discardableResult
    public func append(_ notification: Data) -> Bool {
        guard let anchor, manifest != nil else { return false }
        let mono = env.clock.monotonicNanoseconds()
        let nowUs = anchor.offsetUs(mono)
        rotateIfNeeded(nowUs: nowUs)
        guard let m = manifest, ensureJournal(), let journal else { return false }
        let t = UInt32(clamping: max(0, nowUs - m.openChunkStartOffsetUs))
        let record = BLERecord(tOffsetUs: t, flags: sessionStartPending ? BLERecord.sessionStartFlag : 0, bytes: notification)
        do {
            try journal.append(record.encoded())
        } catch {
            noteWriteError(error)
            return false
        }
        sessionStartPending = false
        chunkRecordCount += 1
        lastRecordOffsetUs = nowUs
        stats.chunkRecords = chunkRecordCount
        stats.totalRecords += 1
        stats.totalBytes += Int64(notification.count)
        if mono &- lastSyncMono >= 1_000_000_000 { syncJournal(mono: mono) }
        return true
    }

    /// 1 Hz: fsync cadence, time-based rotation, retry of a failed manifest commit.
    public func tick() {
        guard let anchor, manifest != nil else { return }
        let mono = env.clock.monotonicNanoseconds()
        rotateIfNeeded(nowUs: anchor.offsetUs(mono))
        if manifestDirty { commitManifest() }
        if journal?.dirty == true, mono &- lastSyncMono >= 900_000_000 { syncJournal(mono: mono) }
    }

    /// Flush to disk now (app lifecycle).
    public func syncNow() {
        syncJournal(mono: env.clock.monotonicNanoseconds())
    }

    /// Forced rotation: double tap, lifecycle, debug.
    public func rotateNow(reason: RotationReason) {
        guard let anchor, let m = manifest else { return }
        let nowUs = anchor.offsetUs(env.clock.monotonicNanoseconds())
        for end in policy.closingEnds(chunkStartUs: m.openChunkStartOffsetUs, nowUs: nowUs) {
            guard finalizeChunk(endUs: end, reason: reason) else { break }
        }
    }

    /// Coverage watermark for heartbeats. It only ever references chunks that are already rotated
    /// into the outbox (never the open journal): connected + subscribed from the capture start
    /// through the end of the last rotated chunk. Nil until the first rotation.
    public func coverage() -> CoverageWatermark? {
        guard let m = manifest, m.openChunkSequence > 0 else { return nil }
        return CoverageWatermark(
            captureId: m.captureId, throughOffsetUs: m.openChunkStartOffsetUs, throughChunkSequence: m.openChunkSequence - 1)
    }

    /// Final rotation + seal. `end_offset_us` equals the last chunk's end (or the capture's end if empty).
    @discardableResult
    public func finish(reason: SealReason) -> SealBody? {
        guard let anchor, manifest != nil else { return nil }
        let endUs = anchor.offsetUs(env.clock.monotonicNanoseconds())
        if let m = manifest, m.codecId == nil, codecFallback(m.deviceId) == nil, let dir {
            // The connection ended before the codec was read: the audio cannot be interpreted.
            log(.warning, "capture", "codec never read for \(m.captureId); discarding \(chunkRecordCount) unreadable records")
            journal?.close()
            journal = nil
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(CaptureManifest.journalName(m.openChunkSequence)))
            chunkRecordCount = 0
        }
        if let m = manifest, chunkRecordCount > 0 || endUs > m.openChunkStartOffsetUs, m.codecId ?? codecFallback(m.deviceId) != nil {
            let ends = policy.closingEnds(chunkStartUs: m.openChunkStartOffsetUs, nowUs: endUs)
            for end in ends where chunkRecordCount > 0 || end > (manifest?.openChunkStartOffsetUs ?? 0) {
                if !finalizeChunk(endUs: end, reason: .disconnect) {
                    log(.error, "capture", "final chunk of \(m.captureId) could not be written; journal kept for recovery")
                    journal?.close()
                    reset()
                    return nil
                }
            }
        }
        guard let m = manifest else { return nil }
        let sealEnd = m.openChunkSequence > 0 ? m.openChunkStartOffsetUs : endUs
        let seal = SealBody(
            lastChunkSequence: m.openChunkSequence - 1, reason: reason,
            endedAt: ISO8601UTC.format(m.wallDate(offsetUs: sealEnd)), endOffsetUs: sealEnd,
            deviceId: m.deviceId, source: .liveBLE)
        do {
            let item = try env.outbox.write(try ContractJSON.encode(seal), kind: .seal(captureId: m.captureId))
            journal?.close()
            if let dir { try? FileManager.default.removeItem(at: dir) }
            log(.info, "capture", "live capture \(m.captureId) sealed (\(reason.rawValue), last chunk \(seal.lastChunkSequence))")
            reset()
            onSealWritten?(item)
            return seal
        } catch {
            noteWriteError(error)
            journal?.close()
            reset()
            return nil
        }
    }

    /// Discards the capture without uploading anything (unsupported codec: the audio is undecodable).
    public func abort() {
        guard let m = manifest else { return }
        journal?.close()
        if let dir { try? FileManager.default.removeItem(at: dir) }
        log(.warning, "capture", "live capture \(m.captureId) discarded")
        reset()
    }

    // MARK: Private

    private func reset() {
        manifest = nil
        anchor = nil
        journal = nil
        dir = nil
        chunkRecordCount = 0
        lastRecordOffsetUs = nil
        manifestDirty = false
        stats.captureId = nil
    }

    private func ensureJournal() -> Bool {
        if journal != nil { return true }
        guard let m = manifest, let dir else { return false }
        do {
            journal = try AppendFile(url: dir.appendingPathComponent(CaptureManifest.journalName(m.openChunkSequence)))
            return true
        } catch {
            noteWriteError(error)
            return false
        }
    }

    private func commitManifest() {
        guard let m = manifest, let dir else { return }
        do {
            try env.saveManifest(m, in: dir)
            manifestDirty = false
        } catch {
            if !manifestDirty || lastError == nil { log(.error, "capture", "manifest commit failed (will retry): \(error)") }
            manifestDirty = true
            noteWriteError(error)
        }
    }

    private func rotateIfNeeded(nowUs: Int64) {
        guard let m = manifest else { return }
        let age = nowUs - m.openChunkStartOffsetUs
        let since = lastRecordOffsetUs.map { nowUs - $0 }
        guard let reason = policy.automaticReason(chunkAgeUs: age, recordCount: chunkRecordCount, sinceLastRecordUs: since) else {
            return
        }
        for end in policy.closingEnds(chunkStartUs: m.openChunkStartOffsetUs, nowUs: nowUs) {
            guard finalizeChunk(endUs: end, reason: reason) else { break }
        }
    }

    private func syncJournal(mono: UInt64) {
        guard let journal else { return }
        do {
            try env.sync(journal, full: false)
            lastSyncMono = mono
        } catch {
            noteWriteError(error)
        }
    }

    private func noteWriteError(_ error: Error) {
        lastError = "\(error)"
        if let e = error as? FileIOError, e.isOutOfSpace { outOfSpace = true }
        log(.error, "capture", "write failed: \(error)")
    }

    /// Closes the open chunk at `endUs` (see the type comment for the ordering).
    @discardableResult
    private func finalizeChunk(endUs: Int64, reason: RotationReason) -> Bool {
        guard var m = manifest, let dir else { return false }
        guard let codec = m.codecId ?? codecFallback(m.deviceId) else {
            if reason != .disconnect { log(.warning, "capture", "rotation deferred: codec not known yet") }
            return false
        }
        let seq = m.openChunkSequence
        let start = m.openChunkStartOffsetUs
        let journalURL = dir.appendingPathComponent(CaptureManifest.journalName(seq))
        let item: OutboxItem
        let end: Int64
        let count: Int
        do {
            if let journal { try env.sync(journal, full: true) }
            let raw = FileIO.exists(journalURL) ? try Data(contentsOf: journalURL) : Data()
            let scan = BLERecord.scan(raw)
            let payload = Data(raw.prefix(scan.validLength))
            // Every record's t_offset_us must lie within [0, end - start].
            let maxT = Int64(scan.records.map(\.tOffsetUs).max() ?? 0)
            end = max(endUs, start + maxT)
            let header = m.header(
                chunkSequence: seq, codecId: codec, startUs: start, endUs: end,
                recordCount: scan.records.count, payloadBytes: payload.count, ringInfo: nil)
            let body = try Envelope.build(header: header, payload: payload)
            item = try env.outbox.write(body, kind: .chunk(captureId: m.captureId, sequence: seq))
            count = scan.records.count
        } catch {
            noteWriteError(error)
            return false
        }
        // Published: this segment is frozen from here on.
        journal?.close()
        journal = nil
        m.openChunkSequence = seq + 1
        m.openChunkStartOffsetUs = end
        manifest = m
        chunkRecordCount = 0
        lastRecordOffsetUs = nil
        stats.chunkSequence = seq + 1
        stats.chunkRecords = 0
        stats.chunksFinalized += 1
        manifestDirty = true
        commitManifest()
        _ = ensureJournal()
        try? FileManager.default.removeItem(at: journalURL)
        log(.info, "capture", "chunk \(seq) of \(m.captureId) closed (\(reason.rawValue), \(count) records, \(item.size) B)")
        onChunkFinalized?(item)
        return true
    }
}

// MARK: - Ring capture

/// One ring capture = one offline-storage sync session. Records are journaled with their device
/// sequence and fsync'd ≥ 1×/s; chunks hold consecutive records and rotate on a record count, a
/// sequence discontinuity, or ~60 s of monotonic time (spans stay far below the u32-µs limit).
public final class RingCaptureWriter {
    public struct Context: Sendable {
        public var meta: CaptureDeviceMeta
        public var codecId: Int
        public var info: RingProtocol.Info
        public var generation: Int
        public var rtcValid: Bool
        public var coversUntil: Date

        public init(meta: CaptureDeviceMeta, codecId: Int, info: RingProtocol.Info, generation: Int, rtcValid: Bool, coversUntil: Date) {
            self.meta = meta
            self.codecId = codecId
            self.info = info
            self.generation = generation
            self.rtcValid = rtcValid
            self.coversUntil = coversUntil
        }
    }

    public let env: CaptureEnvironment
    public var recordsPerChunk: Int
    public var maxChunkDurationUs: Int64 = 60_000_000
    /// Orders ring captures per device so `sync_complete` seals wait for earlier captures.
    public var ledger: RingCaptureLedger?
    public var onChunkFinalized: ((OutboxItem) -> Void)?
    public var onSealWritten: ((OutboxItem) -> Void)?

    private var manifest: CaptureManifest?
    private var anchor: CaptureAnchor?
    private var journal: AppendFile?
    private var dir: URL?
    private var chunkCount = 0
    private var lastSeq: UInt64?
    private var lastSyncMono: UInt64 = 0
    private var manifestDirty = false
    public private(set) var recordsWritten = 0
    public private(set) var chunksFinalized = 0
    /// Highest sequence known to be on disk (fsync'd).
    public private(set) var lastDurableSeq: UInt64?

    public init(env: CaptureEnvironment, recordsPerChunk: Int = 600) {
        self.env = env
        self.recordsPerChunk = recordsPerChunk
    }

    public var isActive: Bool { manifest != nil }
    public var captureId: String? { manifest?.captureId }

    @discardableResult
    public func begin(_ ctx: Context) throws -> String {
        let id = env.newId()
        try ledger?.register(captureId: id, deviceId: ctx.meta.deviceId, generation: ctx.generation)
        let a = env.makeAnchor()
        let d = env.dirs.journalRing.appendingPathComponent(id, isDirectory: true)
        try FileIO.ensureDirectory(d)
        let m = CaptureManifest(
            captureId: id, source: .deviceRing, deviceId: ctx.meta.deviceId, deviceName: ctx.meta.deviceName,
            modelNumber: ctx.meta.modelNumber, firmwareRevision: ctx.meta.firmwareRevision,
            hardwareRevision: ctx.meta.hardwareRevision, codecId: ctx.codecId,
            captureStartedAt: ISO8601UTC.format(a.wall), anchorWallMs: Int64(a.wall.timeIntervalSince1970 * 1000),
            timezone: env.timezone, offlineStorage: nil, appVersion: env.appVersion, openChunkSequence: 0,
            openChunkStartOffsetUs: 0,
            ring: .init(
                infoReadSeq: ctx.info.readSeq, infoWriteSeq: ctx.info.writeSeq, dropped: ctx.info.dropped,
                generation: ctx.generation, rtcValid: ctx.rtcValid, coversUntil: ISO8601UTC.format(ctx.coversUntil)))
        do {
            try env.saveManifest(m, in: d)
            journal = try AppendFile(url: d.appendingPathComponent(CaptureManifest.journalName(0)))
        } catch {
            try? FileManager.default.removeItem(at: d)
            ledger?.unregister(captureId: id)
            throw error
        }
        manifest = m
        anchor = a
        dir = d
        chunkCount = 0
        lastSeq = nil
        lastSyncMono = a.monoNs
        manifestDirty = false
        recordsWritten = 0
        chunksFinalized = 0
        lastDurableSeq = nil
        log(.info, "ring", "ring capture \(id) started (read \(ctx.info.readSeq) write \(ctx.info.writeSeq) gen \(ctx.generation))")
        return id
    }

    public func append(seq: UInt64, record: Data) throws {
        guard let m = manifest, let anchor else { return }
        let nowUs = anchor.offsetUs(env.clock.monotonicNanoseconds())
        if chunkCount > 0, let last = lastSeq {
            let reason: RotationReason?
            if seq != last &+ 1 { reason = .discontinuity }
            else if chunkCount >= recordsPerChunk { reason = .recordLimit }
            else if nowUs - m.openChunkStartOffsetUs >= maxChunkDurationUs { reason = .maxAge }
            else { reason = nil }
            if let reason { try finalizeChunk(endUs: nowUs, reason: reason) }
        }
        try ensureJournal()
        guard let journal else { return }
        try journal.append(RingJournal.encode(seq: seq, record: record))
        chunkCount += 1
        lastSeq = seq
        recordsWritten += 1
    }

    /// fsync if at least one second passed (or `force`). Returns the durable sequence after a sync.
    /// Throws on any persistence failure (the caller must stop the transfer).
    @discardableResult
    public func syncIfDue(force: Bool = false) throws -> UInt64? {
        if manifestDirty { commitManifest() }
        guard let journal else { return force ? lastDurableSeq : nil }
        let mono = env.clock.monotonicNanoseconds()
        guard force || mono &- lastSyncMono >= 1_000_000_000 else { return nil }
        try env.sync(journal, full: false)
        lastSyncMono = mono
        if let lastSeq { lastDurableSeq = lastSeq }
        return lastDurableSeq
    }

    /// Final chunk + seal. `doneNextSeq` is the DONE notification's `next_seq` (sync_complete).
    @discardableResult
    public func finish(reason: SealReason, doneNextSeq: UInt64?) throws -> SealBody? {
        guard let anchor, manifest != nil else { return nil }
        let endUs = anchor.offsetUs(env.clock.monotonicNanoseconds())
        if chunkCount > 0 { try finalizeChunk(endUs: endUs, reason: .disconnect) }
        guard let m = manifest, let ring = m.ring else { return nil }
        let sealEnd = m.openChunkSequence > 0 ? m.openChunkStartOffsetUs : endUs
        let evidence = RingSealEvidence(
            generation: ring.generation, infoReadSeq: ring.infoReadSeq, infoWriteSeq: ring.infoWriteSeq,
            doneNextSeq: doneNextSeq, dropped: ring.dropped, rtcValid: ring.rtcValid, coversUntil: ring.coversUntil)
        let seal = SealBody(
            lastChunkSequence: m.openChunkSequence - 1, reason: reason,
            endedAt: ISO8601UTC.format(m.wallDate(offsetUs: sealEnd)), endOffsetUs: sealEnd, deviceId: m.deviceId,
            source: .deviceRing, ring: evidence)
        let item = try env.outbox.write(try ContractJSON.encode(seal), kind: .seal(captureId: m.captureId))
        journal?.close()
        if let dir { try? FileManager.default.removeItem(at: dir) }
        log(.info, "ring", "ring capture \(m.captureId) sealed (\(reason.rawValue), \(recordsWritten) records, last chunk \(seal.lastChunkSequence))")
        manifest = nil
        self.anchor = nil
        journal = nil
        self.dir = nil
        onSealWritten?(item)
        return seal
    }

    private func ensureJournal() throws {
        guard journal == nil, let m = manifest, let dir else { return }
        journal = try AppendFile(url: dir.appendingPathComponent(CaptureManifest.journalName(m.openChunkSequence)))
    }

    private func commitManifest() {
        guard let m = manifest, let dir else { return }
        do {
            try env.saveManifest(m, in: dir)
            manifestDirty = false
        } catch {
            manifestDirty = true
            log(.error, "ring", "manifest commit failed (will retry): \(error)")
        }
    }

    private func finalizeChunk(endUs: Int64, reason: RotationReason) throws {
        guard var m = manifest, let dir, let ring = m.ring, let codec = m.codecId else { return }
        let seq = m.openChunkSequence
        let journalURL = dir.appendingPathComponent(CaptureManifest.journalName(seq))
        if let journal { try env.sync(journal, full: true) }
        if let lastSeq { lastDurableSeq = lastSeq }
        let raw = FileIO.exists(journalURL) ? try Data(contentsOf: journalURL) : Data()
        let entries = RingJournal.scan(raw).entries
        guard let first = entries.first?.seq else { return }
        var payload = Data(capacity: entries.count * RingProtocol.recordSize)
        for e in entries { payload.append(e.record) }
        let end = max(endUs, m.openChunkStartOffsetUs)
        let header = m.header(
            chunkSequence: seq, codecId: codec, startUs: m.openChunkStartOffsetUs, endUs: end,
            recordCount: entries.count, payloadBytes: payload.count,
            ringInfo: RingChunkInfo(firstSequence: first, readSeq: ring.infoReadSeq, writeSeq: ring.infoWriteSeq, dropped: ring.dropped))
        let body = try Envelope.build(header: header, payload: payload)
        let item = try env.outbox.write(body, kind: .chunk(captureId: m.captureId, sequence: seq))
        // Published: freeze the segment, move on, then commit the manifest (retried if it fails).
        journal?.close()
        journal = nil
        m.openChunkSequence = seq + 1
        m.openChunkStartOffsetUs = end
        manifest = m
        chunkCount = 0
        chunksFinalized += 1
        manifestDirty = true
        commitManifest()
        try? FileManager.default.removeItem(at: journalURL)
        log(.info, "ring", "ring chunk \(seq) of \(m.captureId) closed (\(reason.rawValue), \(entries.count) records from seq \(first))")
        onChunkFinalized?(item)
    }
}

// MARK: - Recovery

/// Launch-time recovery of captures left unsealed by a crash / kill: rotations that were published
/// but not committed to the manifest are re-derived from the outbox, torn tails are cut at the
/// first bad CRC, the open chunk becomes an envelope, and the capture is sealed `app_recovered`
/// with `end_offset_us` = last journaled record (= the last chunk's end).
///
/// A directory whose manifest is missing or corrupt is **quarantined** (moved to
/// `journal/quarantine/`) unless its journals are demonstrably empty; an unreadable manifest
/// (e.g. protected data unavailable) leaves the directory untouched for the next launch.
public enum CaptureRecovery {
    public struct Report: Sendable, Equatable {
        public var liveRecovered: [String] = []
        public var ringRecovered: [String] = []
        public var chunksWritten = 0
        /// Highest durable ring sequence per (device, generation), to advance the dedupe cursor.
        public var ringDurable: [RingDurableMark] = []
        public var quarantined: [String] = []
        public var skipped: [String] = []
        public init() {}
    }

    public struct RingDurableMark: Sendable, Equatable {
        public var deviceId: String
        public var generation: Int
        public var seq: UInt64
    }

    enum ManifestLoad {
        case ok(CaptureManifest)
        case missing
        case unreadable(Error)
        case corrupt(Error)
    }

    public static func run(env: CaptureEnvironment, codecFallback: (String) -> Int? = { _ in nil }) -> Report {
        var report = Report()
        for dir in FileIO.contents(of: env.dirs.journalLive) where dir.hasDirectoryPath {
            if recover(dir: dir, env: env, codecFallback: codecFallback, report: &report) {
                report.liveRecovered.append(dir.lastPathComponent)
            }
        }
        for dir in FileIO.contents(of: env.dirs.journalRing) where dir.hasDirectoryPath {
            if recover(dir: dir, env: env, codecFallback: codecFallback, report: &report) {
                report.ringRecovered.append(dir.lastPathComponent)
            }
        }
        return report
    }

    static func loadManifest(_ url: URL) -> ManifestLoad {
        guard FileIO.exists(url) else { return .missing }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .unreadable(error) }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        do { return .ok(try d.decode(CaptureManifest.self, from: data)) } catch { return .corrupt(error) }
    }

    /// True if no journal in the directory holds a single byte.
    static func isDemonstrablyEmpty(_ dir: URL) -> Bool {
        FileIO.contents(of: dir).filter { $0.pathExtension == "journal" }.allSatisfy { FileIO.fileSize($0) == 0 }
    }

    static func quarantine(_ dir: URL, env: CaptureEnvironment, why: String, report: inout Report) {
        var dest = env.dirs.journalQuarantine.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
        var n = 1
        while FileIO.exists(dest) {
            n += 1
            dest = env.dirs.journalQuarantine.appendingPathComponent("\(dir.lastPathComponent)-\(n)", isDirectory: true)
        }
        do {
            try FileIO.ensureDirectory(env.dirs.journalQuarantine)
            try FileManager.default.moveItem(at: dir, to: dest)
            report.quarantined.append(dir.lastPathComponent)
            log(.error, "recovery", "kept \(dir.lastPathComponent) in journal/quarantine: \(why)")
        } catch {
            report.skipped.append(dir.lastPathComponent)
            log(.error, "recovery", "could not quarantine \(dir.lastPathComponent) (\(error)); left in place")
        }
    }

    private static func recover(dir: URL, env: CaptureEnvironment, codecFallback: (String) -> Int?, report: inout Report) -> Bool {
        var m: CaptureManifest
        switch loadManifest(dir.appendingPathComponent(CaptureManifest.fileName)) {
        case .ok(let loaded):
            m = loaded
        case .missing:
            if isDemonstrablyEmpty(dir) {
                try? FileManager.default.removeItem(at: dir)
            } else {
                quarantine(dir, env: env, why: "journal without a manifest", report: &report)
            }
            return false
        case .corrupt(let error):
            if isDemonstrablyEmpty(dir) {
                try? FileManager.default.removeItem(at: dir)
            } else {
                quarantine(dir, env: env, why: "corrupt manifest (\(error))", report: &report)
            }
            return false
        case .unreadable(let error):
            report.skipped.append(dir.lastPathComponent)
            log(.warning, "recovery", "manifest of \(dir.lastPathComponent) unreadable (\(error)); will retry next launch")
            return false
        }
        let outbox = env.outbox
        if outbox.contains(.seal(captureId: m.captureId)) {
            try? FileManager.default.removeItem(at: dir)
            return false
        }
        // Rotations published but not committed to the manifest.
        while outbox.contains(.chunk(captureId: m.captureId, sequence: m.openChunkSequence)) {
            let kind = OutboxKind.chunk(captureId: m.captureId, sequence: m.openChunkSequence)
            if let end = existingChunkEnd(outbox: outbox, kind: kind) {
                m.openChunkStartOffsetUs = max(m.openChunkStartOffsetUs, end)
            }
            m.openChunkSequence += 1
        }
        var endUs = m.openChunkStartOffsetUs
        let seq = m.openChunkSequence
        let journalURL = dir.appendingPathComponent(CaptureManifest.journalName(seq))
        if let raw = try? Data(contentsOf: journalURL), !raw.isEmpty {
            do {
                if let written = try finalizeRecovered(manifest: m, raw: raw, env: env, codecFallback: codecFallback, report: &report) {
                    endUs = written
                    m.openChunkSequence = seq + 1
                    report.chunksWritten += 1
                }
            } catch {
                log(.error, "recovery", "could not rebuild chunk \(seq) of \(m.captureId): \(error)")
                return false
            }
        }
        let seal = SealBody(
            lastChunkSequence: m.openChunkSequence - 1, reason: .appRecovered,
            endedAt: ISO8601UTC.format(m.wallDate(offsetUs: endUs)), endOffsetUs: endUs, deviceId: m.deviceId,
            source: m.source)
        do {
            try outbox.write(try ContractJSON.encode(seal), kind: .seal(captureId: m.captureId))
            try? FileManager.default.removeItem(at: dir)
            log(.info, "recovery", "\(m.source.rawValue) capture \(m.captureId) recovered and sealed app_recovered (last chunk \(seal.lastChunkSequence))")
            return true
        } catch {
            log(.error, "recovery", "seal write failed for \(m.captureId): \(error)")
            return false
        }
    }

    /// Returns the chunk end offset if a chunk was written.
    private static func finalizeRecovered(manifest m: CaptureManifest, raw: Data, env: CaptureEnvironment, codecFallback: (String) -> Int?, report: inout Report) throws -> Int64? {
        guard let codec = m.codecId ?? codecFallback(m.deviceId) else {
            log(.error, "recovery", "codec unknown for \(m.captureId); journal discarded")
            return nil
        }
        let seq = m.openChunkSequence
        switch m.source {
        case .deviceRing:
            let entries = RingJournal.scan(raw).entries
            guard let first = entries.first?.seq, let ring = m.ring else { return nil }
            var payload = Data()
            for e in entries { payload.append(e.record) }
            let endUs = m.openChunkStartOffsetUs
            let header = m.header(
                chunkSequence: seq, codecId: codec, startUs: m.openChunkStartOffsetUs, endUs: endUs,
                recordCount: entries.count, payloadBytes: payload.count,
                ringInfo: RingChunkInfo(firstSequence: first, readSeq: ring.infoReadSeq, writeSeq: ring.infoWriteSeq, dropped: ring.dropped))
            try env.outbox.write(try Envelope.build(header: header, payload: payload), kind: .chunk(captureId: m.captureId, sequence: seq))
            if let last = entries.last?.seq {
                report.ringDurable.append(RingDurableMark(deviceId: m.deviceId, generation: ring.generation, seq: last))
            }
            return endUs
        default:
            let scan = BLERecord.scan(raw)
            guard !scan.records.isEmpty else { return nil }
            let payload = Data(raw.prefix(scan.validLength))
            let maxT = Int64(scan.records.map(\.tOffsetUs).max() ?? 0)
            let endUs = m.openChunkStartOffsetUs + maxT
            let header = m.header(
                chunkSequence: seq, codecId: codec, startUs: m.openChunkStartOffsetUs, endUs: endUs,
                recordCount: scan.records.count, payloadBytes: payload.count, ringInfo: nil)
            try env.outbox.write(try Envelope.build(header: header, payload: payload), kind: .chunk(captureId: m.captureId, sequence: seq))
            if scan.validLength != raw.count {
                log(.warning, "recovery", "cut torn tail of \(raw.count - scan.validLength) B from \(m.captureId) chunk \(seq)")
            }
            return endUs
        }
    }

    private static func existingChunkEnd(outbox: Outbox, kind: OutboxKind) -> Int64? {
        guard let url = outbox.locate(kind), let data = try? Data(contentsOf: url),
              let parsed = try? Envelope.parse(data) else { return nil }
        return parsed.header.chunkEndOffsetUs
    }
}
