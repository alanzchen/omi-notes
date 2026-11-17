import Foundation
import Testing
@testable import OmiWatchKit

/// ASTRA-20261117-IT1-01: a Watch report and the Watch change it was received after must be one record, replaced
/// atomically, so an interrupted save can never pair an old report with a new count. SYNTHETIC values.
@Suite struct WatchReportRecordTests {
    func inbox(_ dir: URL) -> PhoneWatchInbox { PhoneWatchInbox(root: dir, currentBinding: { "p" }) }
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())

    @Test func anInterruptedSaveAfterASwitchLeavesTheBuildUnknown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omi-record-\(UUID().uuidString)")
        let a = inbox(dir)
        a.saveReport(WatchReport(state: .idle, since: nil, waitingParts: 0, at: now.addingTimeInterval(300), deviceId: "A"))
        a.saveAppBuild(WatchAppBuild(build: 49, at: now, deviceId: "A", source: .report, receivedAt: now))
        a.watchChanged(at: now)
        // B's save got as far as a separate count file before the app died (how 568b8e9 saved them)
        try WatchWire.encode(["generation": 1]).write(to: dir.appendingPathComponent("report-generation.json"))
        #expect(inbox(dir).appBuild(now: now) == nil, "A's report is from before the switch: no Watch is in use")
    }

    @Test func aReportSavedBeforeCountsWereKeptNamesNoWatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omi-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try WatchWire.encode(WatchReport(state: .idle, since: nil, waitingParts: 0, at: now, deviceId: "A")).write(to: dir.appendingPathComponent("report.json"))
        let box = inbox(dir)
        box.saveAppBuild(WatchAppBuild(build: 49, at: now, deviceId: "A", source: .report, receivedAt: now))
        #expect(box.latestReport?.deviceId == "A", "still read for the Watch's state")
        #expect(box.appBuild(now: now) == nil, "but which Watch change it came after is unknown")
        box.saveReport(WatchReport(state: .idle, since: nil, waitingParts: 0, at: now.addingTimeInterval(-5), deviceId: "A"))
        #expect(box.appBuild(now: now)?.build == 49, "the next report (even dated earlier) names it")
    }
}

/// ASTRA-20261117-IT1-01: `Files.durableWrite` removed the old file before moving the new one in, so a reader (or a
/// crash) between the two found no file at all. A replace must never leave the name empty.
@Suite struct DurableReplaceTests {
    @Test func aReplacedFileIsNeverMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omi-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.json")
        try Files.durableWrite(Data("0".utf8), to: url)
        let done = Flag()
        let reader = Thread {
            var missing = 0
            while !done.value { if !FileManager.default.fileExists(atPath: url.path) { missing += 1 } }
            done.missing = missing
            done.finished = true
        }
        reader.start()
        for i in 1...400 { try Files.durableWrite(Data("\(i)".utf8), to: url) }
        let source = dir.appendingPathComponent("audio.src")
        try Data("audio".utf8).write(to: source)
        for _ in 1...100 { try Files.durableCopy(source, to: url) }
        done.value = true
        while !done.finished { usleep(1000) }
        #expect(done.missing == 0, "the file was missing \(done.missing) times during replaces")
        #expect(try Data(contentsOf: url) == Data("audio".utf8))
    }
}

private final class Flag: @unchecked Sendable {
    var value = false, finished = false, missing = 0
}
