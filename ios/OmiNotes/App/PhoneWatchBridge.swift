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

    init(engine: OmiEngine) {
        self.engine = engine
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func announce(_ session: WCSession) {
        guard session.activationState == .activated else { return }
        // a changing field, so the context is always transmitted (an unchanged one may not reach a
        // freshly installed Watch app)
        try? session.updateApplicationContext([WatchWire.binding: engine.settings.phoneInstallId, "at": Date().timeIntervalSince1970])
    }

    private func acknowledge(_ ids: [String], _ session: WCSession) {
        guard !ids.isEmpty else { return }
        let message: [String: Any] = [WatchWire.acks: ids, WatchWire.binding: engine.settings.phoneInstallId]
        session.transferUserInfo(message)  // delivered even if the Watch app isn't running now
        if session.isReachable { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        OmiLog.shared.log(.info, "watch", "WatchConnectivity \(state.rawValue) paired \(session.isPaired) installed \(session.isWatchAppInstalled)\(error.map { " error \($0.localizedDescription)" } ?? "")")
        engine.acceptWatchReport(session.receivedApplicationContext[WatchWire.report] as? Data)
        announce(session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()  // a different Watch was paired: talk to it
    }

    func sessionWatchStateDidChange(_ session: WCSession) { announce(session) }

    /// The Watch's latest status report.
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        engine.acceptWatchReport(context[WatchWire.report] as? Data)
    }

    /// The Watch asks who its iPhone is (it has no binding yet).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler([WatchWire.binding: engine.settings.phoneInstallId])
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
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo[WatchWire.kind] as? String == WatchWire.end else { return }
        do {
            acknowledge([try engine.acceptWatchEnd(userInfo[WatchWire.manifest] as? Data)], session)
        } catch {
            OmiLog.shared.log(.warning, "watch", "recording end not accepted: \(error.localizedDescription)")
        }
    }
}
