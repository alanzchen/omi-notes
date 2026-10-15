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

    @ViewBuilder private var root: some View {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "OmiWatchDebugComplicationGallery") != nil {
            ComplicationGallery()
        } else {
            RecordView(recorder: recorder, sync: sync)
        }
        #else
        RecordView(recorder: recorder, sync: sync)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            root
                // from the complication: the status screen is the app's only screen; nothing is
                // started or stopped by opening it
                .onOpenURL { url in
                    watchLog.info("opened from \(url.absoluteString)")
                    sync.pump()
                }
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
        .onChange(of: phase) { _, now in
            if now == .active {
                sync.pump()
                recorder.noteOpened()
            }
        }
    }
}

enum WatchHash {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
