import Foundation
import Testing
@testable import OmiBLE

/// ASTRA-20261116-IT4-02: the phone's install id is made on first read. Two first reads at once (the engine's queue
/// and a WatchConnectivity callback) could each make and save a different id, and a Watch part bound to the one
/// that lost was refused as another iPhone's.
@Suite struct InstallIdTests {
    @Test func concurrentFirstReadsAgreeOnOneId() {
        var split = 0
        for _ in 0..<200 {
            let defaults = UserDefaults(suiteName: "omi-install-\(UUID().uuidString)")!
            // two stores over the same defaults, as the app and an extension or a second engine could be
            let stores = [SettingsStore(defaults: defaults, tokens: InMemoryTokenStore()), SettingsStore(defaults: defaults, tokens: InMemoryTokenStore())]
            let seen = IdSet<Set<String>>([])
            DispatchQueue.concurrentPerform(iterations: 8) { i in
                if let id = stores[i % 2].phoneInstallId { seen.withLock { _ = $0.insert(id) } }
            }
            let ids = seen.withLock { $0 }
            if ids.count != 1 || defaults.string(forKey: "omi.phoneInstallId") != ids.first { split += 1 }
        }
        #expect(split == 0, "\(split) of 200 first reads made more than one id")
    }

    @Test func aStoredIdIsKept() {
        let defaults = UserDefaults(suiteName: "omi-install-\(UUID().uuidString)")!
        defaults.set("existing-id", forKey: "omi.phoneInstallId")
        #expect(SettingsStore(defaults: defaults, tokens: InMemoryTokenStore()).phoneInstallId == "existing-id")
    }
}

private final class IdSet<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}
