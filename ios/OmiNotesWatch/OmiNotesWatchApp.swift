import CryptoKit
import Foundation
import OmiWatchKit
import SwiftUI

@main
struct OmiNotesWatchApp: App {
    @State private var sync: WatchSync
    @State private var recorder: WatchRecorder
    @Environment(\.scenePhase) private var phase

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("watch-outbox", isDirectory: true)
        let outbox = WatchOutbox(root: root)
        // telemetry is kept apart from audio (its own folder and bound)
        let perf = WatchPerfQueue(root: root.deletingLastPathComponent().appendingPathComponent("watch-telemetry", isDirectory: true))
        let sync = WatchSync(outbox: outbox, perf: perf)
        _sync = State(initialValue: sync)
        _recorder = State(initialValue: WatchRecorder(outbox: outbox, sync: sync, telemetry: WatchTelemetry(queue: perf)))
    }

    var body: some Scene {
        WindowGroup {
            RecordView(recorder: recorder, sync: sync)
                .task {
                    #if DEBUG
                    // Simulator automation only: `-OmiWatchDebugAutoStart YES` presses Start, as a tap would.
                    if UserDefaults.standard.bool(forKey: "OmiWatchDebugAutoStart") {
                        try? await Task.sleep(for: .seconds(3))
                        recorder.start()
                        // `-OmiWatchDebugAutoStopAfter 22` presses Stop after that many seconds.
                        let stopAfter = UserDefaults.standard.double(forKey: "OmiWatchDebugAutoStopAfter")
                        if stopAfter > 0 {
                            try? await Task.sleep(for: .seconds(stopAfter))
                            recorder.stop()
                        }
                    }
                    #endif
                }
        }
        .onChange(of: phase) { _, now in if now == .active { sync.pump() } }
    }
}

enum WatchHash {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
