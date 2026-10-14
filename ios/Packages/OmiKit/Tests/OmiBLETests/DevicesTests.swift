import Foundation
import Testing
@testable import OmiBLE
import OmiWatchKit

/// The Devices screen: which devices get cards, and a Watch state that claims only what is known.
@Suite struct DevicesTests {
    let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func cardsForConfiguredDevicesInAFixedOrderAndASetupRowForTheRest() {
        #expect(DeviceLayout.arrange(pendantPaired: true, watchConfigured: true) == ([.pendant, .watch], []), "both record; no choice between them")
        #expect(DeviceLayout.arrange(pendantPaired: true, watchConfigured: false) == ([.pendant], [.watch]))
        #expect(DeviceLayout.arrange(pendantPaired: false, watchConfigured: true) == ([.watch], [.pendant]))
        #expect(DeviceLayout.arrange(pendantPaired: false, watchConfigured: false) == ([], [.pendant, .watch]))
    }

    @Test func aReceiptOrAnInstalledAppIsNotTakenAsRecording() {
        let received = WatchSummary.evaluate(installed: true, report: nil, lastReceivedAt: now.addingTimeInterval(-30), now: now)
        #expect(received.title == "Current state unknown" && received.tone == .quiet && received.configured)
        let installed = WatchSummary.evaluate(installed: true, report: nil, lastReceivedAt: nil, now: now)
        #expect(installed.title == "Not used yet" && installed.configured)
        let unknown = WatchSummary.evaluate(installed: nil, report: nil, lastReceivedAt: nil, now: now)
        #expect(!unknown.configured && unknown.title == "Set up Apple Watch", "unknown installation: a setup row, not a fake device")
    }

    @Test func onlyAFreshReportSaysWhatTheWatchIsDoing() {
        let rec = WatchReport(state: .recording, since: now.addingTimeInterval(-3600), waitingParts: 1, at: now.addingTimeInterval(-120))
        let fresh = WatchSummary.evaluate(installed: true, report: rec, lastReceivedAt: nil, now: now)
        #expect(fresh.title == "Recording" && fresh.tone == .recording && fresh.detail?.contains("reported") == true)
        var old = rec
        old.at = now.addingTimeInterval(-WatchSummary.fresh - 1)
        let stale = WatchSummary.evaluate(installed: nil, report: old, lastReceivedAt: nil, now: now)
        #expect(stale.title == "Current state unknown" && stale.detail?.hasSuffix("recording") == true && stale.tone == .quiet)
        let paused = WatchSummary.evaluate(installed: true, report: WatchReport(state: .paused, since: nil, waitingParts: 0, at: now), lastReceivedAt: nil, now: now)
        #expect(paused.tone == .attention && paused.detail?.contains("Resume") == true)
    }

    @Test func thePhoneKeepsOnlyTheNewestReport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-wreport-\(UUID().uuidString)")
        let inbox = PhoneWatchInbox(root: root, binding: "p")
        let newer = WatchReport(state: .recording, since: nil, waitingParts: 3, at: now)
        inbox.saveReport(newer)
        inbox.saveReport(WatchReport(state: .idle, since: nil, waitingParts: 0, at: now.addingTimeInterval(-60)))  // delivered late
        #expect(inbox.latestReport == newer)
        #expect(PhoneWatchInbox(root: root, binding: "p").latestReport == newer, "kept across relaunch")
    }
}
