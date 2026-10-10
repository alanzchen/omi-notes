import Compression
import CryptoKit
import Foundation

// Firmware updates for the Omi CV1 (device-protocol.md "Firmware update"): which release to install,
// and checking its package before anything is sent to the pendant.

/// A CV1 firmware release as the Omi backend describes it (`GET /v2/firmware/latest` and
/// `/v2/firmware/stable`: no account needed, `backend/routers/firmware.py`; the Omi app's
/// `app/lib/backend/http/api/device.dart`). The answer comes from BasedHardware/omi's GitHub releases.
public struct FirmwareRelease: Equatable, Sendable {
    public var version: String
    public var minimumFirmware: String?
    public var zipURL: URL
    public var changelog: [String]
    public var legacySecureDFU: Bool

    public static let cv1Model = "Omi CV 1"
    public static let apiBase = URL(string: "https://api.omi.me/v2/firmware/")!

    public init(version: String, minimumFirmware: String?, zipURL: URL, changelog: [String], legacySecureDFU: Bool) {
        self.version = version
        self.minimumFirmware = minimumFirmware
        self.zipURL = zipURL
        self.changelog = changelog
        self.legacySecureDFU = legacySecureDFU
    }

    /// Decodes an answer; nil for anything else (a 404 "no suitable firmware" is handled by the caller).
    public init?(omiAPI data: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = o["version"] as? String, FirmwareVersion(version) != nil,
              let zip = (o["zip_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        self.init(version: version, minimumFirmware: o["min_version"] as? String, zipURL: zip,
                  changelog: (o["changelog"] as? [String]) ?? [], legacySecureDFU: o["is_legacy_secure_dfu"] as? Bool ?? true)
    }

    /// The request for a newer release than the pendant's (the backend answers 404 when there is none).
    public static func latestURL(model: String, firmware: String, hardware: String?, manufacturer: String?) -> URL {
        var c = URLComponents(url: apiBase.appendingPathComponent("latest"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "device_model", value: model), URLQueryItem(name: "firmware_revision", value: firmware),
                        URLQueryItem(name: "hardware_revision", value: hardware ?? ""), URLQueryItem(name: "manufacturer_name", value: manufacturer ?? "")]
        return c.url!
    }

    /// The request for the newest published release (the Omi app's "roll back to stable").
    public static func stableURL(model: String) -> URL {
        var c = URLComponents(url: apiBase.appendingPathComponent("stable"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "device_model", value: model)]
        return c.url!
    }

    /// The package is the official release asset for exactly this version (the backend points to it;
    /// `.github/workflows/firmware_release.yml` publishes `Omi_CV1_OTA_v<version>.zip` under tag
    /// `Omi_CV1_v<version>`).
    public var isOfficialCV1Asset: Bool {
        zipURL.scheme == "https" && zipURL.host == "github.com"
            && zipURL.path.hasPrefix("/BasedHardware/omi/releases/download/Omi_CV1_v\(version)/")
            && zipURL.lastPathComponent.lowercased().hasSuffix(".zip")
    }

    /// Why this release can't be installed here, or nil.
    public func blocker(installedOn current: FirmwareVersion?) -> String? {
        if legacySecureDFU { return "it needs the older Nordic DFU, which this app doesn't do" }
        if !isOfficialCV1Asset { return "its download isn't the official Omi release" }
        if let current, let min = minimumFirmware.flatMap(FirmwareVersion.init), current < min {
            return "the pendant's firmware is older than this update supports (\(min))"
        }
        return nil
    }
}

// MARK: - Zip (stored or deflated entries; enough for an OTA package)

public enum ZipError: Error, Equatable, LocalizedError {
    case malformed(String), unsupported(String), crcMismatch(String)
    public var errorDescription: String? {
        switch self {
        case .malformed(let s): return "the package is damaged (\(s))"
        case .unsupported(let s): return "the package uses an unsupported format (\(s))"
        case .crcMismatch(let s): return "the package is damaged (\(s) doesn't match its checksum)"
        }
    }
}

public struct ZipArchive: Sendable {
    public let entries: [String: Data]

    public init(_ data: Data) throws {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // End of central directory: the last 0x06054b50 (a comment can follow it).
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 65_535) {
            if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.malformed("no directory") }
        let count = u16(eocd + 10), dirOffset = u32(eocd + 16)
        var entries: [String: Data] = [:]
        var p = dirOffset
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014b50 else { throw ZipError.malformed("directory entry") }
            let method = u16(p + 10), crc = UInt32(u32(p + 16)), compressed = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nameLen <= b.count else { throw ZipError.malformed("name") }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            guard local + 30 <= b.count, u32(local) == 0x04034b50 else { throw ZipError.malformed("entry \(name)") }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= b.count else { throw ZipError.malformed("entry \(name)") }
            let raw = Data(b[start..<(start + compressed)])
            let content: Data
            switch method {
            case 0: content = raw
            case 8: content = try Self.inflate(raw, size: size, name: name)
            default: throw ZipError.unsupported("compression \(method)")
            }
            guard content.count == size, CRC32.checksum(content) == crc else { throw ZipError.crcMismatch(name) }
            if !name.hasSuffix("/") { entries[name] = content }
        }
        self.entries = entries
    }

    static func inflate(_ data: Data, size: Int, name: String) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.malformed("entry \(name)") }
        return out
    }
}

// MARK: - MCUboot image

/// A signed MCUboot image: header, body, TLVs. The bootloader verifies the signature; the app checks
/// the structure, that the SHA-256 TLV matches the image, and that it is signed with the CV1 key.
public struct MCUbootImage: Equatable, Sendable {
    public let data: Data
    /// SHA-256 TLV: the hash MCUmgr's image state commands identify the image by.
    public let hash: Data
    public let keyHash: Data?
    public let headerVersion: String

    public static let magic: UInt32 = 0x96f3_b83d

    public init(_ data: Data) throws {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 32, UInt32(u32(0)) == Self.magic else { throw FirmwarePackageError.invalidImage("not an MCUboot image") }
        let headerSize = u16(8), protectedSize = u16(10), imageSize = u32(12)
        headerVersion = "\(b[20]).\(b[21]).\(u16(22))+\(u32(24))"
        var p = headerSize + imageSize
        guard p <= b.count else { throw FirmwarePackageError.invalidImage("shorter than its header says") }
        var hash: Data?, keyHash: Data?
        for want in [0x6908, 0x6907] where p + 4 <= b.count && u16(p) == want {
            let end = p + u16(p + 2)
            guard end <= b.count else { throw FirmwarePackageError.invalidImage("TLV area") }
            var q = p + 4
            while q + 4 <= end {
                let type = u16(q), len = u16(q + 2)
                guard q + 4 + len <= end else { throw FirmwarePackageError.invalidImage("TLV") }
                if type == 0x10 { hash = Data(b[(q + 4)..<(q + 4 + len)]) }
                if type == 0x01 { keyHash = Data(b[(q + 4)..<(q + 4 + len)]) }
                q += 4 + len
            }
            p = end
        }
        guard p == b.count else { throw FirmwarePackageError.invalidImage("unexpected bytes after the TLVs") }
        guard let hash, hash.count == 32 else { throw FirmwarePackageError.invalidImage("no SHA-256") }
        let covered = data.prefix(headerSize + imageSize + protectedSize)
        guard Data(SHA256.hash(data: covered)) == hash else { throw FirmwarePackageError.invalidImage("SHA-256 doesn't match") }
        self.data = data
        self.hash = hash
        self.keyHash = keyHash
    }
}

// MARK: - OTA package

public enum FirmwarePackageError: Error, Equatable, LocalizedError {
    case invalidManifest(String), invalidImage(String), wrongDevice(String), tooLarge(String)
    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let s): return "the update package isn't valid (\(s))"
        case .invalidImage(let s): return "an image in the update isn't valid (\(s))"
        case .wrongDevice(let s): return "the update isn't for this pendant (\(s))"
        case .tooLarge(let s): return "the update doesn't fit the pendant (\(s))"
        }
    }
}

/// A CV1 OTA package (`dfu_application.zip` from the nRF Connect SDK build): `manifest.json` with
/// image 0 (application core, board `omi`) and image 1 (network core, `omi/nrf5340/cpunet`).
public struct FirmwarePackage: Equatable, Sendable {
    public struct Image: Equatable, Sendable {
        public let index: Int
        public let image: MCUbootImage
    }

    public let images: [Image]

    /// Key hash TLV of every published CV1 image (3.0.17–3.0.21): the bootloader's signing key
    /// (`omi/firmware/sysbuild.conf` `SB_CONFIG_BOOT_SIGNATURE_KEY_FILE`, RSA-2048).
    public static let cv1KeyHash = Data([
        0xfc, 0x57, 0x01, 0xdc, 0x61, 0x35, 0xe1, 0x32, 0x38, 0x47, 0xbd, 0xc4, 0x0f, 0x04, 0xd2, 0xe5,
        0xbe, 0xe5, 0x83, 0x3b, 0x23, 0xc2, 0x9f, 0x93, 0x59, 0x3d, 0x00, 0x01, 0x8c, 0xfa, 0x99, 0x94,
    ])
    /// Secondary slots (`omi/firmware/boards/omi/pm_static.yml`: mcuboot_secondary 0xf0000,
    /// mcuboot_secondary_1 0x40000).
    public static let slotSize = [0: 0xF0000, 1: 0x40000]
    static let boards = [0: "omi", 1: "omi/nrf5340/cpunet"]

    public init(zip: Data) throws {
        let archive = try ZipArchive(zip)
        guard let manifestData = archive.entries["manifest.json"],
              let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
              let files = manifest["files"] as? [[String: Any]] else { throw FirmwarePackageError.invalidManifest("no manifest") }
        var images: [Image] = []
        for f in files {
            guard let indexText = f["image_index"] as? String, let index = Int(indexText),
                  let name = f["file"] as? String, let bytes = archive.entries[name] else {
                throw FirmwarePackageError.invalidManifest("file entry")
            }
            guard let board = Self.boards[index] else { throw FirmwarePackageError.wrongDevice("image \(index)") }
            guard f["board"] as? String == board, f["soc"] as? String == "nrf5340" else {
                throw FirmwarePackageError.wrongDevice("\(f["board"] as? String ?? "?") for image \(index)")
            }
            if let size = f["size"] as? Int, size != bytes.count { throw FirmwarePackageError.invalidManifest("size of \(name)") }
            guard bytes.count <= Self.slotSize[index]! else { throw FirmwarePackageError.tooLarge("image \(index)") }
            let image = try MCUbootImage(bytes)
            guard image.keyHash == Self.cv1KeyHash else { throw FirmwarePackageError.wrongDevice("not signed for the CV1 bootloader") }
            images.append(Image(index: index, image: image))
        }
        guard Set(images.map(\.index)) == [0, 1], images.count == 2 else {
            throw FirmwarePackageError.invalidManifest("expected the application and network core images")
        }
        self.images = images.sorted { $0.index < $1.index }
    }

    public var totalBytes: Int { images.reduce(0) { $0 + $1.image.data.count } }
}
