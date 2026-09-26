import Foundation

// MARK: - Codec

/// Audio codec ids read from `O(0002)` (first byte).
public enum OmiCodec: Int, Sendable, Codable, CaseIterable {
    /// Opus, DevKit, 160 samples = 10 ms.
    case opus10ms = 20
    /// Opus FS320, Omi CV1, 320 samples = 20 ms.
    case opus20ms = 21

    public var frameSamples: Int { self == .opus10ms ? 160 : 320 }
    public var label: String { self == .opus10ms ? "Opus 10 ms (DevKit)" : "Opus 20 ms (CV1)" }

    public enum Evaluation: Equatable, Sendable {
        case supported(OmiCodec)
        /// Unknown or legacy PCM id. The app refuses to record rather than producing garbage.
        case unsupported(id: Int)
        case unreadable
    }

    public static func evaluate(_ value: Data?) -> Evaluation {
        guard let value, let first = value.first else { return .unreadable }
        if let codec = OmiCodec(rawValue: Int(first)) { return .supported(codec) }
        return .unsupported(id: Int(first))
    }
}

// MARK: - Live audio packet header

/// `[seq:u16 LE][fragment_index:u8][payload…]`. Parsed on the phone only for UI statistics;
/// frame reassembly is server-side.
public struct AudioPacketHeader: Equatable, Sendable {
    public let sequence: UInt16
    public let fragmentIndex: UInt8
    public let payloadLength: Int

    public init?(_ data: Data) {
        guard data.count >= 3 else { return nil }
        let b = [UInt8](data.prefix(3))
        sequence = UInt16(b[0]) | (UInt16(b[1]) << 8)
        fragmentIndex = b[2]
        payloadLength = data.count - 3
    }
}

/// Counts notifications lost to sequence gaps within one connection.
/// `seq` increments per notification and wraps at 65536.
public struct SequenceLossTracker: Sendable, Equatable {
    public private(set) var received: Int = 0
    public private(set) var lost: Int = 0
    public private(set) var duplicates: Int = 0
    public private(set) var lastSequence: UInt16?

    /// Gaps larger than this are treated as a restart of the counter, not loss
    /// (the firmware never resets seq, but a device reboot does).
    public var maxPlausibleGap: Int = 10_000

    public init() {}

    public mutating func record(_ seq: UInt16) {
        defer { lastSequence = seq }
        guard let last = lastSequence else { received += 1; return }
        let gap = Int(seq &- last)
        if gap == 0 { duplicates += 1; return }
        received += 1
        if gap > 1, gap <= maxPlausibleGap { lost += gap - 1 }
    }

    /// Percentage of notifications missing, 0…100.
    public var lossPercent: Double {
        let total = received + lost
        return total == 0 ? 0 : Double(lost) * 100 / Double(total)
    }
}

// MARK: - Button

/// Button characteristic payload: `i32 LE event` + 4 zero bytes (CV1 emits 1, 2, 5).
public enum ButtonEvent: Equatable, Sendable {
    case singleTap      // 1 → bookmark
    case doubleTap      // 2 → end the current conversation now (and rotate the chunk)
    case longTap        // 3 (not emitted by CV1)
    case press          // 4 (not emitted by CV1)
    case release        // 5 → ignored
    case unknown(Int32)

    public static func decode(_ data: Data) -> ButtonEvent? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(4))
        let raw = Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        switch raw {
        case 1: return .singleTap
        case 2: return .doubleTap
        case 3: return .longTap
        case 4: return .press
        case 5: return .release
        default: return .unknown(raw)
        }
    }

    /// Code uploaded in a `button` event, or nil if the event is not forwarded.
    public var uploadCode: Int? {
        switch self {
        case .singleTap: return 1
        case .doubleTap: return 2
        default: return nil
        }
    }
}

// MARK: - Features

/// `O(0021)`: u32 LE bitmask. Bit 6 = offline storage (CV1 = 0x1EC).
public struct DeviceFeatures: Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public init?(_ data: Data) {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(4))
        rawValue = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    public var offlineStorage: Bool { rawValue & (1 << 6) != 0 }
}

// MARK: - Firmware version

/// Parses DIS firmware strings like `3.0.21`, `v3.0.20`, `3.0.20-rc1`, `3.0`.
public struct FirmwareVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init(_ components: [Int]) { self.components = components }

    public init?(_ string: String?) {
        guard var s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        // Keep the leading dotted-number part; stop at the first other character.
        let core = s.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard let n = Int(p) else { return nil }
            nums.append(n)
        }
        components = nums
    }

    public static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        for i in 0..<n {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Offline ring storage protocol starts at 3.0.20.
    public static let ringProtocolMinimum = FirmwareVersion([3, 0, 20])
}

// MARK: - Offline storage support (static part of detection)

public enum OfflineStorageSupport: Equatable, Sendable {
    case unknown
    case supported
    case unsupported(String)

    /// Header value `offline_storage`: true / false / null.
    public var headerValue: Bool? {
        switch self {
        case .unknown: return nil
        case .supported: return true
        case .unsupported: return false
        }
    }

    /// Detection steps 1–2 from device-protocol.md: service + both characteristics present,
    /// firmware ≥ 3.0.20, and features bit 6 set when the features characteristic exists.
    ///
    /// `.unsupported` (header `offline_storage: false`) only on affirmative evidence: a parsed
    /// firmware version < 3.0.20, features read successfully with bit 6 clear, or firmware ≥ 3.0.20
    /// without the storage service. Unreadable/unparseable metadata stays `.unknown` (header `null`).
    /// `features == nil` with `hasFeaturesCharacteristic == true` means the read failed.
    public static func staticCheck(
        hasStorageService: Bool,
        firmwareRevision: String?,
        features: DeviceFeatures?,
        hasFeaturesCharacteristic: Bool
    ) -> OfflineStorageSupport {
        let version = FirmwareVersion(firmwareRevision)
        if let version, version < FirmwareVersion.ringProtocolMinimum {
            return .unsupported("firmware \(version) < 3.0.20")
        }
        if hasFeaturesCharacteristic, let features, !features.offlineStorage {
            return .unsupported("features bit 6 not set")
        }
        guard version != nil else { return .unknown }
        guard hasStorageService else { return .unsupported("no storage service") }
        if hasFeaturesCharacteristic, features == nil { return .unknown }
        return .supported
    }
}
