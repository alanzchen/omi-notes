import Foundation

// MCUmgr SMP over BLE, the firmware's update transport (`omi/firmware/omi/omi.conf`
// `CONFIG_NCS_SAMPLE_MCUMGR_BT_OTA_DFU=y`; the Omi app uses it through `mcumgr_flutter`). Only what an
// image update needs: upload, image state (read / confirm) and reset.

/// A CBOR value: the subset SMP uses (definite and indefinite-length maps and arrays).
public indirect enum CBOR: Equatable, Sendable {
    case uint(UInt64), nint(Int64), bytes(Data), text(String), array([CBOR]), map([(String, CBOR)]), bool(Bool), null

    public static func == (a: CBOR, b: CBOR) -> Bool {
        switch (a, b) {
        case (.uint(let x), .uint(let y)): return x == y
        case (.nint(let x), .nint(let y)): return x == y
        case (.bytes(let x), .bytes(let y)): return x == y
        case (.text(let x), .text(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.map(let x), .map(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public subscript(key: String) -> CBOR? {
        if case .map(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    public var int: Int? {
        switch self {
        case .uint(let v): return Int(exactly: v)
        case .nint(let v): return Int(exactly: v)
        default: return nil
        }
    }

    public var data: Data? { if case .bytes(let d) = self { return d } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var array: [CBOR]? { if case .array(let a) = self { return a } else { return nil } }
    public var string: String? { if case .text(let s) = self { return s } else { return nil } }

    // MARK: Encoding (definite lengths)

    public func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    func encode(into out: inout Data) {
        func head(_ major: UInt8, _ value: UInt64) {
            let m = major << 5
            switch value {
            case 0..<24: out.append(m | UInt8(value))
            case 24..<0x100: out.append(m | 24); out.append(UInt8(value))
            case 0x100..<0x1_0000: out.append(m | 25); out.append(contentsOf: withUnsafeBytes(of: UInt16(value).bigEndian) { Array($0) })
            case 0x1_0000..<0x1_0000_0000: out.append(m | 26); out.append(contentsOf: withUnsafeBytes(of: UInt32(value).bigEndian) { Array($0) })
            default: out.append(m | 27); out.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) })
            }
        }
        switch self {
        case .uint(let v): head(0, v)
        case .nint(let v): head(1, UInt64(-1 - v))
        case .bytes(let d): head(2, UInt64(d.count)); out.append(d)
        case .text(let s): let u = Data(s.utf8); head(3, UInt64(u.count)); out.append(u)
        case .array(let a): head(4, UInt64(a.count)); for v in a { v.encode(into: &out) }
        case .map(let pairs):
            head(5, UInt64(pairs.count))
            for (k, v) in pairs { CBOR.text(k).encode(into: &out); v.encode(into: &out) }
        case .bool(let b): out.append(b ? 0xf5 : 0xf4)
        case .null: out.append(0xf6)
        }
    }

    // MARK: Decoding

    public static func decode(_ data: Data) -> CBOR? {
        var r = Reader(bytes: [UInt8](data))
        return r.value()
    }

    struct Reader {
        let bytes: [UInt8]
        var i = 0

        mutating func byte() -> UInt8? {
            guard i < bytes.count else { return nil }
            defer { i += 1 }
            return bytes[i]
        }

        mutating func uint(_ info: UInt8) -> UInt64? {
            switch info {
            case 0..<24: return UInt64(info)
            case 24...27:
                let n = 1 << Int(info - 24)
                guard i + n <= bytes.count else { return nil }
                var v: UInt64 = 0
                for _ in 0..<n { v = v << 8 | UInt64(bytes[i]); i += 1 }
                return v
            default: return nil
            }
        }

        mutating func value() -> CBOR? {
            guard let b = byte() else { return nil }
            let major = b >> 5, info = b & 0x1f
            if info == 31 {  // indefinite length (map/array), as zcbor may encode them
                switch major {
                case 4:
                    var a: [CBOR] = []
                    while i < bytes.count, bytes[i] != 0xff { guard let v = value() else { return nil }; a.append(v) }
                    guard byte() == 0xff else { return nil }
                    return .array(a)
                case 5:
                    var pairs: [(String, CBOR)] = []
                    while i < bytes.count, bytes[i] != 0xff {
                        guard case .text(let k)? = value(), let v = value() else { return nil }
                        pairs.append((k, v))
                    }
                    guard byte() == 0xff else { return nil }
                    return .map(pairs)
                default: return nil
                }
            }
            switch major {
            case 0: return uint(info).map(CBOR.uint)
            case 1: return uint(info).map { .nint(-1 - Int64($0)) }
            case 2, 3:
                guard let n = uint(info).flatMap({ Int(exactly: $0) }), i + n <= bytes.count else { return nil }
                defer { i += n }
                let d = Data(bytes[i..<(i + n)])
                return major == 2 ? .bytes(d) : .text(String(decoding: d, as: UTF8.self))
            case 4:
                guard let n = uint(info) else { return nil }
                var a: [CBOR] = []
                for _ in 0..<n { guard let v = value() else { return nil }; a.append(v) }
                return .array(a)
            case 5:
                guard let n = uint(info) else { return nil }
                var pairs: [(String, CBOR)] = []
                for _ in 0..<n {
                    guard case .text(let k)? = value(), let v = value() else { return nil }
                    pairs.append((k, v))
                }
                return .map(pairs)
            case 7:
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                default: return nil
                }
            default: return nil
            }
        }
    }
}

/// An SMP message: 8-byte header (op, flags, length, group, sequence, command id; big-endian) and a
/// CBOR map body. Version 1 framing (Zephyr answers both).
public struct SMPMessage: Equatable, Sendable {
    public enum Op: UInt8, Sendable { case read = 0, readResponse = 1, write = 2, writeResponse = 3 }

    public var op: Op
    public var group: UInt16
    public var id: UInt8
    public var sequence: UInt8
    public var body: CBOR

    public static let osGroup: UInt16 = 0, imageGroup: UInt16 = 1
    public static let imageState: UInt8 = 0, imageUpload: UInt8 = 1, osReset: UInt8 = 5

    public init(op: Op, group: UInt16, id: UInt8, sequence: UInt8, body: CBOR) {
        self.op = op
        self.group = group
        self.id = id
        self.sequence = sequence
        self.body = body
    }

    public func encoded() -> Data {
        let payload = body.encoded()
        var out = Data([op.rawValue, 0])
        out.append(contentsOf: withUnsafeBytes(of: UInt16(payload.count).bigEndian) { Array($0) })
        out.append(contentsOf: withUnsafeBytes(of: group.bigEndian) { Array($0) })
        out.append(sequence)
        out.append(id)
        out.append(payload)
        return out
    }

    /// Length of a whole message whose first 8 bytes are `header` (to reassemble notifications).
    public static func totalLength(header: Data) -> Int? {
        guard header.count >= 8 else { return nil }
        let b = [UInt8](header.prefix(8))
        return 8 + (Int(b[2]) << 8 | Int(b[3]))
    }

    public static func decode(_ data: Data) -> SMPMessage? {
        let b = [UInt8](data)
        guard b.count >= 8, let op = Op(rawValue: b[0] & 0x07), let total = totalLength(header: data), total == b.count,
              let body = CBOR.decode(Data(b[8...])) else { return nil }
        return SMPMessage(op: op, group: UInt16(b[4]) << 8 | UInt16(b[5]), id: b[7], sequence: b[6], body: body)
    }

    /// The error code: 0 is success. SMP v1 puts it in `rc`, v2 in `err.rc`.
    public var rc: Int { body["rc"]?.int ?? body["err"]?["rc"]?.int ?? 0 }

    // MARK: Requests

    /// One upload chunk. The first carries the image number, its length and SHA-256 (the firmware
    /// uses it to resume an interrupted upload).
    public static func upload(image: Int, offset: Int, chunk: Data, total: Int, sha: Data, sequence: UInt8) -> SMPMessage {
        var pairs: [(String, CBOR)] = []
        if offset == 0 {
            pairs = [("image", .uint(UInt64(image))), ("len", .uint(UInt64(total))), ("sha", .bytes(sha))]
        }
        pairs += [("off", .uint(UInt64(offset))), ("data", .bytes(chunk))]
        return SMPMessage(op: .write, group: imageGroup, id: imageUpload, sequence: sequence, body: .map(pairs))
    }

    /// The largest chunk whose whole upload request fits one write of `maximumWrite` bytes; 0 when
    /// not even one byte fits (the link's packets are too small to update over).
    public static func chunkSize(image: Int, offset: Int, total: Int, sha: Data, maximumWrite: Int) -> Int {
        var n = max(0, maximumWrite - 8)
        while n > 0, upload(image: image, offset: offset, chunk: Data(count: n), total: total, sha: sha, sequence: 0).encoded().count > maximumWrite {
            n -= 1
        }
        return n
    }

    public static func readImageState(sequence: UInt8) -> SMPMessage {
        SMPMessage(op: .read, group: imageGroup, id: imageState, sequence: sequence, body: .map([]))
    }

    /// Marks the image with this hash to be installed for good at the next restart (MCUboot here
    /// overwrites the old image: `sysbuild.conf` `SB_CONFIG_MCUBOOT_MODE_OVERWRITE_ONLY=y`).
    public static func confirm(hash: Data, sequence: UInt8) -> SMPMessage {
        SMPMessage(op: .write, group: imageGroup, id: imageState, sequence: sequence,
                   body: .map([("hash", .bytes(hash)), ("confirm", .bool(true))]))
    }

    public static func reset(sequence: UInt8) -> SMPMessage {
        SMPMessage(op: .write, group: osGroup, id: osReset, sequence: sequence, body: .map([]))
    }
}

/// Image slots as the firmware reports them (`images` of an image state read).
public struct SMPImageSlot: Equatable, Sendable {
    public var image: Int
    public var slot: Int
    public var hash: Data?
    public var pending: Bool
    public var confirmed: Bool
    public var active: Bool

    public static func parse(_ body: CBOR) -> [SMPImageSlot] {
        (body["images"]?.array ?? []).map { i in
            SMPImageSlot(image: i["image"]?.int ?? 0, slot: i["slot"]?.int ?? 0, hash: i["hash"]?.data,
                         pending: i["pending"]?.bool ?? false, confirmed: i["confirmed"]?.bool ?? false,
                         active: i["active"]?.bool ?? false)
        }
    }
}

/// Reassembles SMP responses split across notifications.
public struct SMPAssembler: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) -> SMPMessage? {
        buffer.append(data)
        guard let total = SMPMessage.totalLength(header: buffer), buffer.count >= total else { return nil }
        let whole = buffer.prefix(total)
        buffer = Data(buffer.dropFirst(total))
        return SMPMessage.decode(Data(whole))
    }

    public mutating func reset() { buffer = Data() }
}
