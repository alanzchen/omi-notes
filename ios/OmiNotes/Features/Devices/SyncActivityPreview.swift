#if DEBUG
import OmiProtocol
import SwiftUI

/// Simulator screenshots only (debug builds): `-OmiNotesDebugLiveActivityPreview 1` renders the Live
/// Activity's own views (Shared/SyncActivityViews.swift) with SYNTHETIC states. It is an in-app render
/// of those views, not the system Lock Screen or Dynamic Island. `-OmiNotesDebugLiveActivityPreview 2` shows
/// the later states and the island (a headless simulator can't scroll).
struct SyncActivityPreviewGallery: View {
    static var requested: Bool { UserDefaults.standard.integer(forKey: "OmiNotesDebugLiveActivityPreview") > 0 }
    private var secondPage: Bool { UserDefaults.standard.integer(forKey: "OmiNotesDebugLiveActivityPreview") == 2 }

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
         ("All lengths unknown", SyncActivityState(stage: .waiting, title: "Waiting to send", queuedFiles: 3, asOf: now), false),
         ("Batch with an unknown size", SyncActivityState(stage: .sending, title: "Sending to your server", rate: 48_000, queuedAudioSeconds: 600,
                                                          queuedFiles: 12, batchSent: 410_000, batchTotal: 410_000, batchUnknownUploads: 1, asOf: now), false),
         ("iPhone sent, Watch still has audio", SyncActivityState(stage: .allSent, title: "This iPhone has sent everything",
                                                                  detail: "Your server is processing 2", queuedAudioSeconds: 0, queuedFiles: 0,
                                                                  watchWaitingSeconds: 230, watchReportAt: now.addingTimeInterval(-120), asOf: now), false),
         ("All sent", SyncActivityState(stage: .allSent, title: "This iPhone has sent everything", detail: "Your server is processing 2",
                                        queuedAudioSeconds: 0, queuedFiles: 0, asOf: now), false)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("IN-APP RENDER OF THE LIVE ACTIVITY VIEWS · SYNTHETIC · NOT THE SYSTEM LOCK SCREEN")
                    .font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(.orange)
                ForEach(secondPage ? Array(states.dropFirst(4)) : Array(states.prefix(4)), id: \.0) { name, s, stale in
                    Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    SyncLockScreenView(state: s, stale: stale)
                        .background(SyncPalette.background, in: .rect(cornerRadius: 22))
                }
                Text("Compact island (trailing), on black").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                    ForEach(states, id: \.0) { _, s, stale in
                        Text(SyncWords.compact(s, stale: stale)).font(.caption2.monospacedDigit()).lineLimit(1).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4).background(.black, in: .capsule)
                    }
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
