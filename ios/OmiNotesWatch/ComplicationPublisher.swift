import Foundation
import OmiWatchKit
import WidgetKit

/// Keeps the complication's snapshot current: written when what the face shows changes (recorder
/// state, waiting/none, pairing) and, while recording, at most every 15 min so the face doesn't
/// call an old recording live. Each write asks WidgetKit to reload; the system decides when (and
/// whether, within its budget) the face updates.
@MainActor
final class ComplicationPublisher {
    private let store = ComplicationStore(accessGroup: ComplicationKind.accessGroup)
    private var last: ComplicationSnapshot?

    func update(recorder: ComplicationSnapshot.Recorder, waitingParts: Int, bound: Bool) {
        let next = ComplicationSnapshot(at: Date(), recorder: recorder, waitingParts: waitingParts, bound: bound)
        guard ComplicationPublishPolicy.shouldWrite(last: last, next: next) else { return }
        last = next
        let status = store.save(next)
        if status != errSecSuccess { watchLog.error("complication snapshot not saved (\(status))") }
        WidgetCenter.shared.reloadTimelines(ofKind: ComplicationKind.status)
    }
}
