import Foundation

/// CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) — identical to `zlib.crc32`.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    /// Continue a running CRC. Start with `crc = 0`.
    public static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }

    public static func checksum(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        data.withUnsafeBytes { update(seed, $0) }
    }

    public static func checksum(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        bytes.withUnsafeBytes { update(seed, $0) }
    }
}
