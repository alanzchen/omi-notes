import Foundation

// Capture format v1 (docs/capture-format-v1.md). Field names are the contract's snake_case keys.

public enum CaptureSource: String, Codable, Sendable {
    case liveBLE = "live_ble"
    case deviceRing = "device_ring"
    case wavReplay = "wav_replay"
    /// An Apple Watch recording relayed by the phone (16 kHz PCM, capture-format-v1.md "Apple Watch").
    case watchMic = "watch_mic"
}

public enum PayloadFormat: String, Codable, Sendable {
    case bleNotificationsV1 = "ble_notifications_v1"
    case ringRecordsV1 = "ring_records_v1"
    case pcm16leV1 = "pcm16le_v1"
}

public enum ClockQuality: String, Codable, Sendable {
    case phoneAnchored = "phone_anchored"
    case deviceSeconds = "device_seconds"
    case unknown
}

/// `ring` object of a `ring_records_v1` chunk header.
public struct RingChunkInfo: Codable, Equatable, Sendable {
    public var firstSequence: UInt64
    public var recordSize: Int
    public var readSeq: UInt64
    public var writeSeq: UInt64
    public var dropped: UInt64

    public init(firstSequence: UInt64, recordSize: Int = RingProtocol.recordSize, readSeq: UInt64, writeSeq: UInt64, dropped: UInt64) {
        self.firstSequence = firstSequence
        self.recordSize = recordSize
        self.readSeq = readSeq
        self.writeSeq = writeSeq
        self.dropped = dropped
    }

    enum CodingKeys: String, CodingKey {
        case firstSequence = "first_sequence"
        case recordSize = "record_size"
        case readSeq = "read_seq"
        case writeSeq = "write_seq"
        case dropped
    }
}

/// Envelope header JSON.
public struct EnvelopeHeader: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var captureId: String
    public var chunkSequence: Int
    public var deviceId: String
    public var deviceName: String?
    public var modelNumber: String?
    public var firmwareRevision: String?
    public var hardwareRevision: String?
    public var source: CaptureSource
    public var payloadFormat: PayloadFormat
    public var codecId: Int
    public var sampleRate: Int = 16_000
    public var channels: Int = 1
    public var captureStartedAt: String
    public var chunkStartOffsetUs: Int64
    public var chunkEndOffsetUs: Int64
    public var clockQuality: ClockQuality
    public var timezone: String?
    public var recordCount: Int
    public var payloadBytes: Int
    public var offlineStorage: Bool?
    public var ring: RingChunkInfo?
    public var appVersion: String?

    public init(
        captureId: String, chunkSequence: Int, deviceId: String, deviceName: String?, modelNumber: String?,
        firmwareRevision: String?, hardwareRevision: String?, source: CaptureSource, payloadFormat: PayloadFormat,
        codecId: Int, captureStartedAt: String, chunkStartOffsetUs: Int64, chunkEndOffsetUs: Int64,
        clockQuality: ClockQuality, timezone: String?, recordCount: Int, payloadBytes: Int,
        offlineStorage: Bool?, ring: RingChunkInfo?, appVersion: String?
    ) {
        self.captureId = captureId
        self.chunkSequence = chunkSequence
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.modelNumber = modelNumber
        self.firmwareRevision = firmwareRevision
        self.hardwareRevision = hardwareRevision
        self.source = source
        self.payloadFormat = payloadFormat
        self.codecId = codecId
        self.captureStartedAt = captureStartedAt
        self.chunkStartOffsetUs = chunkStartOffsetUs
        self.chunkEndOffsetUs = chunkEndOffsetUs
        self.clockQuality = clockQuality
        self.timezone = timezone
        self.recordCount = recordCount
        self.payloadBytes = payloadBytes
        self.offlineStorage = offlineStorage
        self.ring = ring
        self.appVersion = appVersion
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case captureId = "capture_id"
        case chunkSequence = "chunk_sequence"
        case deviceId = "device_id"
        case deviceName = "device_name"
        case modelNumber = "model_number"
        case firmwareRevision = "firmware_revision"
        case hardwareRevision = "hardware_revision"
        case source
        case payloadFormat = "payload_format"
        case codecId = "codec_id"
        case sampleRate = "sample_rate"
        case channels
        case captureStartedAt = "capture_started_at"
        case chunkStartOffsetUs = "chunk_start_offset_us"
        case chunkEndOffsetUs = "chunk_end_offset_us"
        case clockQuality = "clock_quality"
        case timezone
        case recordCount = "record_count"
        case payloadBytes = "payload_bytes"
        case offlineStorage = "offline_storage"
        case ring
        case appVersion = "app_version"
    }

    /// Nullable fields are written as explicit `null` (contract types are `string | null`);
    /// `ring` is omitted unless present.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(captureId, forKey: .captureId)
        try c.encode(chunkSequence, forKey: .chunkSequence)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(modelNumber, forKey: .modelNumber)
        try c.encode(firmwareRevision, forKey: .firmwareRevision)
        try c.encode(hardwareRevision, forKey: .hardwareRevision)
        try c.encode(source, forKey: .source)
        try c.encode(payloadFormat, forKey: .payloadFormat)
        try c.encode(codecId, forKey: .codecId)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(channels, forKey: .channels)
        try c.encode(captureStartedAt, forKey: .captureStartedAt)
        try c.encode(chunkStartOffsetUs, forKey: .chunkStartOffsetUs)
        try c.encode(chunkEndOffsetUs, forKey: .chunkEndOffsetUs)
        try c.encode(clockQuality, forKey: .clockQuality)
        try c.encode(timezone, forKey: .timezone)
        try c.encode(recordCount, forKey: .recordCount)
        try c.encode(payloadBytes, forKey: .payloadBytes)
        try c.encode(offlineStorage, forKey: .offlineStorage)
        try c.encodeIfPresent(ring, forKey: .ring)
        try c.encode(appVersion, forKey: .appVersion)
    }
}

/// One `ble_notifications_v1` record:
/// `[t_offset_us u32 LE][length u16 LE][flags u8][bytes][crc32 u32 LE over the preceding 7+length]`.
public struct BLERecord: Equatable, Sendable {
    public static let sessionStartFlag: UInt8 = 0x01
    public static let overhead = 11

    public var tOffsetUs: UInt32
    public var flags: UInt8
    public var bytes: Data

    public init(tOffsetUs: UInt32, flags: UInt8, bytes: Data) {
        self.tOffsetUs = tOffsetUs
        self.flags = flags
        self.bytes = bytes
    }

    public var isSessionStart: Bool { flags & Self.sessionStartFlag != 0 }

    public func encoded() -> Data {
        precondition(bytes.count <= Int(UInt16.max), "notification too long")
        var out = Data(capacity: Self.overhead + bytes.count)
        out.append(le(tOffsetUs))
        out.append(le(UInt16(bytes.count)))
        out.append(flags)
        out.append(bytes)
        out.append(le(CRC32.checksum(out)))
        return out
    }

    public struct ScanResult: Sendable {
        public var records: [BLERecord]
        /// Length of the valid prefix; bytes past it are a torn tail.
        public var validLength: Int
    }

    /// Reads records until the data ends or the first truncated/CRC-failing record.
    public static func scan(_ data: Data) -> ScanResult {
        let b = [UInt8](data)
        var off = 0
        var records: [BLERecord] = []
        while off + 7 <= b.count {
            let t = UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
            let len = Int(UInt16(b[off + 4]) | UInt16(b[off + 5]) << 8)
            let flags = b[off + 6]
            let end = off + 7 + len
            guard end + 4 <= b.count else { break }
            let stored = UInt32(b[end]) | UInt32(b[end + 1]) << 8 | UInt32(b[end + 2]) << 16 | UInt32(b[end + 3]) << 24
            let crc = b.withUnsafeBytes { CRC32.update(0, UnsafeRawBufferPointer(rebasing: $0[off..<end])) }
            guard crc == stored else { break }
            records.append(BLERecord(tOffsetUs: t, flags: flags, bytes: Data(b[(off + 7)..<end])))
            off = end + 4
        }
        return ScanResult(records: records, validLength: off)
    }
}

public enum EnvelopeError: Error, Equatable, CustomStringConvertible {
    case badMagic
    case badHeaderLength(Int)
    case headerNotJSON(String)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case recordCountMismatch(expected: Int, actual: Int)
    case corruptRecords

    public var description: String {
        switch self {
        case .badMagic: return "bad magic"
        case .badHeaderLength(let n): return "bad header length \(n)"
        case .headerNotJSON(let s): return "header is not valid JSON: \(s)"
        case .payloadLengthMismatch(let e, let a): return "payload is \(a) bytes, header says \(e)"
        case .recordCountMismatch(let e, let a): return "\(a) records, header says \(e)"
        case .corruptRecords: return "record CRC/framing error"
        }
    }
}

/// `OMINOTE1` envelope: `[magic 8]["header_len" u32 LE][header JSON][payload]`.
public enum Envelope {
    public static let magic = Data("OMINOTE1".utf8)
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 8 * 1024 * 1024

    public static func headerJSON(_ header: EnvelopeHeader) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(header)
    }

    /// Serializes an envelope. `header.payloadBytes` must already equal `payload.count`.
    public static func build(header: EnvelopeHeader, payload: Data) throws -> Data {
        precondition(header.payloadBytes == payload.count, "payload_bytes mismatch")
        let json = try headerJSON(header)
        guard json.count <= maxHeaderBytes else { throw EnvelopeError.badHeaderLength(json.count) }
        var out = Data(capacity: 12 + json.count + payload.count)
        out.append(magic)
        out.append(le(UInt32(json.count)))
        out.append(json)
        out.append(payload)
        return out
    }

    /// Parses and validates framing (and record CRCs for live payloads).
    public static func parse(_ body: Data) throws -> (header: EnvelopeHeader, payload: Data) {
        let b = [UInt8](body)
        guard b.count >= 12, Data(b[0..<8]) == magic else { throw EnvelopeError.badMagic }
        let hlen = Int(UInt32(b[8]) | UInt32(b[9]) << 8 | UInt32(b[10]) << 16 | UInt32(b[11]) << 24)
        guard hlen > 0, hlen <= maxHeaderBytes, 12 + hlen <= b.count else { throw EnvelopeError.badHeaderLength(hlen) }
        let header: EnvelopeHeader
        do {
            header = try JSONDecoder().decode(EnvelopeHeader.self, from: Data(b[12..<(12 + hlen)]))
        } catch {
            throw EnvelopeError.headerNotJSON(String(describing: error))
        }
        let payload = Data(b[(12 + hlen)...])
        guard payload.count == header.payloadBytes else {
            throw EnvelopeError.payloadLengthMismatch(expected: header.payloadBytes, actual: payload.count)
        }
        switch header.payloadFormat {
        case .bleNotificationsV1:
            let scan = BLERecord.scan(payload)
            guard scan.validLength == payload.count else { throw EnvelopeError.corruptRecords }
            guard scan.records.count == header.recordCount else {
                throw EnvelopeError.recordCountMismatch(expected: header.recordCount, actual: scan.records.count)
            }
        case .ringRecordsV1:
            let size = header.ring?.recordSize ?? RingProtocol.recordSize
            guard payload.count == header.recordCount * size else {
                throw EnvelopeError.recordCountMismatch(expected: header.recordCount, actual: payload.count / max(size, 1))
            }
        case .pcm16leV1:
            guard payload.count == header.recordCount * 2 else {
                throw EnvelopeError.recordCountMismatch(expected: header.recordCount, actual: payload.count / 2)
            }
        }
        return (header, payload)
    }
}

@inline(__always)
func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
