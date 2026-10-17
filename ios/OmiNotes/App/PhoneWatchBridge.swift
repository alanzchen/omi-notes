import Foundation
import OmiBLE
import OmiCapture
import OmiWatchKit
import WatchConnectivity

/// The iPhone end of the Apple Watch relay. A segment is acknowledged to the Watch only after it is
/// stored durably here and matches its hash; the Watch deletes nothing before that. Recordings bound
/// to another iPhone install are refused (the Watch keeps them).
final class PhoneWatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    let engine: OmiEngine
    /// Omi Notes installed on a paired Watch (for Home's status), on activation and on every change;
    /// false at once where WatchConnectivity is unsupported. Not called while activation is pending or failed.
    let onWatchState: @Sendable (Bool) -> Void

    /// `onWatchState` is set before activation starts, so an early callback can't be missed.
    init(engine: OmiEngine, onWatchState: @escaping @Sendable (Bool) -> Void) {
        self.engine = engine
        self.onWatchState = onWatchState
        super.init()
        guard WCSession.isSupported() else {
            onWatchState(false)  // no Watch can pair with this device
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func announce(_ session: WCSession) {
        // unreadable before the first unlock: announcing nothing beats announcing a wrong identity
        guard session.activationState == .activated, let phone = engine.settings.phoneInstallId else { return }
        // a changing field, so the context is always transmitted (an unchanged one may not reach a
        // freshly installed Watch app)
        try? session.updateApplicationContext([WatchWire.binding: phone, "at": Date().timeIntervalSince1970])
    }

    private func acknowledge(_ ids: [String], _ session: WCSession) {
        guard !ids.isEmpty, let phone = engine.settings.phoneInstallId else { return }
        let message: [String: Any] = [WatchWire.acks: ids, WatchWire.binding: phone]
        session.transferUserInfo(message)  // delivered even if the Watch app isn't running now
        if session.isReachable { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        OmiLog.shared.log(.info, "watch", "WatchConnectivity \(state.rawValue) paired \(session.isPaired) installed \(session.isWatchAppInstalled)\(error.map { " error \($0.localizedDescription)" } ?? "")")
        engine.acceptWatchReport(session.receivedApplicationContext[WatchWire.report] as? Data)
        if state == .activated { onWatchState(session.isPaired && session.isWatchAppInstalled) }
        announce(session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()  // a different Watch was paired: talk to it
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        onWatchState(session.isPaired && session.isWatchAppInstalled)
        announce(session)
    }

    /// The Watch's latest status report.
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        engine.acceptWatchReport(context[WatchWire.report] as? Data)
    }

    /// The Watch asks who its iPhone is (it has no binding yet).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(engine.settings.phoneInstallId.map { [WatchWire.binding: $0] } ?? [:])
        announce(session)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        OmiLog.shared.log(.info, "watch", "received a file from the Watch (\(file.metadata?[WatchWire.kind] as? String ?? "?"))")
        guard file.metadata?[WatchWire.kind] as? String == WatchWire.segment else { return }
        do {
            let id = try engine.acceptWatchSegment(file: file.fileURL, manifest: file.metadata?[WatchWire.manifest] as? Data)
            acknowledge([id], session)
        } catch {
            // not acknowledged: the Watch keeps it (and resends it, or holds it for its own iPhone)
            OmiLog.shared.log(.warning, "watch", "segment not accepted: \(error.localizedDescription)")
            engine.noteWatchRefusal("segment: \(error.localizedDescription)")
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo[WatchWire.kind] as? String == WatchWire.perf {
            do {
                acknowledge([try engine.acceptWatchPerf(userInfo[WatchWire.manifest] as? Data)], session)
            } catch {
                // not acknowledged: the Watch keeps the batch
                OmiLog.shared.log(.warning, "watch", "performance batch not accepted: \(error.localizedDescription)")
                engine.noteWatchRefusal("perf: \(error.localizedDescription)")
            }
            return
        }
        guard userInfo[WatchWire.kind] as? String == WatchWire.end else { return }
        do {
            acknowledge([try engine.acceptWatchEnd(userInfo[WatchWire.manifest] as? Data)], session)
        } catch {
            OmiLog.shared.log(.warning, "watch", "recording end not accepted: \(error.localizedDescription)")
            engine.noteWatchRefusal("end: \(error.localizedDescription)")
        }
    }
}
