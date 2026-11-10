import Foundation
import Testing

/// Build 44's Watch app crashed at launch: `WatchSync.syncPing` (a `@MainActor` class) passed plain closures as
/// `WCSession.sendMessage`'s reply and error handlers. WatchConnectivity's header marks neither `@Sendable`, so
/// in Swift 6 they inherited the main actor, and their runtime isolation check trapped when WatchConnectivity
/// called them on its own queue, seconds after launch whenever parts waited and the iPhone was reachable.
/// The Watch app can't be loaded by these tests, so its source is checked: every such handler is `@Sendable`
/// (it then hops to the main actor itself, through `onMain`).
@Suite struct WatchCallbackIsolationTests {
    static let watchSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // OmiKit
        .deletingLastPathComponent().deletingLastPathComponent()  // ios
        .appendingPathComponent("OmiNotesWatch")

    @Test func watchConnectivityHandlersInTheWatchAppAreSendable() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.watchSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the Watch app's sources are where this test expects them")
        var offenders: [String] = []
        for file in files {
            for (n, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                for handler in ["replyHandler: {", "errorHandler: {"] where line.contains(handler) {
                    let after = line.components(separatedBy: handler).dropFirst().joined()
                    if !after.trimmingCharacters(in: .whitespaces).hasPrefix("@Sendable") {
                        offenders.append("\(file.lastPathComponent):\(n + 1)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "handlers WatchConnectivity calls off the main actor must be @Sendable: \(offenders)")
    }
}
