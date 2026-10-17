import Foundation
import Testing
@testable import OmiBLE
@testable import OmiWatchKit

/// Before the iPhone's first unlock after a restart, the app can be launched in the background and its
/// settings read as empty. That is not a fresh install: the identity the Watch binds its recordings to
/// must not be replaced then, or every part bound to the real one stays held on the Watch.
@Suite struct InstallIdentityTests {
    func store(_ defaults: UserDefaults) -> SettingsStore { SettingsStore(defaults: defaults, tokens: InMemoryTokenStore()) }
    func emptyDefaults() -> UserDefaults { UserDefaults(suiteName: "omi-install-\(UUID().uuidString)")! }

    @Test func beforeTheFirstUnlockNoReplacementIdentityIsMinted() {
        let unreadable = emptyDefaults()  // reads as empty, like settings before the first unlock
        let s = store(unreadable)
        s.unlockedSinceBoot = false
        #expect(s.phoneInstallId == nil, "unknown, not new")
        #expect(unreadable.string(forKey: "omi.phoneInstallId") == nil, "nothing stored over the real one")
        s.unlockedSinceBoot = true  // first unlock: a genuinely missing identity is created once
        let id = s.phoneInstallId
        #expect(id != nil && s.phoneInstallId == id)
    }

    @Test func aStoredIdentityIsUsedWheneverItCanBeRead() {
        let d = emptyDefaults()
        d.set("phone-A", forKey: "omi.phoneInstallId")
        let s = store(d)
        s.unlockedSinceBoot = false
        #expect(s.phoneInstallId == "phone-A")
    }

    @Test func theInboxAcceptsNothingWhileTheIdentityIsUnreadableAndReadsItAgainLater() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-identity-\(UUID().uuidString)")
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let identity = Locked<String?>(nil)
        let inbox = PhoneWatchInbox(root: root.appendingPathComponent("watch"), currentBinding: { identity.value })
        let file = try WatchRelayTests.segmentFile(seconds: 1, in: tmp, name: "s0")
        let m = WatchRelayTests().manifest(file, recording: UUID().uuidString.lowercased(), index: 0, binding: "phone-A", start: 0)
        // not acknowledged (the Watch keeps it and sends it again), and not called another iPhone's
        #expect(throws: WatchRelayError.identityUnreadable) { try inbox.accept(file: file, segment: m) }
        identity.value = "phone-A"  // after the first unlock, without relaunching
        try inbox.accept(file: file, segment: m)
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
