import Foundation
import Testing
@testable import OmiBLE
import OmiProtocol

/// ASTRA-20261121-IT3-03: a badly shaped optional "disk" member made the whole status undecodable, so a healthy server
/// looked unreachable. The member is decoded tolerantly: a bad shape is unknown, never a failed status.
@Suite struct StatusDiskDecodeTests {
    @Test func aBadDiskMemberDoesNotFailTheStatus() throws {
        for json in [#"{"ok":true,"disk":{"full":true,"since":{"bad":"type"}}}"#, #"{"ok":true,"disk":"full"}"#,
                     #"{"ok":true,"disk":{"full":"yes"}}"#, #"{"ok":true,"disk":[1]}"#] {
            let status = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
            #expect(status.ok == true, "\(json)")
        }
        let good = try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"ok":true,"disk":{"full":true,"since":"2026-11-21T00:00:00Z"}}"#.utf8))
        #expect(good.disk?.full == true && good.disk?.since == "2026-11-21T00:00:00Z")
        let badSince = try JSONDecoder().decode(ServerStatus.self, from: Data(#"{"ok":true,"disk":{"full":true,"since":{"bad":"type"}}}"#.utf8))
        #expect(badSince.disk?.full == true && badSince.disk?.since == nil)
    }
}
