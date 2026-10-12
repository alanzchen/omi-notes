import OmiBLE
import OmiCapture
import OmiProtocol
import UIKit

/// Creates the engine (and with it the `CBCentralManager` carrying the restore identifier)
/// synchronously in `didFinishLaunching`, because iOS may relaunch the app straight into the
/// background for a Bluetooth event or a finished upload.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private(set) var model: AppModel!
    private var watchBridge: PhoneWatchBridge?
    private var backgroundTasks: UIKitBackgroundTasks!
    private let alerts = LocalAlerts()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        backgroundTasks = UIKitBackgroundTasks(application: application)
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let trace = Bundle.main.url(forResource: "simulated_trace", withExtension: "omitrace")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(SimulatedTrace.parse)
        let config = EngineConfiguration(
            dirs: .appDefault(), appVersion: "\(bundleVersion) (\(build))", timezone: TimeZone.current.identifier,
            simulatedTrace: trace)
        let engine = OmiEngine(config: config, settings: SettingsStore(), background: backgroundTasks)
        model = AppModel(engine: engine)
        watchBridge = PhoneWatchBridge(engine: engine)
        model.problemAlerts.sink = alerts
        #if DEBUG
        // Simulator automation only (debug builds): `-OmiNotesDebugServerURL <url> -OmiNotesDebugToken <token>`.
        if let raw = UserDefaults.standard.string(forKey: "OmiNotesDebugServerURL"),
           let token = UserDefaults.standard.string(forKey: "OmiNotesDebugToken"),
           let url = ServerURLPolicy.evaluate(raw).url {
            do { try engine.configureServer(url: url, token: token) } catch {
                OmiLog.shared.log(.error, "app", "debug server configuration failed: \(error)")
            }
        }
        // `-OmiNotesDebugServerIssues YES` shows a synthetic server answer with two failed conversations
        // shaped like the live server's speakers_unknown issues (screenshots of the Server tab).
        if UserDefaults.standard.bool(forKey: "OmiNotesDebugServerIssues") {
            let status = #"{"ok":true,"vault_id":"fixture-vault","features":["issues","retry","keep","conversation_detail","search","stats"],"queue":{"chunks_pending":0,"conversations_open":0,"conversations_pending":0,"failed":2,"conversations_failed":2,"chunks_failed":0,"conversations_retrying":0,"notes_conflicted":0},"worker":{"present":true},"stt":{"provider":"fixture","ready":true},"llm":{"provider":"fixture","ready":true},"last_note_at":"2026-10-09T14:00:00.000Z"}"#
            let message = "Words were transcribed, but local speaker separation found no distinct speaker, so no note was made. The audio and the automated text are kept on the server."
            func issue(_ id: String, _ at: String) -> String {
                #"{"code":"conversation_failed","severity":"action","message":"\#(message)","next_step":"You can keep it as a transcript with the speaker unknown. A retry would give the same result.","server_step":"Nothing is lost. The phone can keep it as a transcript with the speaker unknown; if speaker separation on the server changes, then retry on the server with `omi-notes retry-failed`.","retryable":false,"can_keep":true,"conversation_id":"\#(id)","started_at":"\#(at)","title":null}"#
            }
            let issues = #"{"issues":["# + issue("00000000-fixture-0001", "2026-09-29T22:08:09.000Z") + "," + issue("00000000-fixture-0002", "2026-09-29T19:23:04.000Z") + "]}"
            if let st = try? JSONDecoder().decode(ServerStatus.self, from: Data(status.utf8)),
               let list = try? JSONDecoder().decode(ServerIssuesResponse.self, from: Data(issues.utf8)) {
                model.debugUseServerFixture(status: st, issues: list.issues)
            }
        }
        // `-OmiNotesDebugSimulatedDevice YES|NO` turns the simulated pendant on or off, and
        // `-OmiNotesDebugPendantControlsFail YES` makes it reject settings writes (screenshots of the
        // pendant's settings and their error state).
        if UserDefaults.standard.object(forKey: "OmiNotesDebugSimulatedDevice") != nil {
            engine.setSimulatedMode(UserDefaults.standard.bool(forKey: "OmiNotesDebugSimulatedDevice"))
        }
        engine.setSimulatedControlsFail(UserDefaults.standard.bool(forKey: "OmiNotesDebugPendantControlsFail"))
        // `-OmiNotesDebugPendantFeaturesUnreadable YES`: the simulated pendant's features can't be read.
        // `-OmiNotesDebugSimulatedFirmwareAfterUpdate 3.0.22`: what it reports after an update's restart.
        // `-OmiNotesDebugFirmwareFeed <dir>`: Omi's firmware answers and packages come from local files
        // (latest.json / stable.json, the package by its file name; a missing file is a 404).
        let featuresUnreadable = UserDefaults.standard.bool(forKey: "OmiNotesDebugPendantFeaturesUnreadable")
        let afterUpdate = UserDefaults.standard.string(forKey: "OmiNotesDebugSimulatedFirmwareAfterUpdate")
        engine.configureSimulatedPendant { sim in
            sim.failFeaturesRead = featuresUnreadable
            if let afterUpdate { sim.firmwareAfterUpdate = afterUpdate }
        }
        if let feed = UserDefaults.standard.string(forKey: "OmiNotesDebugFirmwareFeed") {
            let dir = URL(fileURLWithPath: feed)
            model.firmwareFetch = { url in
                let name = url.path.hasSuffix("/latest") ? "latest.json" : url.path.hasSuffix("/stable") ? "stable.json" : url.lastPathComponent
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return (Data(), 404) }
                try await Task.sleep(for: .milliseconds(600))
                return (data, 200)
            }
        }
        // `-OmiNotesDebugOpenURL omi-notes://configure?…` exercises the URL-scheme sheet without the system prompt.
        if let raw = UserDefaults.standard.string(forKey: "OmiNotesDebugOpenURL"), let link = URL(string: raw) {
            model.handleOpenURL(link)
        }
        #endif
        if application.applicationState == .background {
            // Relaunched for a Bluetooth event / upload: no scene will become active.
            engine.appDidEnterBackground()
        }
        let restored = launchOptions?[.bluetoothCentrals] != nil
        OmiLog.shared.log(.info, "app", "launched\(restored ? " by Bluetooth state restoration" : "") (\(application.applicationState == .background ? "background" : "foreground"))")
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        let box = CompletionBox(completionHandler)
        model.engine.handleBackgroundSessionEvents(identifier: identifier) { box.call() }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        model.engine.appWillTerminate()
    }
}

/// Carries a UIKit completion handler across the engine queue; it is only ever invoked on main.
private final class CompletionBox: @unchecked Sendable {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func call() { body() }
}

/// `beginBackgroundTask` / `endBackgroundTask`, callable from the engine queue without blocking it:
/// both hop to the main queue in order, so an end can never overtake its begin.
final class UIKitBackgroundTasks: BackgroundTaskProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var next = 1
    private var ids: [Int: UIBackgroundTaskIdentifier] = [:]
    private let application: UIApplication

    init(application: UIApplication) { self.application = application }

    func beginTask(name: String, expiration: @escaping @Sendable () -> Void) -> Int? {
        lock.lock()
        let token = next
        next += 1
        lock.unlock()
        let app = application
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let id = app.beginBackgroundTask(withName: name) {
                    expiration()
                    self.endTask(token)
                }
                self.lock.lock()
                self.ids[token] = id
                self.lock.unlock()
            }
        }
        return token
    }

    func endTask(_ token: Int) {
        let app = application
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.lock.lock()
                let id = self.ids.removeValue(forKey: token)
                self.lock.unlock()
                if let id, id != .invalid { app.endBackgroundTask(id) }
            }
        }
    }
}
