import Foundation
import Testing
@testable import OmiProtocol

@Suite struct CRC32Tests {
    @Test func knownVectors() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
        #expect(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    @Test func incrementalEqualsWhole() {
        let a = Data("12345".utf8), b = Data("6789".utf8)
        #expect(CRC32.checksum(b, seed: CRC32.checksum(a)) == 0xCBF4_3926)
    }
}

@Suite struct AudioPacketTests {
    @Test func headerParse() throws {
        let h = try #require(AudioPacketHeader(Data([0x34, 0x12, 0x02, 0xAA, 0xBB])))
        #expect(h.sequence == 0x1234)
        #expect(h.fragmentIndex == 2)
        #expect(h.payloadLength == 2)
        #expect(AudioPacketHeader(Data([1, 2])) == nil)
    }

    @Test func lossTrackerGapsWrapAndDuplicates() {
        var t = SequenceLossTracker()
        for s: UInt16 in [65533, 65534, 65535, 0, 1] { t.record(s) }  // wrap: no loss
        #expect(t.lost == 0)
        #expect(t.received == 5)
        t.record(1)  // duplicate
        #expect(t.duplicates == 1)
        t.record(5)  // 2, 3, 4 lost
        #expect(t.lost == 3)
        t.record(65534)  // gap across the wrap is huge → treated as restart, not loss
        #expect(t.lost == 3)
        #expect(abs(t.lossPercent - 3.0 * 100 / 10) < 0.001)
    }

    @Test func lossAcrossWrap() {
        var t = SequenceLossTracker()
        t.record(65534)
        t.record(1)  // 65535 and 0 lost
        #expect(t.lost == 2)
    }
}

@Suite struct ButtonTests {
    @Test func decodesCV1Payloads() {
        #expect(ButtonEvent.decode(Data([1, 0, 0, 0, 0, 0, 0, 0])) == .singleTap)
        #expect(ButtonEvent.decode(Data([2, 0, 0, 0, 0, 0, 0, 0])) == .doubleTap)
        #expect(ButtonEvent.decode(Data([5, 0, 0, 0, 0, 0, 0, 0])) == .release)
        #expect(ButtonEvent.decode(Data([3, 0, 0, 0])) == .longTap)
        #expect(ButtonEvent.decode(Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0])) == .unknown(-1))
        #expect(ButtonEvent.decode(Data([1, 0, 0])) == nil)
    }

    @Test func uploadCodes() {
        #expect(ButtonEvent.singleTap.uploadCode == 1)
        #expect(ButtonEvent.doubleTap.uploadCode == 2)
        #expect(ButtonEvent.release.uploadCode == nil)
        #expect(ButtonEvent.press.uploadCode == nil)
    }
}

@Suite struct FirmwareVersionTests {
    @Test func parsingAndOrdering() throws {
        let v21 = try #require(FirmwareVersion("3.0.21"))
        let v20 = try #require(FirmwareVersion("v3.0.20"))
        #expect(v21 > v20)
        #expect(FirmwareVersion("3.0.20.0") == FirmwareVersion("3.0.20"))
        #expect(try #require(FirmwareVersion("3.0.19")) < FirmwareVersion.ringProtocolMinimum)
        #expect(try #require(FirmwareVersion("3.1")) > FirmwareVersion("3.0.25")!)
        #expect(FirmwareVersion("3.0.20-rc1") == FirmwareVersion("3.0.20"))
        #expect(try #require(FirmwareVersion("2.9.99")) < v20)
        #expect(FirmwareVersion("10.0.0")! > FirmwareVersion("9.9.9")!)
        #expect(FirmwareVersion("abc") == nil)
        #expect(FirmwareVersion("") == nil)
        #expect(FirmwareVersion(nil) == nil)
    }

    @Test func offlineStorageStaticCheck() {
        let cv1 = DeviceFeatures(rawValue: 0x1EC)
        #expect(cv1.offlineStorage)
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: true, firmwareRevision: "3.0.21", features: cv1, hasFeaturesCharacteristic: true) == .supported)
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: true, firmwareRevision: "3.0.21", features: nil, hasFeaturesCharacteristic: false) == .supported)
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: true, firmwareRevision: "3.0.19", features: cv1, hasFeaturesCharacteristic: true).headerValue == false)
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: true, firmwareRevision: "3.0.21", features: DeviceFeatures(rawValue: 0x1AC), hasFeaturesCharacteristic: true).headerValue == false)
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: false, firmwareRevision: "3.0.21", features: cv1, hasFeaturesCharacteristic: true).headerValue == false)
        #expect(OfflineStorageSupport.unknown.headerValue == nil)
    }

    /// Review #6: transient read failures must not claim "no offline storage".
    @Test func unreadableMetadataIsUnknownNotUnsupported() {
        let cv1 = DeviceFeatures(rawValue: 0x1EC)
        // Firmware read failed / unparseable → unknown (null), never false.
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: true, firmwareRevision: nil, features: cv1, hasFeaturesCharacteristic: true) == .unknown)
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: true, firmwareRevision: "garbage", features: cv1, hasFeaturesCharacteristic: true) == .unknown)
        // Features characteristic exists but the read failed → unknown.
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: true, firmwareRevision: "3.0.21", features: nil, hasFeaturesCharacteristic: true) == .unknown)
        // Affirmative evidence still wins even when other metadata is missing.
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: true, firmwareRevision: "3.0.19", features: nil, hasFeaturesCharacteristic: true).headerValue == false)
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: false, firmwareRevision: nil, features: DeviceFeatures(rawValue: 0), hasFeaturesCharacteristic: true).headerValue == false)
        #expect(OfflineStorageSupport.staticCheck(hasStorageService: false, firmwareRevision: nil, features: nil, hasFeaturesCharacteristic: false) == .unknown)
    }
}

@Suite struct CodecTests {
    @Test func onlyOpus20And21() {
        #expect(OmiCodec.evaluate(Data([21])) == .supported(.opus20ms))
        #expect(OmiCodec.evaluate(Data([20, 99])) == .supported(.opus10ms))
        #expect(OmiCodec.evaluate(Data([1])) == .unsupported(id: 1))
        #expect(OmiCodec.evaluate(Data([0])) == .unsupported(id: 0))
        #expect(OmiCodec.evaluate(Data()) == .unreadable)
        #expect(OmiCodec.evaluate(nil) == .unreadable)
    }
}

@Suite struct GATTTests {
    @Test func uuidLookupAndNormalization() {
        #expect(OmiCharacteristic.find(service: "19B10000-E8F2-537E-4F6C-D104768A1214", characteristic: "19B10001-E8F2-537E-4F6C-D104768A1214") == .audioData)
        #expect(OmiCharacteristic.find(service: "180F", characteristic: "2A19") == .batteryLevel)
        #expect(OmiCharacteristic.find(service: "0000180f-0000-1000-8000-00805f9b34fb", characteristic: "00002a19-0000-1000-8000-00805f9b34fb") == .batteryLevel)
        #expect(OmiCharacteristic.find(service: OmiUUID.storageService, characteristic: OmiUUID.storageStatus) == .storageStatus)
        #expect(OmiCharacteristic.find(service: "180F", characteristic: "2A24") == nil)
    }

    @Test func scanFilter() {
        #expect(DeviceScanFilter.isCandidate(name: "Omi", advertisedServices: []))
        #expect(DeviceScanFilter.isCandidate(name: nil, advertisedServices: [OmiUUID.audioService.uppercased()]))
        #expect(DeviceScanFilter.isCandidate(name: "Omi DevKit 2", advertisedServices: []))
        #expect(!DeviceScanFilter.isCandidate(name: "OmiGlass", advertisedServices: [OmiUUID.audioService]))
        #expect(!DeviceScanFilter.isCandidate(name: "AirPods", advertisedServices: []))
    }
}

@Suite struct ISOTests {
    @Test func formatsUTCWithMillis() {
        let d = Date(timeIntervalSince1970: 1_790_451_125.123_9)
        #expect(ISO8601UTC.format(d) == "2026-09-26T19:32:05.123Z")
        #expect(ISO8601UTC.format(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
        #expect(ISO8601UTC.parse("2026-09-26T19:32:05.123Z")!.timeIntervalSince1970 == 1_790_451_125.123)
    }
}
