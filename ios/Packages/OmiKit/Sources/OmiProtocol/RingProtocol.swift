import Foundation

/// Offline ring storage protocol, firmware ≥ 3.0.20 (device-protocol.md, Omi `ring_protocol.dart`,
/// firmware `storage.c`). Status read is u32 LE ×4; every other multi-byte field is big-endian.
public enum RingProtocol {
    public static let recordSize = 444
    public static let timestampBytes = 4
    public static let audioPayloadBytes = recordSize - timestampBytes  // 440

    public enum Opcode {
        public static let ack: UInt8 = 0x01
        public static let info: UInt8 = 0x02
        public static let data: UInt8 = 0x03
        public static let done: UInt8 = 0x04
        public static let readBegin: UInt8 = 0x05
    }

    public enum Command {
        public static let stop: UInt8 = 0x03
        public static let info: UInt8 = 0x10
        public static let read: UInt8 = 0x11
        public static let advance: UInt8 = 0x12
        // 0x13 CLEAR exists but is never sent by this app.
    }

    public enum StatusCode {
        public static let ok: UInt8 = 0
        public static let invalid: UInt8 = 6
        public static let notReady: UInt8 = 9
        public static let sequenceOutOfRange: UInt8 = 10

        public static func describe(_ code: UInt8) -> String {
            switch code {
            case ok: return "ok"
            case invalid: return "invalid command"
            case notReady: return "storage not ready"
            case sequenceOutOfRange: return "sequence out of range"
            default: return "status \(code)"
            }
        }
    }

    // MARK: Status read (30295782)

    public struct Status: Equatable, Sendable {
        public let usedBytes: UInt32
        public let unreadRecords: UInt32
        public let freeBytes: UInt32
        public let rtcValid: Bool
    }

    public enum StatusParse: Equatable, Sendable {
        case ring(Status)
        /// 8-byte status: legacy (DevKit / multi-file) protocol. Unsupported; send nothing.
        case legacy
        case invalid(length: Int)
    }

    /// Detection step 3: exactly 16 bytes → ring protocol; 8 bytes → legacy; anything else → invalid.
    public static func parseStatus(_ data: Data) -> StatusParse {
        let b = [UInt8](data)
        if b.count == 8 { return .legacy }
        guard b.count == 16 else { return .invalid(length: b.count) }
        return .ring(Status(
            usedBytes: le32(b, 0), unreadRecords: le32(b, 4), freeBytes: le32(b, 8), rtcValid: le32(b, 12) != 0))
    }

    // MARK: Notifications (30295781)

    public struct Info: Equatable, Sendable {
        public let readSeq: UInt64
        public let writeSeq: UInt64
        public let capacity: UInt32
        public let dropped: UInt64
        public let recordSize: UInt16
        public var unread: UInt64 { writeSeq >= readSeq ? writeSeq - readSeq : 0 }

        public init(readSeq: UInt64, writeSeq: UInt64, capacity: UInt32, dropped: UInt64, recordSize: UInt16) {
            self.readSeq = readSeq
            self.writeSeq = writeSeq
            self.capacity = capacity
            self.dropped = dropped
            self.recordSize = recordSize
        }
    }

    public struct Done: Equatable, Sendable {
        public let status: UInt8
        public let nextSeq: UInt64
    }

    public struct ReadBegin: Equatable, Sendable {
        public let startSeq: UInt64
        public let count: UInt32
    }

    public enum Notification: Equatable, Sendable {
        case ack(status: UInt8)
        case info(Info)
        case data(Data)
        case done(Done)
        case readBegin(ReadBegin)
        case malformed(opcode: UInt8?, length: Int)
    }

    public static func parseNotification(_ data: Data) -> Notification {
        let b = [UInt8](data)
        guard let op = b.first else { return .malformed(opcode: nil, length: 0) }
        switch op {
        case Opcode.ack:
            guard b.count >= 2 else { return .malformed(opcode: op, length: b.count) }
            return .ack(status: b[1])
        case Opcode.info:
            guard b.count == 31 else { return .malformed(opcode: op, length: b.count) }
            return .info(Info(
                readSeq: be64(b, 1), writeSeq: be64(b, 9), capacity: be32(b, 17), dropped: be64(b, 21),
                recordSize: be16(b, 29)))
        case Opcode.data:
            return .data(Data(b[1...]))
        case Opcode.done:
            guard b.count >= 10 else { return .malformed(opcode: op, length: b.count) }
            return .done(Done(status: b[1], nextSeq: be64(b, 2)))
        case Opcode.readBegin:
            guard b.count >= 13 else { return .malformed(opcode: op, length: b.count) }
            return .readBegin(ReadBegin(startSeq: be64(b, 1), count: be32(b, 9)))
        default:
            return .malformed(opcode: op, length: b.count)
        }
    }

    // MARK: Commands

    public static func infoCommand() -> Data { Data([Command.info]) }

    /// `[0x11][start_seq:u64 BE][count:u32 BE]`, count 0 = everything available.
    public static func readCommand(startSeq: UInt64, count: UInt32 = 0) -> Data {
        var d = Data([Command.read])
        d.append(be(startSeq))
        d.append(be(count))
        return d
    }

    /// `[0x12][new_read_seq:u64 BE]`.
    public static func advanceCommand(newReadSeq: UInt64) -> Data {
        var d = Data([Command.advance])
        d.append(be(newReadSeq))
        return d
    }

    public static func stopCommand() -> Data { Data([Command.stop]) }

    // MARK: Records

    /// `[unix_ts:u32 BE]` of a 444-byte record.
    public static func recordTimestamp(_ record: Data) -> UInt32 {
        let b = [UInt8](record.prefix(4))
        guard b.count == 4 else { return 0 }
        return be32(b, 0)
    }

    /// Opus frames packed in the 440-byte payload: repeated `[len:u8][frame]`, `0` = padding.
    /// Stops when `offset + 1 + len >= 440` (firmware's dangling length byte at the boundary).
    /// Used for tests and UI estimates only; the server does the real parse.
    public static func parseAudioPayload(_ payload: Data) -> [Data] {
        let b = [UInt8](payload)
        var frames: [Data] = []
        var offset = 0
        while offset < b.count - 1 {
            let size = Int(b[offset])
            if size == 0 { offset += 1; continue }
            if offset + 1 + size >= b.count { break }
            frames.append(Data(b[(offset + 1)..<(offset + 1 + size)]))
            offset += 1 + size
        }
        return frames
    }

    // MARK: Byte helpers

    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    static func be16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    static func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(b[o + i]) }
        return v
    }
    public static func be<T: FixedWidthInteger>(_ v: T) -> Data {
        withUnsafeBytes(of: v.bigEndian) { Data($0) }
    }
}

/// Reassembles unaligned `NOTIFY_DATA` payloads (opcode stripped) into 444-byte records.
public struct RingRecordReassembler: Sendable {
    public let recordSize: Int
    private var buffer = Data()

    public init(recordSize: Int = RingProtocol.recordSize) { self.recordSize = recordSize }

    /// Appends bytes and returns every record completed by them.
    public mutating func append(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var out: [Data] = []
        var start = buffer.startIndex
        while buffer.endIndex - start >= recordSize {
            out.append(Data(buffer[start..<(start + recordSize)]))
            start += recordSize
        }
        if start != buffer.startIndex { buffer = Data(buffer[start...]) }
        return out
    }

    public var pendingBytes: Int { buffer.count }
    public mutating func reset() { buffer = Data() }
}
