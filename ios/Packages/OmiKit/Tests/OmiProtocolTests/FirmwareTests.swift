import CryptoKit
import Foundation
import Testing
@testable import OmiProtocol

/// Synthetic CV1 OTA packages: MCUboot images (header, body, TLVs) in a stored zip with a manifest.
enum FirmwareFixture {
    static func image(size: Int = 600, keyHash: Data = FirmwarePackage.cv1KeyHash, seed: UInt8 = 1) -> Data {
        var d = Data()
        func le16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func le32(_ v: Int) { le16(v & 0xffff); le16(v >> 16 & 0xffff) }
        le32(Int(MCUbootImage.magic)); le32(0); le16(32); le16(0); le32(size); le32(0)
        d.append(contentsOf: [0, 0]); le16(0); le32(0); le32(0)  // version 0.0.0+0, pad
        d.append(contentsOf: (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
        let sha = Data(SHA256.hash(data: d))
        let tlvs = Data([0x01, 0x00, 0x20, 0x00]) + keyHash + Data([0x10, 0x00, 0x20, 0x00]) + sha
        le16(0x6907); le16(4 + tlvs.count)
        d.append(tlvs)
        return d
    }

    static func manifest(app: Int, net: Int, appBoard: String = "omi") -> Data {
        Data(#"{"format-version":1,"files":[{"type":"application","board":"\#(appBoard)","soc":"nrf5340","image_index":"0","size":\#(app),"file":"omi.signed.bin"},{"type":"application","board":"omi/nrf5340/cpunet","soc":"nrf5340","image_index":"1","size":\#(net),"file":"ipc_radio.bin"}],"name":"omi"}"#.utf8)
    }

    /// A zip with stored (uncompressed) entries, like the published OTA packages.
    static func zip(_ files: [(String, Data)]) -> Data {
        var out = Data(), directory = Data()
        func le16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func le32(_ v: Int, _ d: inout Data) { le16(v & 0xffff, &d); le16(v >> 16 & 0xffff, &d) }
        for (name, content) in files {
            let offset = out.count, crc = Int(CRC32.checksum(content)), n = Data(name.utf8)
            le32(0x04034b50, &out); le16(20, &out); le16(0, &out); le16(0, &out); le16(0, &out); le16(0, &out)
            le32(crc, &out); le32(content.count, &out); le32(content.count, &out); le16(n.count, &out); le16(0, &out)
            out.append(n); out.append(content)
            le32(0x02014b50, &directory); le16(20, &directory); le16(20, &directory); le16(0, &directory); le16(0, &directory)
            le16(0, &directory); le16(0, &directory); le32(crc, &directory); le32(content.count, &directory); le32(content.count, &directory)
            le16(n.count, &directory); le16(0, &directory); le16(0, &directory); le16(0, &directory); le16(0, &directory)
            le32(0, &directory); le32(offset, &directory); directory.append(n)
        }
        let dirOffset = out.count
        out.append(directory)
        le32(0x06054b50, &out); le16(0, &out); le16(0, &out); le16(files.count, &out); le16(files.count, &out)
        le32(directory.count, &out); le32(dirOffset, &out); le16(0, &out)
        return out
    }

    static func package(app: Data = image(seed: 1), net: Data = image(size: 400, seed: 2), appBoard: String = "omi") -> Data {
        zip([("manifest.json", manifest(app: app.count, net: net.count, appBoard: appBoard)), ("omi.signed.bin", app), ("ipc_radio.bin", net)])
    }

}

@Suite struct FirmwareReleaseTests {
    /// The backend's actual answer for a CV1 on 3.0.20 (read 2026-10-10 from api.omi.me, no account).
    static let answer = Data(#"{"version":"3.0.21","min_version":"3.0.6","min_app_version":"1.0.74","min_app_version_code":"438","zip_url":"https://github.com/BasedHardware/omi/releases/download/Omi_CV1_v3.0.21/Omi_CV1_OTA_v3.0.21.zip","draft":false,"ota_update_steps":["battery","internet"],"is_legacy_secure_dfu":false,"changelog":["fix audio sync issue"]}"#.utf8)

    @Test func theBackendsAnswerIsReadAndOnlyTheOfficialPackageAccepted() throws {
        let r = try #require(FirmwareRelease(omiAPI: Self.answer))
        #expect(r.version == "3.0.21" && r.changelog == ["fix audio sync issue"] && !r.legacySecureDFU && r.isOfficialCV1Asset)
        #expect(r.blocker(installedOn: FirmwareVersion("3.0.20")) == nil)
        #expect(r.blocker(installedOn: FirmwareVersion("3.0.5")) != nil, "below min_version")
        var elsewhere = r
        elsewhere.zipURL = URL(string: "https://example.com/BasedHardware/omi/releases/download/Omi_CV1_v3.0.21/x.zip")!
        #expect(elsewhere.blocker(installedOn: nil) == "its download isn't the official Omi release")
        var otherVersion = r
        otherVersion.version = "3.0.22"
        #expect(!otherVersion.isOfficialCV1Asset, "the package must be the release of exactly that version")
        var legacy = r
        legacy.legacySecureDFU = true
        #expect(legacy.blocker(installedOn: nil) != nil)
        #expect(FirmwareRelease(omiAPI: Data(#"{"detail":"No suitable firmware update found for your device version."}"#.utf8)) == nil)
        let url = FirmwareRelease.latestURL(model: "Omi CV 1", firmware: "3.0.21", hardware: "5.0", manufacturer: "Based Hardware")
        #expect(url.absoluteString == "https://api.omi.me/v2/firmware/latest?device_model=Omi%20CV%201&firmware_revision=3.0.21&hardware_revision=5.0&manufacturer_name=Based%20Hardware")
    }
}

@Suite struct FirmwarePackageTests {
    @Test func aValidPackageHasBothCoresWithTheirHashes() throws {
        let p = try FirmwarePackage(zip: FirmwareFixture.package())
        #expect(p.images.map(\.index) == [0, 1])
        #expect(p.images[0].image.hash.count == 32 && p.images[0].image.headerVersion == "0.0.0+0")
    }

    @Test func damagedForeignOrIncompletePackagesAreRefused() {
        var tampered = FirmwareFixture.image(seed: 1)
        tampered[100] ^= 0xff
        #expect(throws: FirmwarePackageError.invalidImage("SHA-256 doesn't match")) {
            try FirmwarePackage(zip: FirmwareFixture.package(app: tampered))
        }
        #expect(throws: FirmwarePackageError.wrongDevice("not signed for the CV1 bootloader")) {
            try FirmwarePackage(zip: FirmwareFixture.package(app: FirmwareFixture.image(keyHash: Data(repeating: 1, count: 32))))
        }
        #expect(throws: FirmwarePackageError.wrongDevice("omi_devkit for image 0")) {
            try FirmwarePackage(zip: FirmwareFixture.package(appBoard: "omi_devkit"))
        }
        let onlyApp = FirmwareFixture.zip([
            ("manifest.json", Data(#"{"files":[{"board":"omi","soc":"nrf5340","image_index":"0","file":"a.bin"}]}"#.utf8)),
            ("a.bin", FirmwareFixture.image()),
        ])
        #expect(throws: FirmwarePackageError.invalidManifest("expected the application and network core images")) {
            try FirmwarePackage(zip: onlyApp)
        }
        var badZip = FirmwareFixture.package()
        badZip[200] ^= 0x55  // inside a stored entry: its CRC no longer matches
        #expect(throws: (any Error).self) { try FirmwarePackage(zip: badZip) }
    }

    /// The published 3.0.21 package, when downloaded locally (not part of the hermetic suite).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMI_REAL_OTA_ZIP"] != nil))
    func thePublishedPackageParses() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMI_REAL_OTA_ZIP"]!))
        let p = try FirmwarePackage(zip: data)
        #expect(p.images.map { $0.image.data.count } == [248_644, 175_092])
        print("REAL-OTA images \(p.images.map { "\($0.index): \($0.image.data.count) B hash \($0.image.hash.prefix(8).map { String(format: "%02x", $0) }.joined())" })")
    }
}

@Suite struct SMPTests {
    @Test func cborRoundTripsAndReadsIndefiniteMaps() {
        let v = CBOR.map([("off", .uint(65_536)), ("data", .bytes(Data([1, 2]))), ("rc", .nint(-3)), ("ok", .bool(true))])
        #expect(CBOR.decode(v.encoded()) == v)
        // zcbor's indefinite-length response {"rc": 0, "off": 512}
        let indefinite = Data([0xbf, 0x62, 0x72, 0x63, 0x00, 0x63, 0x6f, 0x66, 0x66, 0x19, 0x02, 0x00, 0xff])
        #expect(CBOR.decode(indefinite)?["off"]?.int == 512)
    }

    @Test func uploadsFitOneWriteAndResponsesAreReassembled() throws {
        let sha = Data(repeating: 9, count: 32)
        #expect(SMPMessage.chunkSize(image: 1, offset: 0, total: 175_092, sha: sha, maximumWrite: 20) == 0, "too small: refused, not overflowed")
        for maximumWrite in [244, 100] {
            for offset in [0, 70_000] {
                let n = SMPMessage.chunkSize(image: 1, offset: offset, total: 175_092, sha: sha, maximumWrite: maximumWrite)
                let m = SMPMessage.upload(image: 1, offset: offset, chunk: Data(count: n), total: 175_092, sha: sha, sequence: 3)
                #expect(m.encoded().count <= maximumWrite && n > 0)
            }
        }
        let first = SMPMessage.upload(image: 1, offset: 0, chunk: Data([7]), total: 10, sha: sha, sequence: 4)
        let decoded = try #require(SMPMessage.decode(first.encoded()))
        #expect(decoded.group == 1 && decoded.id == 1 && decoded.sequence == 4 && decoded.body["image"]?.int == 1 && decoded.body["len"]?.int == 10)
        #expect(SMPMessage.upload(image: 1, offset: 5, chunk: Data([7]), total: 10, sha: sha, sequence: 5).body["sha"] == nil)

        let state = SMPMessage(op: .readResponse, group: 1, id: 0, sequence: 9, body: .map([("images", .array([
            .map([("image", .uint(0)), ("slot", .uint(1)), ("hash", .bytes(Data(repeating: 0xab, count: 32))), ("pending", .bool(true))]),
        ]))])).encoded()
        var assembler = SMPAssembler()
        let part1 = assembler.append(state.prefix(5)), part2 = assembler.append(state.dropFirst(5).prefix(20))
        #expect(part1 == nil && part2 == nil)
        let last = assembler.append(state.dropFirst(25))
        let whole = try #require(last)
        #expect(SMPImageSlot.parse(whole.body) == [SMPImageSlot(image: 0, slot: 1, hash: Data(repeating: 0xab, count: 32), pending: true, confirmed: false, active: false)])
        #expect(SMPMessage(op: .writeResponse, group: 1, id: 1, sequence: 1, body: .map([("err", .map([("group", .uint(1)), ("rc", .uint(6))]))])).rc == 6)
    }
}
