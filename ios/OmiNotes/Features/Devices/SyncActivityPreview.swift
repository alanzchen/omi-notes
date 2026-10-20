#if DEBUG
import OmiProtocol
import SwiftUI

/// Simulator screenshots only (debug builds): `-OmiNotesDebugLiveActivityPreview 1` renders the Live
/// Activity's own views (Shared/SyncActivityViews.swift) with SYNTHETIC states. It is an in-app render
/// of those views, not the system Lock Screen or Dynamic Island.
struct SyncActivityPreviewGallery: View {
    static var requested: Bool { UserDefaults.standard.bool(forKey: "OmiNotesDebugLiveActivityPreview") }

    private let now = Date()
    private var states: [(String, SyncActivityState, Bool)] {
        [("Sending (fresh)", SyncActivityState(stage: .sending, title: "Sending to your server", rate: 1_240_000, queuedAudioSeconds: 2_170,
                                               queuedFiles: 38, batchSent: 3_900_000, batchTotal: 8_100_000, watchWaitingSeconds: 230,
                                               watchReportAt: now.addingTimeInterval(-120), asOf: now), false),
         ("Sending, gone stale", SyncActivityState(stage: .sending, title: "Sending to your server", rate: 1_240_000, queuedAudioSeconds: 2_170,
                                                   queuedFiles: 38, asOf: now.addingTimeInterval(-600)), true),
         ("Offline", SyncActivityState(stage: .offline, title: "Can't reach your server", detail: "timed out", queuedAudioSeconds: 2_170,
                                       queuedFiles: 38, asOf: now), false),
         ("Some lengths unknown", SyncActivityState(stage: .waiting, title: "Waiting to send", queuedAudioSeconds: 600, queuedAudioPartial: true,
                                                    queuedFiles: 12, asOf: now), false),
         ("All sent", SyncActivityState(stage: .allSent, title: "Everything has reached your server", detail: "Your server is processing 2",
                                        queuedAudioSeconds: 0, queuedFiles: 0, asOf: now), false)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("IN-APP RENDER OF THE LIVE ACTIVITY VIEWS · SYNTHETIC · NOT THE SYSTEM LOCK SCREEN")
                    .font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(.orange)
                ForEach(states, id: \.0) { name, s, stale in
                    Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    SyncLockScreenView(state: s, stale: stale)
                        .background(SyncPalette.background, in: .rect(cornerRadius: 22))
                }
                Text("Expanded island (bottom region), on black").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SyncLines(state: states[0].1, stale: false, compact: true)
                    .padding(14).background(.black, in: .rect(cornerRadius: 30)).environment(\.colorScheme, .dark)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }
}
#endif
