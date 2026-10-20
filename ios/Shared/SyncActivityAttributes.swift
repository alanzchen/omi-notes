import ActivityKit
import OmiProtocol

/// The sync Live Activity (app and Lock Screen extension). Its content is `SyncActivityState`:
/// counts, durations and stages only, never note titles, transcripts or audio.
struct SyncActivityAttributes: ActivityAttributes {
    typealias ContentState = SyncActivityState
}
