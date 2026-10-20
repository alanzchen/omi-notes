import ActivityKit
import OmiProtocol
import SwiftUI
import WidgetKit

/// The sync Live Activity on the Lock Screen and in the Dynamic Island. It shows only what the app
/// last knew (`SyncActivityState`): a rate only while bytes were moving, durations from the
/// recordings' own lengths, and "as of" once the system marks it stale (the app isn't running).
@main
struct OmiNotesLiveActivityBundle: WidgetBundle {
    var body: some Widget { SyncLiveActivity() }
}

struct SyncLiveActivity: Widget {
    static let transfersURL = URL(string: "omi-notes://transfers")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            SyncLockScreenView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(SyncPalette.background)
                .activitySystemActionForegroundColor(SyncPalette.ink)
                .widgetURL(Self.transfersURL)
        } dynamicIsland: { context in
            let s = context.state, stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text(SyncWords.shortStage(s)).font(.caption.weight(.semibold)) } icon: { SyncStageIcon(stage: s.stage) }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(SyncWords.trailing(s, stale: stale)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SyncLines(state: s, stale: stale, compact: true).dynamicTypeSize(...DynamicTypeSize.xxLarge)
                }
            } compactLeading: {
                SyncStageIcon(stage: s.stage)
            } compactTrailing: {
                Text(SyncWords.compact(s, stale: stale)).font(.caption2.monospacedDigit()).lineLimit(1)
            } minimal: {
                SyncStageIcon(stage: s.stage)
            }
            .widgetURL(Self.transfersURL)
        }
    }
}
