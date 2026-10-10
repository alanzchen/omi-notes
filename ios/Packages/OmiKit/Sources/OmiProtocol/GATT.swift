import Foundation

/// GATT identifiers used by the app (docs/device-protocol.md).
/// UUIDs are lowercase strings so this module stays free of CoreBluetooth.
public enum OmiUUID {
    /// `O(xxxx)` = `19b1xxxx-e8f2-537e-4f6c-d104768a1214`.
    public static func omi(_ short: String) -> String { "19b1\(short)-e8f2-537e-4f6c-d104768a1214" }

    public static let audioService = omi("0000")
    public static let audioData = omi("0001")
    public static let audioCodec = omi("0002")

    public static let batteryService = "180f"
    public static let batteryLevel = "2a19"

    public static let deviceInfoService = "180a"
    public static let modelNumber = "2a24"
    public static let serialNumber = "2a25"
    public static let firmwareRevision = "2a26"
    public static let hardwareRevision = "2a27"
    public static let manufacturerName = "2a29"

    public static let featuresService = omi("0020")
    public static let features = omi("0021")

    public static let timeSyncService = omi("0030")
    public static let timeSyncWrite = omi("0031")
    public static let timeSyncRead = omi("0032")

    public static let buttonService = "23ba7924-0000-1000-7450-346eac492e92"
    public static let button = "23ba7925-0000-1000-7450-346eac492e92"

    public static let settingsService = omi("0010")
    public static let ledDimRatio = omi("0011")
    public static let micGain = omi("0012")
    public static let charging = omi("0013")

    /// The vibration motor (`omi/firmware/omi/src/haptic.c`).
    public static let hapticService = "cab1ab95-2ea5-4f4d-bb56-874b72cfc984"
    public static let haptic = "cab1ab96-2ea5-4f4d-bb56-874b72cfc984"

    public static let storageService = "30295780-4301-eabd-2904-2849adfeae43"
    public static let storageControl = "30295781-4301-eabd-2904-2849adfeae43"
    public static let storageStatus = "30295782-4301-eabd-2904-2849adfeae43"
}

/// Every characteristic the app touches, with its service.
public enum OmiCharacteristic: String, CaseIterable, Sendable, Hashable {
    case audioData, audioCodec
    case batteryLevel
    case modelNumber, serialNumber, firmwareRevision, hardwareRevision, manufacturerName
    case features
    case timeSyncWrite, timeSyncRead
    case button
    case charging
    case ledDimRatio, micGain
    case haptic
    case storageControl, storageStatus

    public var serviceUUID: String {
        switch self {
        case .audioData, .audioCodec: return OmiUUID.audioService
        case .batteryLevel: return OmiUUID.batteryService
        case .modelNumber, .serialNumber, .firmwareRevision, .hardwareRevision, .manufacturerName:
            return OmiUUID.deviceInfoService
        case .features: return OmiUUID.featuresService
        case .timeSyncWrite, .timeSyncRead: return OmiUUID.timeSyncService
        case .button: return OmiUUID.buttonService
        case .charging, .ledDimRatio, .micGain: return OmiUUID.settingsService
        case .haptic: return OmiUUID.hapticService
        case .storageControl, .storageStatus: return OmiUUID.storageService
        }
    }

    public var uuid: String {
        switch self {
        case .audioData: return OmiUUID.audioData
        case .audioCodec: return OmiUUID.audioCodec
        case .batteryLevel: return OmiUUID.batteryLevel
        case .modelNumber: return OmiUUID.modelNumber
        case .serialNumber: return OmiUUID.serialNumber
        case .firmwareRevision: return OmiUUID.firmwareRevision
        case .hardwareRevision: return OmiUUID.hardwareRevision
        case .manufacturerName: return OmiUUID.manufacturerName
        case .features: return OmiUUID.features
        case .timeSyncWrite: return OmiUUID.timeSyncWrite
        case .timeSyncRead: return OmiUUID.timeSyncRead
        case .button: return OmiUUID.button
        case .charging: return OmiUUID.charging
        case .ledDimRatio: return OmiUUID.ledDimRatio
        case .micGain: return OmiUUID.micGain
        case .haptic: return OmiUUID.haptic
        case .storageControl: return OmiUUID.storageControl
        case .storageStatus: return OmiUUID.storageStatus
        }
    }

    /// Services the connection sequence discovers (in this order).
    public static let serviceUUIDs: [String] = [
        OmiUUID.audioService, OmiUUID.timeSyncService, OmiUUID.deviceInfoService, OmiUUID.featuresService,
        OmiUUID.batteryService, OmiUUID.buttonService, OmiUUID.settingsService, OmiUUID.storageService,
        OmiUUID.hapticService,
    ]

    /// Lookup by (service, characteristic), both lowercase. 16-bit SIG UUIDs are 4 hex chars.
    public static func find(service: String, characteristic: String) -> OmiCharacteristic? {
        let s = normalize(service), c = normalize(characteristic)
        return allCases.first { normalize($0.serviceUUID) == s && normalize($0.uuid) == c }
    }

    /// Reduce `0000180f-0000-1000-8000-00805f9b34fb` to `180f`; lowercase everything.
    public static func normalize(_ uuid: String) -> String {
        let u = uuid.lowercased()
        let base = "-0000-1000-8000-00805f9b34fb"
        if u.count == 36, u.hasPrefix("0000"), u.hasSuffix(base) {
            return String(u.dropFirst(4).prefix(4))
        }
        return u
    }
}

/// Which advertisements the foreground pairing scan shows (device-protocol.md "Scanning").
public enum DeviceScanFilter {
    public static let knownNames: Set<String> = ["Omi", "Omi DevKit 2", "Friend"]

    /// `advertisedServices` are lowercase UUID strings from the advertisement.
    public static func isCandidate(name: String?, advertisedServices: [String]) -> Bool {
        if let name, name.lowercased().contains("glass") { return false }  // OmiGlass reuses O(0000)
        if advertisedServices.map({ OmiCharacteristic.normalize($0) }).contains(OmiUUID.audioService) { return true }
        guard let name else { return false }
        return knownNames.contains(name)
    }
}
