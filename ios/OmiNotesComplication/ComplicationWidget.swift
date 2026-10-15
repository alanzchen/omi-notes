import OmiWatchKit
import SwiftUI
import WidgetKit

/// The Omi Notes watch-face complication (circular): recording state and the Watch's queue.
/// It shows what the Watch app last wrote, and turns to "unknown" once that is too old; the app
/// asks for a reload when what the face shows changes (the system decides when it happens).
@main
struct OmiNotesComplicationBundle: WidgetBundle {
    var body: some Widget { OmiNotesStatusWidget() }
}

struct OmiNotesStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationKind.status, provider: StatusProvider()) { entry in
            ComplicationCircle(display: entry.display)
                .widgetURL(ComplicationKind.statusURL)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Omi Notes")
        .description("Recording state, and audio waiting to go to your iPhone.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct StatusEntry: TimelineEntry {
    let date: Date
    let display: ComplicationDisplay
}

struct StatusProvider: TimelineProvider {
    let store = ComplicationStore(accessGroup: ComplicationKind.accessGroup)

    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), display: ComplicationDisplay(main: .idle, sync: .onIPhone))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        // the picker's preview: a plain example, not a claim about this Watch
        if context.isPreview { completion(placeholder(in: context)); return }
        completion(StatusEntry(date: Date(), display: ComplicationDisplay.evaluate(store.load(), now: Date())))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date(), snapshot = store.load()
        var entries = [StatusEntry(date: now, display: ComplicationDisplay.evaluate(snapshot, now: now))]
        // the moment it would go stale, it shows "unknown" without needing a reload
        if let stale = ComplicationDisplay.staleAt(snapshot), stale > now {
            entries.append(StatusEntry(date: stale, display: ComplicationDisplay.evaluate(snapshot, now: stale)))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}
