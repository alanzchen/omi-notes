import OmiBLE
import OmiCapture
import OmiProtocol
import UIKit

/// Creates the engine (and with it the `CBCentralManager` carrying the restore identifier)
/// synchronously in `didFinishLaunching`, because iOS may relaunch the app straight into the
/// background for a Bluetooth event or a finished upload.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private(set) var model: AppModel!
    private var backgroundTasks: UIKitBackgroundTasks!

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
        #if DEBUG
        // Simulator automation only (debug builds): `-OmiNotesDebugServerURL <url> -OmiNotesDebugToken <token>`.
        if let raw = UserDefaults.standard.string(forKey: "OmiNotesDebugServerURL"),
           let token = UserDefaults.standard.string(forKey: "OmiNotesDebugToken"),
           let url = ServerURLPolicy.evaluate(raw).url {
            do { try engine.configureServer(url: url, token: token) } catch {
                OmiLog.shared.log(.error, "app", "debug server configuration failed: \(error)")
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
