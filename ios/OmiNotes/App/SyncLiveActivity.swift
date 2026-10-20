import ActivityKit
import OmiBLE
import OmiProtocol
import SwiftUI

/// ActivityKit behind `SyncActivityController` (OmiKit holds the lifecycle and its tests).
@MainActor
final class ActivityKitSyncHost: SyncActivityHost {
    var onEnded: ((String, Bool) -> Void)?

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func existing() -> [String] {
        let live = Activity<SyncActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        live.forEach(observe)
        return live.map(\.id)
    }

    func start(_ state: SyncActivityState, staleDate: Date) throws -> String {
        let a = try Activity.request(attributes: SyncActivityAttributes(), content: .init(state: state, staleDate: staleDate), pushType: nil)
        observe(a)
        return a.id
    }

    func update(_ id: String, _ state: SyncActivityState, staleDate: Date) {
        Task.detached { await Self.push(id, state, staleDate: staleDate) }
    }

    func end(_ id: String, final: SyncActivityState?) {
        Task.detached { await Self.finish(id, final) }
    }

    nonisolated private static func find(_ id: String) -> Activity<SyncActivityAttributes>? {
        Activity<SyncActivityAttributes>.activities.first { $0.id == id }
    }

    nonisolated private static func push(_ id: String, _ state: SyncActivityState, staleDate: Date) async {
        await find(id)?.update(.init(state: state, staleDate: staleDate))
    }

    nonisolated private static func finish(_ id: String, _ final: SyncActivityState?) async {
        await find(id)?.end(final.map { .init(state: $0, staleDate: nil) }, dismissalPolicy: final == nil ? .immediate : .default)
    }

    /// Removed from the Lock Screen by the user (`dismissed`) vs. ended by the system or by us.
    private func observe(_ a: Activity<SyncActivityAttributes>) {
        let id = a.id
        Task { [weak self] in
            for await state in a.activityStateUpdates {
                switch state {
                case .dismissed: self?.onEnded?(id, true)
                case .ended: self?.onEnded?(id, false)
                default: break
                }
            }
        }
    }
}

/// Keeps the one sync Live Activity in step with the transfer state while the app runs. It only
/// presents: it never starts, stops or keeps alive an upload.
@MainActor
final class SyncActivityCoordinator {
    static let optOutKey = "omi.syncLiveActivityOff"
    private let host = ActivityKitSyncHost()
    private let controller: SyncActivityController

    init() {
        controller = SyncActivityController(host: host)
        host.onEnded = { [weak self] id, byUser in self?.controller.ended(id, byUser: byUser) }
        controller.adopt()  // after a relaunch: the one that exists, never a second
    }

    func refresh(_ model: AppModel, foreground: Bool) {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "OmiNotesDebugLiveActivity") {
            startDebugFixture(name)
            return
        }
        #endif
        let summary = model.transfers(watchInstalled: DevicesView.watchAppInstalled)
        controller.refresh(SyncActivityState(summary, now: Date()), foreground: foreground,
                           optedOut: UserDefaults.standard.bool(forKey: Self.optOutKey), now: Date())
    }

    #if DEBUG
    private var debugStarted = false

    /// Simulator screenshots only (debug builds): `-OmiNotesDebugLiveActivity sending|stale|offline|kept-aside|unknown-length`
    /// starts one SYNTHETIC activity (its detail line says so). "stale" goes stale after a few seconds.
    private func startDebugFixture(_ name: String) {
        guard !debugStarted, host.enabled else { return }
        let now = Date()
        var s = SyncActivityState(stage: .sending, title: "Sending to your server", detail: "Synthetic preview", rate: 1_240_000,
                                  queuedAudioSeconds: 2_170, queuedFiles: 38, batchSent: 3_900_000, batchTotal: 8_100_000,
                                  watchWaitingSeconds: 230, watchReportAt: now.addingTimeInterval(-120), serverPending: 1, asOf: now)
        var stale = now.addingTimeInterval(600)
        switch name {
        case "sending": break
        case "stale": stale = now.addingTimeInterval(4)
        case "offline":
            s = SyncActivityState(stage: .offline, title: "Can't reach your server", detail: "Synthetic preview · timed out",
                                  queuedAudioSeconds: 2_170, queuedFiles: 38, watchWaitingSeconds: 230, watchReportAt: now.addingTimeInterval(-120), asOf: now)
        case "kept-aside":
            s = SyncActivityState(stage: .keptAside, title: "Files kept aside on this iPhone", detail: "Synthetic preview · 1 not uploaded; see Devices",
                                  queuedAudioSeconds: 0, queuedFiles: 0, asOf: now)
        case "unknown-length":
            s = SyncActivityState(stage: .waiting, title: "Waiting to send", detail: "Synthetic preview", queuedAudioSeconds: 600,
                                  queuedAudioPartial: true, queuedFiles: 12, asOf: now)
        default: return
        }
        debugStarted = (try? host.start(s, staleDate: stale)) != nil
    }
    #endif
}
