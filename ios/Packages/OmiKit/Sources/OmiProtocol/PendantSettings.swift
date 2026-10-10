import Foundation

/// The pendant's own settings (device-protocol.md "Pendant settings"): one byte each in the settings
/// service, saved in the pendant's flash and applied at once. A write is confirmed only by reading
/// the value back.
public enum PendantSetting: String, Sendable, CaseIterable {
    /// LED brightness, 0–100 % (0 = off). Firmware default 50.
    case ledBrightness
    /// Microphone gain level, 0–8 (0 = muted). Firmware default 6 (+20 dB).
    case micGain

    public var characteristic: OmiCharacteristic {
        switch self {
        case .ledBrightness: return .ledDimRatio
        case .micGain: return .micGain
        }
    }

    public var range: ClosedRange<Int> {
        switch self {
        case .ledBrightness: return 0...100
        case .micGain: return 0...8
        }
    }

    public var firmwareDefault: Int {
        switch self {
        case .ledBrightness: return 50
        case .micGain: return 6
        }
    }

    /// Advertised by the features characteristic (bit 7 LED dimming, bit 8 mic gain).
    public func isAdvertised(by features: DeviceFeatures) -> Bool {
        switch self {
        case .ledBrightness: return features.ledDimming
        case .micGain: return features.micGain
        }
    }

    /// The single byte written (out-of-range values are clamped, as the firmware also does).
    public func encode(_ value: Int) -> Data { Data([UInt8(min(max(value, range.lowerBound), range.upperBound))]) }

    /// A read value, or nil when the pendant answered with nothing usable.
    public func decode(_ data: Data?) -> Int? {
        guard let b = data?.first, range.contains(Int(b)) else { return nil }
        return Int(b)
    }
}

/// Microphone gain levels as the firmware maps them (`omi/firmware/omi/src/mic.c` `mic_set_gain`).
public enum MicGainLevel {
    public static func label(_ level: Int) -> String {
        let decibels = ["−20 dB", "−10 dB", "0 dB", "+6 dB", "+10 dB", "+20 dB", "+30 dB", "+40 dB"]
        if level == 0 { return "Muted" }
        return (1...8).contains(level) ? decibels[level - 1] : "—"
    }
}

/// A vibration (`omi/firmware/omi/src/haptic.c`): writing 1, 2 or 3 buzzes for 100, 300 or 500 ms.
public enum HapticPulse: UInt8, Sendable {
    case short = 1, medium = 2, long = 3
    public var payload: Data { Data([rawValue]) }
}
