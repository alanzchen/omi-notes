import ActivityKit
import OmiBLE
import OmiProtocol
import SwiftUI

/// ActivityKit behind `SyncActivityController` (OmiKit holds the lifecycle and its tests). Updates and
/// ends run one after another (`OrderedActivityOperations`), so a slow SDK call never lands after a
/// newer one or after the end.
@MainActor
final class ActivityKitSyncHost: SyncActivityHost {
    var onEnded: ((String, Bool) -> Void)?
    private let operations = OrderedActivityOperations(
        send: { id, state, staleDate in await ActivityKitSyncHost.push(id, state, staleDate: staleDate) },
        finish: { id, final, ending in await ActivityKitSyncHost.finish(id, final, ending) })

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Running (active or stale) and ended-but-shown cards; dismissed ones are gone.
    func existing() -> [(id: String, running: Bool)] {
        let shown = Activity<SyncActivityAttributes>.activities.filter { $0.activityState != .dismissed }
        shown.forEach(observe)
        return shown.map { ($0.id, $0.activityState == .active || $0.activityState == .stale) }
    }

    func start(_ state: SyncActivityState, staleDate: Date) throws -> String {
        let a = try Activity.request(attributes: SyncActivityAttributes(), content: .init(state: state, staleDate: staleDate), pushType: nil)
        observe(a)
        return a.id
    }

    func update(_ id: String, _ state: SyncActivityState, staleDate: Date) {
        operations.update(id, state, staleDate: staleDate)
    }

    func end(_ id: String, final: SyncActivityState?, ending: SyncActivityEnding) {
        operations.end(id, final: final, ending: ending)
    }

    nonisolated private static func find(_ id: String) -> Activity<SyncActivityAttributes>? {
        Activity<SyncActivityAttributes>.activities.first { $0.id == id }
    }

    nonisolated private static func push(_ id: String, _ state: SyncActivityState, staleDate: Date) async {
        await find(id)?.update(.init(state: state, staleDate: staleDate))
    }

    nonisolated private static func finish(_ id: String, _ final: SyncActivityState?, _ ending: SyncActivityEnding) async {
        let policy: ActivityUIDismissalPolicy
        switch ending {
        case .immediate: policy = .immediate
        case .after(let date): policy = .after(date)
        }
        await find(id)?.end(final.map { .init(state: $0, staleDate: nil) }, dismissalPolicy: policy)
    }

    /// `.dismissed` (removed by the person or by the system; ActivityKit doesn't say which) vs. ended.
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

/// A dismissal holds until a sync is confirmed finished, across relaunches.
@MainActor
final class DefaultsSyncActivityMemory: SyncActivityMemory {
    static let key = "omi.syncLiveActivityDismissed"
    var dismissed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }
}

/// Keeps the one sync Live Activity in step with the transfer state while the app runs. It only
/// presents: it never starts, stops or keeps alive an upload. In the foreground it looks again at
/// the controller's next check (a shown rate, a renewal); in the background it does nothing.
@MainActor
final class SyncActivityCoordinator {
    static let optOutKey = "omi.syncLiveActivityOff"
    private let host = ActivityKitSyncHost()
    private let controller: SyncActivityController
    private weak var model: AppModel?
    private var foreground = false
    private var recheck: Task<Void, Never>?

    init() {
        controller = SyncActivityController(host: host, memory: DefaultsSyncActivityMemory())
        host.onEnded = { [weak self] id, dismissed in self?.controller.ended(id, dismissed: dismissed) }
        controller.adopt()  // after a relaunch: the one that exists, never a second
    }

    func refresh(_ model: AppModel, foreground: Bool) {
        self.model = model
        self.foreground = foreground
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "OmiNotesDebugLiveActivity") {
            startDebugFixture(name)
            return
        }
        #endif
        let now = Date()
        // nothing decided before the engine's first snapshot (its placeholder says nothing)
        let state = model.snapshot.ready ? SyncActivityState(model.transfers(watchInstalled: DevicesView.watchAppInstalled, now: now), now: now) : nil
        controller.refresh(state, foreground: foreground, optedOut: UserDefaults.standard.bool(forKey: Self.optOutKey), now: now)
        schedule(now: now)
    }

    /// One pending look at a time, only while in the foreground.
    private func schedule(now: Date) {
        recheck?.cancel()
        recheck = nil
        guard foreground, let at = controller.nextCheck(now: now) else { return }
        let delay = max(1, at.timeIntervalSince(now))
        recheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let model = self.model, self.foreground else { return }
            self.refresh(model, foreground: true)
        }
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
