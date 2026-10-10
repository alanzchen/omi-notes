import Foundation
import Testing
@testable import OmiProtocol

@Suite struct PendantSettingsTests {
    @Test func settingsAreOneByteClampedAndReadBackOnlyInRange() {
        #expect(PendantSetting.ledBrightness.encode(30) == Data([30]))
        #expect(PendantSetting.ledBrightness.encode(140) == Data([100]))
        #expect(PendantSetting.micGain.encode(-1) == Data([0]))
        #expect(PendantSetting.micGain.encode(12) == Data([8]))
        #expect(PendantSetting.micGain.decode(Data([6])) == 6)
        #expect(PendantSetting.micGain.decode(Data([9])) == nil, "out of range is not a reading")
        #expect(PendantSetting.ledBrightness.decode(Data()) == nil)
        #expect(MicGainLevel.label(0) == "Muted" && MicGainLevel.label(6) == "+20 dB" && MicGainLevel.label(8) == "+40 dB")
        #expect(HapticPulse.long.payload == Data([3]))
    }

    @Test func featureBitsAndCharacteristicsMatchTheFirmware() {
        let cv1 = DeviceFeatures(rawValue: 0x1EC)  // button, battery, haptic, offline storage, LED, mic gain
        #expect(cv1.haptic && cv1.offlineStorage && cv1.ledDimming && cv1.micGain)
        let old = DeviceFeatures(rawValue: 0x4C)
        #expect(!old.haptic && !old.ledDimming && !old.micGain)
        #expect(OmiCharacteristic.find(service: "19b10010-e8f2-537e-4f6c-d104768a1214",
                                       characteristic: "19B10011-E8F2-537E-4F6C-D104768A1214") == .ledDimRatio)
        #expect(OmiCharacteristic.find(service: OmiUUID.settingsService, characteristic: OmiUUID.micGain) == .micGain)
        #expect(OmiCharacteristic.find(service: "cab1ab95-2ea5-4f4d-bb56-874b72cfc984",
                                       characteristic: "cab1ab96-2ea5-4f4d-bb56-874b72cfc984") == .haptic)
        #expect(OmiCharacteristic.serviceUUIDs.first == OmiUUID.audioService, "audio is still discovered first")
        #expect(OmiCharacteristic.serviceUUIDs.contains(OmiUUID.hapticService))
    }
}
