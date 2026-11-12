import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiWatchKit

/// Each transfer stage says only what its source knows, as of its time; "sending" needs bytes that
/// actually moved, and a Watch report is fresh only within the Watch's own window.
@Suite struct TransferSummaryTests {
    let s: UInt64 = 1_000_000_000
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func reachable() -> ServerReachability { .reachable(version: "0.1.0", detail: "") }

    func snapshot(pending: Int = 0, counting: Bool = true, bytesAt: UInt64? = nil) -> EngineSnapshot {
        var snap = EngineSnapshot()
        snap.ready = true
        snap.serverConfigured = true
        snap.outbox.pendingCount = pending
        if counting { snap.transfer.meter.start(atMono: 0, wall: now) }
        if let at = bytesAt {
            snap.transfer.meter.progress(id: "a", audio: true, sent: 0, expected: 1_000, atMono: at - s)
            snap.transfer.meter.progress(id: "a", audio: true, sent: 500, expected: 1_000, atMono: at)
        }
        return snap
    }

    func state(_ snap: EngineSnapshot, _ server: ServerReachability? = nil, at mono: UInt64) -> TransferSummary.UploadState {
        TransferSummary.evaluate(snapshot: snap, server: server ?? reachable(), status: nil, statusAt: nil, watchInstalled: nil, nowMono: mono, now: now).phone.state
    }

    @Test func sendingOnlyWhileBytesAreActuallyMoving() {
        let snap = snapshot(pending: 3, bytesAt: 5 * s)
        #expect(state(snap, at: 5 * s) == .sending)
        #expect(state(snap, at: 20 * s) == .waiting, "bytes stopped: waiting, not still 'sending'")
        let summary = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: nil, nowMono: 20 * s, now: now)
        #expect(summary.phone.rate == nil)
    }

    @Test func theOtherStatesFollowWhatIsKnown() {
        #expect(state(snapshot(pending: 0), at: 5 * s) == .allSent)
        #expect(state(snapshot(pending: 4), .unreachable("timed out"), at: 5 * s) == .offline("timed out"))
        var backoff = snapshot(pending: 4)
        backoff.upload.backingOff = 2
        #expect(state(backoff, at: 5 * s) == .retrying)
        var paused = snapshot(pending: 4)
        paused.upload.pausedReason = "storage"
        #expect(state(paused, at: 5 * s) == .paused("storage"))
        #expect(state(snapshot(pending: 4, counting: false), at: 5 * s) == .unknown, "not counting: nothing is live")
        var none = snapshot()
        none.serverConfigured = false
        #expect(state(none, at: 5 * s) == .notConfigured)
    }

    @Test func aWatchReportIsFreshOnlyWithinTheWatchsWindow() {
        var snap = snapshot()
        snap.watchReport = WatchReport(state: .recording, since: nil, waitingParts: 4, waitingSeconds: 230, at: now.addingTimeInterval(-60))
        var w = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: s, now: now).watch
        #expect(w.reportFresh && w.waitingSeconds == 230 && w.waitingParts == 4)
        snap.watchReport?.at = now.addingTimeInterval(-3600)
        w = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: s, now: now).watch
        #expect(!w.reportFresh, "an hour-old report is what the Watch had then")
        snap.watchReport?.at = now.addingTimeInterval(3600)
        w = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: s, now: now).watch
        #expect(!w.reportFresh, "a report from the future isn't current either")
    }

    @Test func reCheckedPartsAreNotCountedAsOnTheWatch() {
        var snap = snapshot()
        snap.watchReport = WatchReport(state: .recording, since: nil, waitingParts: 10, waitingSeconds: 600, at: now.addingTimeInterval(-60),
                                       stats: ["recheck_parts": 7, "recheck_s": 420])
        let w = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: s, now: now).watch
        #expect(w.recheckParts == 7 && w.recheckSeconds == 420)
        #expect(w.newParts == 3 && w.waitingParts == 10 && w.waitingSeconds == 600, "re-checks stay in the totals")
        snap.watchReport = WatchReport(state: .idle, since: nil, waitingParts: 2, waitingSeconds: 60, at: now)
        let old = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: s, now: now).watch
        #expect(old.recheckParts == 0 && old.newParts == 2, "an older Watch app reports no re-checks")
    }

    // UX-LT-ASTRA-05/07 (astra-review/EngineHarness.swift)

    @Test func retainedWorkIsNeverAllSent() {
        var kept = snapshot(pending: 0)
        kept.outbox.quarantineCount = 1
        #expect(state(kept, at: 5 * s) == .keptAside(1))
        var preparing = snapshot(pending: 0)
        preparing.watchPending = 2
        #expect(state(preparing, at: 5 * s) == .preparing(2))
        var unreadable = snapshot(pending: 0)
        unreadable.outbox.inventoryReadable = false
        #expect(state(unreadable, at: 5 * s) == .queueUnreadable, "a queue that couldn't be read isn't empty")
    }

    @Test func anUnknownWatchInstallIsNotNotInUse() {
        let w = TransferSummary.evaluate(snapshot: snapshot(), server: reachable(), status: nil, statusAt: nil, watchInstalled: nil, nowMono: s, now: now).watch
        #expect(w.inUse == nil)
        let no = TransferSummary.evaluate(snapshot: snapshot(), server: reachable(), status: nil, statusAt: nil, watchInstalled: false, nowMono: s, now: now).watch
        #expect(no.inUse == false)
    }

    @Test func theReceiptTimeIsAReceiptNotAConversion() {
        var snap = snapshot()
        snap.watchReceived = 3
        snap.watchLastReceivedAt = now  // a conversion marker written now (after a relaunch)
        let w = TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: s, now: now).watch
        #expect(w.lastReceivedAt == nil, "no receipt in this run: unknown, not the marker's time")
    }

    @Test func ratesReadInTheirUnits() {
        #expect(TransferSummary.rateText(820) == "820 B/s")
        #expect(TransferSummary.rateText(48_200) == "48.2 KB/s")
        #expect(TransferSummary.rateText(1_300_000) == "1.3 MB/s")
    }

    // OMI-THROUGHPUT-UI-20261108: the redesigned screen's hero and bars

    @Test func timeLeftOnlyWhileBytesMove() throws {
        let backlog = try #require(TransferSummary.debugFixture("backlog", now: now))
        let left = try #require(backlog.phoneTimeLeft)
        #expect(abs(left / 3600 - 13.4) < 0.1, "5.39 GB at 111.7 KB/s is about 13.4 h")
        let waiting = try #require(TransferSummary.debugFixture("waiting", now: now))
        #expect(waiting.phoneTimeLeft == nil, "no speed, no estimate")
    }

    @Test func barsCoverOnlyWhatIsKnown() throws {
        let backlog = try #require(TransferSummary.debugFixture("backlog", now: now))
        let f = try #require(backlog.phoneFraction)
        #expect(abs(f - 46.6 / (46.6 + 5_390)) < 0.0001)
        #expect(try #require(TransferSummary.debugFixture("all-sent", now: now)).phoneFraction == 1)
        let watch = try #require(backlog.watchFraction)
        #expect(abs(watch - 266.0 / 270) < 0.0001, "received parts of received plus still on the Watch")
        #expect(try #require(TransferSummary.debugFixture("unknown-watch", now: now)).watchFraction == nil)
        var notCounting = backlog
        notCounting.phone.since = nil
        #expect(notCounting.phoneFraction == nil, "in the background nothing is counted, so no bar")
    }

    // ASTRA-IT1-05/06: nothing on Transfers may claim completion it can't know.

    @Test func aStaleOrFutureWatchReportIsNoCompletion() throws {
        for age: TimeInterval in [-86_400, 86_400] {
            var t = try #require(TransferSummary.debugFixture("all-sent", now: now))
            t.watch.reportAt = now.addingTimeInterval(age)
            t.watch.reportFresh = false
            #expect(t.watchFraction == nil, "no 100% from a report of yesterday or tomorrow")
            #expect(!t.everythingSent, "and no \"All sent\" either")
        }
    }

    @Test func allSentNeedsTheWatchToo() throws {
        var t = try #require(TransferSummary.debugFixture("all-sent", now: now))
        #expect(t.everythingSent, "phone empty, fresh Watch report with nothing waiting")
        t.watch.waitingParts = 3
        #expect(!t.everythingSent, "the Watch still has parts")
        t.watch.waitingParts = nil
        #expect(!t.everythingSent, "unknown is not nothing")
        t.watch.inUse = false
        #expect(t.everythingSent, "no Watch in use: the iPhone is everything")
    }

    @Test func theServerHasWorkWhileConversationsAreQueued() throws {
        var t = try #require(TransferSummary.debugFixture("all-sent", now: now))
        t.server.chunksPending = 0
        t.server.conversationsPending = 3
        #expect(t.serverWorkLeft == 3)
        t.server.conversationsPending = 0
        #expect(t.serverWorkLeft == 0)
        t.server.chunksPending = nil
        t.server.conversationsPending = nil
        #expect(t.serverWorkLeft == nil, "unknown when the server didn't say")
    }

    /// ASTRA-IT3-03: one count present as 0 and the other absent became "nothing to process".
    /// Done only when both are explicitly 0; a known count above 0 is an "at least".
    @Test func aMissingServerCountIsNeverZero() throws {
        var t = try #require(TransferSummary.debugFixture("all-sent", now: now))
        t.server.chunksPending = 0; t.server.conversationsPending = nil
        #expect(t.serverWorkLeft == nil && t.serverWork == nil)
        t.server.chunksPending = nil; t.server.conversationsPending = 0
        #expect(t.serverWorkLeft == nil && t.serverWork == nil)
        t.server.chunksPending = 4; t.server.conversationsPending = nil
        #expect(t.serverWork?.left == 4 && t.serverWork?.atLeast == true && t.serverWorkLeft == nil)
        t.server.chunksPending = 0; t.server.conversationsPending = 0
        #expect(t.serverWork?.left == 0 && t.serverWork?.atLeast == false && t.serverWorkLeft == 0)
    }

    /// ASTRA-IT10-01: audio kept on the Watch that can't be sent (orphan parts) counted toward the cap
    /// but not as "waiting", so an orphan-only Watch read as everything sent, 100%. Kept parts now
    /// suppress every all-sent claim, below the cap and at it.
    @Test(arguments: [false, true])
    func audioKeptOnTheWatchIsNeverAllSent(atCap: Bool) throws {
        let report = WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now, deviceId: "watch-1",
                                 stats: ["orphan_parts": 1])
        #expect(report.keptParts == 1)
        var snap = EngineSnapshot.answered
        snap.ready = true; snap.serverConfigured = true; snap.watchReport = report
        snap.transfer.meter.start(atMono: 0, wall: now)
        let t = TransferSummary.evaluate(snapshot: snap, server: .reachable(version: "t", detail: ""), status: nil, statusAt: nil,
                                         watchInstalled: true, nowMono: 0, now: now)
        #expect(t.watch.keptOnWatch == 1)
        #expect(!t.everythingSent && t.watchFraction == nil, "no all-sent and no 100% while audio is kept on the Watch")
        if atCap {
            let reason = try #require(WatchStorage.pauseReason(freeBytes: 2_000_000_000, waitingBytes: WatchStorage.maximumWaiting,
                                                               keptBytes: WatchStorage.maximumWaiting))
            #expect(!reason.contains("Resume") && reason.contains("can't be sent"), "no promise that opening the iPhone clears it: \(reason)")
            let normal = try #require(WatchStorage.pauseReason(freeBytes: 2_000_000_000, waitingBytes: WatchStorage.maximumWaiting, keptBytes: 0))
            #expect(normal.contains("Open Omi Notes on the iPhone"), "an ordinary backlog keeps its advice")
        }
    }

    func summary(_ report: WatchReport) -> TransferSummary {
        var snap = EngineSnapshot.answered
        snap.ready = true; snap.serverConfigured = true; snap.watchReport = report
        snap.transfer.meter.start(atMono: 0, wall: now)
        return TransferSummary.evaluate(snapshot: snap, server: reachable(), status: nil, statusAt: nil, watchInstalled: true, nowMono: 0, now: now)
    }

    /// ASTRA-IT11-01: a report without `orphan_parts` (an older Watch app, or no stats at all) read as
    /// zero kept parts, so a legacy Watch could show all sent. Missing is unknown; only an explicit 0 is none.
    @Test func aMissingKeptPartsCountIsUnknownNotZero() {
        let legacy = WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now, deviceId: "watch-1")
        let noKey = WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now, deviceId: "watch-1", stats: ["awaiting_ack": 0])
        let zero = WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now, deviceId: "watch-1", stats: ["orphan_parts": 0])
        #expect(legacy.keptParts == nil && noKey.keptParts == nil && zero.keptParts == 0)
        for r in [legacy, noKey] {
            let t = summary(r)
            #expect(t.watch.keptOnWatch == nil)
            #expect(!t.everythingSent && t.watchFraction == nil, "unknown kept parts are not none")
            #expect(!WatchSummary.onWatchLine(r, lastReceivedAt: now, now: now).contains("Everything sent"))
        }
        let t = summary(zero)
        #expect(t.everythingSent && t.watchFraction == 1, "an explicit 0 is proof")
        #expect(WatchSummary.onWatchLine(zero, lastReceivedAt: now, now: now).hasPrefix("Everything sent to this iPhone"))
    }

    /// ASTRA-20261109-IT1-04: the Transfers line still said "Nothing left on the Watch" for a fresh report
    /// with no waiting parts and no kept-parts count, while the Watch detail said kept parts weren't
    /// reported. A missing count never implies empty storage; an explicit 0 still completes normally.
    @Test func aMissingKeptPartsCountNeverSaysNothingLeftOnTheWatch() {
        let legacy = WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now, deviceId: "watch-1")
        let t = summary(legacy)
        #expect(t.watch.keptOnWatch == nil)
        #expect(t.watchLine(now: now) == "没有待发录音（保留部分未报告）")
        #expect(!WatchSummary.onWatchLine(legacy, lastReceivedAt: nil, now: now).contains("Everything sent"), "neither screen calls it empty")
        let zero = summary(WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now, stats: ["orphan_parts": 0]))
        #expect(zero.watchLine(now: now) == "手表上已无录音" && zero.everythingSent)
        let waiting = summary(WatchReport(state: .idle, since: nil, waitingParts: 2, waitingSeconds: 120, at: now))
        #expect(waiting.watchLine(now: now) == "还剩 2 分钟录音")
    }

    /// ASTRA-IT11-02: at the cap, any kept audio made the reason say there's no room because it can't be
    /// sent, even when sendable audio over the cap would free room once the iPhone takes it. The
    /// "can't be sent" reason is only for kept audio that fills the cap (or the disk) by itself.
    @Test func theCapReasonBlamesKeptAudioOnlyWhenItAloneFillsTheCap() throws {
        let cap = WatchStorage.maximumWaiting
        let mixed = try #require(WatchStorage.pauseReason(freeBytes: 2_000_000_000, waitingBytes: cap, keptBytes: 100_000_000))
        #expect(mixed.contains("Open Omi Notes on the iPhone"), "sending the rest frees room: \(mixed)")
        let keptOnly = try #require(WatchStorage.pauseReason(freeBytes: 2_000_000_000, waitingBytes: cap, keptBytes: cap))
        #expect(keptOnly.contains("can't be sent") && !keptOnly.contains("Resume"))
        let fullDisk = try #require(WatchStorage.pauseReason(freeBytes: 100_000_000, waitingBytes: 50_000_000, keptBytes: 50_000_000))
        #expect(fullDisk.contains("can't be sent") && !fullDisk.contains("send what's waiting"), "nothing sendable: \(fullDisk)")
        let fullDiskMixed = try #require(WatchStorage.pauseReason(freeBytes: 100_000_000, waitingBytes: 50_000_000, keptBytes: 10_000_000))
        #expect(fullDiskMixed.contains("send what's waiting"))
    }

    /// ASTRA-IT11-03: a positive kept-parts count was shown as current even from a stale or future-dated
    /// report. It is a statement about now only from a fresh report.
    @Test func keptPartsFromAnOldOrFutureReportAreNotCurrent() {
        let kept: [String: Int] = ["orphan_parts": 2]
        let fresh = summary(WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now.addingTimeInterval(-60), stats: kept))
        #expect(fresh.watchLine(now: now) == "无可发送的录音" && fresh.problemLine(now: now) == "手表上有录音无法发送")
        let stale = summary(WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now.addingTimeInterval(-3 * 3600), stats: kept))
        #expect(stale.watchLine(now: now) == "等待手表报告" && stale.problemLine(now: now) == "手表报告已过时")
        let future = summary(WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now.addingTimeInterval(3600), stats: kept))
        #expect(future.watchLine(now: now) == "等待手表报告" && future.problemLine(now: now) == "手表时间与 iPhone 不一致")
        let ok = summary(WatchReport(state: .idle, since: nil, waitingParts: 3, waitingSeconds: 180, at: now, stats: ["orphan_parts": 0]))
        #expect(ok.watchLine(now: now) == "还剩 3 分钟录音" && ok.problemLine(now: now) == nil)
    }

    /// ASTRA-IT11-04: with both waiting and kept parts, the line named only the kept ones and then said
    /// "They move when both are nearby", about parts that can't be sent. Both are named; the advice is
    /// about the waiting audio only, and never given for kept parts alone.
    @Test func aMixedBacklogNamesBothAndAdvisesOnlyAboutSendableAudio() {
        let mixed = WatchReport(state: .recording, since: now, waitingParts: 3, waitingSeconds: 180, at: now, stats: ["orphan_parts": 2])
        let line = WatchSummary.onWatchLine(mixed, lastReceivedAt: nil, now: now)
        #expect(line == "3 min waiting · 2 parts kept, can't be sent", "\(line)")
        #expect(WatchSummary.onWatchHint(mixed, lastReceivedAt: nil, now: now) == "The waiting audio moves when both are nearby with Omi Notes open")
        let keptOnly = WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now, stats: ["orphan_parts": 2])
        #expect(WatchSummary.onWatchLine(keptOnly, lastReceivedAt: nil, now: now) == "2 parts kept, can't be sent")
        #expect(WatchSummary.onWatchHint(keptOnly, lastReceivedAt: nil, now: now) == nil)
        let waiting = WatchReport(state: .recording, since: now, waitingParts: 3, waitingSeconds: 180, at: now, stats: ["orphan_parts": 0])
        #expect(WatchSummary.onWatchHint(waiting, lastReceivedAt: nil, now: now) == "Moves when both are nearby with Omi Notes open")
        #expect(WatchSummary.onWatchHint(waiting, lastReceivedAt: now.addingTimeInterval(-60), now: now) == nil, "arriving: no advice")
    }

    /// Nightly 2026-11-12 round 2: the Watch page's "On the Watch" row was three lines ("2 min of audio not on this
    /// iPhone yet · reported 1 minute ago. They move when …"). One status line, no repeated report time (the header
    /// has it); the advice is a separate short line. The Devices card of an idle Watch says what is waiting on it.
    @Test func theWatchRowIsOneStatusLineAndTheCardSaysWhatIsWaiting() {
        let idle = WatchReport(state: .idle, since: nil, waitingParts: 3, waitingSeconds: 140, at: now.addingTimeInterval(-60), stats: ["orphan_parts": 0])
        let line = WatchSummary.onWatchLine(idle, lastReceivedAt: now.addingTimeInterval(-4 * 3600), now: now)
        #expect(line == "2 min waiting" && !line.contains("reported"))
        let s = WatchSummary.evaluate(installed: true, report: idle, lastReceivedAt: now.addingTimeInterval(-4 * 3600), now: now)
        #expect(s.cardDetail == "2 min waiting on the Watch" && s.detail?.hasPrefix("reported") == true)
        let empty = WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now, stats: ["orphan_parts": 0])
        #expect(WatchSummary.evaluate(installed: true, report: empty, lastReceivedAt: now, now: now).cardDetail == nil)
        let recording = WatchReport(state: .recording, since: now, waitingParts: 3, waitingSeconds: 140, at: now)
        #expect(WatchSummary.evaluate(installed: true, report: recording, lastReceivedAt: now, now: now).cardDetail == nil)
    }

    /// Nightly 2026-11-12 round 2 / ASTRA-20261112-IT2-03: a recording with no final sample was "not finished yet"
    /// for good, and then (90e5c2e) "no final reading" after 12 h even while a current report said the same recording
    /// was still going. Sample age never says a recording ended.
    @Test func aWatchRecordingsEndIsNeverInferredFromAnOldSample() {
        let started = now.addingTimeInterval(-14 * 3600)
        func end(_ complete: Bool, _ last: Date?, _ r: WatchReport? = nil) -> String? {
            WatchSummary.sessionEnd(complete: complete, startedAt: started, lastAt: last, report: r, now: now)
        }
        #expect(end(true, now.addingTimeInterval(-90 * 86_400)) == nil)
        #expect(end(false, now.addingTimeInterval(-3600)) == "Not finished yet")
        #expect(end(false, now.addingTimeInterval(-12 * 3600)) == "Not finished yet", "exactly 12 h")
        #expect(end(false, now.addingTimeInterval(-13 * 3600))?.hasPrefix("Last reading 13 hours ago") == true)
        #expect(end(false, now.addingTimeInterval(3600)) == "Reading time unclear", "a future sample")
        #expect(end(false, nil) == "No end reading")
        let recording = WatchReport(state: .recording, since: started.addingTimeInterval(30), waitingParts: 0, at: now.addingTimeInterval(-60))
        #expect(end(false, now.addingTimeInterval(-13 * 3600), recording) == nil, "the current report says it is still recording")
        let other = WatchReport(state: .recording, since: now.addingTimeInterval(-600), waitingParts: 0, at: now.addingTimeInterval(-60))
        #expect(end(false, now.addingTimeInterval(-13 * 3600), other)?.hasPrefix("Last reading") == true, "another recording")
        let future = WatchReport(state: .recording, since: started, waitingParts: 0, at: now.addingTimeInterval(3600))
        #expect(end(false, now.addingTimeInterval(-13 * 3600), future)?.hasPrefix("Last reading") == true, "not a current report")
    }

    /// ASTRA-20261112-IT2-02: a future-dated report (Watch clock ahead) made the card say "2 min waiting on the Watch"
    /// as current, dropping "reported in 1 hour". Only a report as of now gives that subtitle.
    @Test func aFutureReportGivesNoCurrentWaitingSubtitle() {
        let ahead = WatchReport(state: .idle, since: nil, waitingParts: 3, waitingSeconds: 140, at: now.addingTimeInterval(3600))
        let s = WatchSummary.evaluate(installed: true, report: ahead, lastReceivedAt: nil, now: now)
        #expect(s.cardDetail == nil && (s.cardDetail ?? s.detail ?? "").contains("in 1 hour"), "\(String(describing: s.detail))")
        #expect(!WatchSummary.isCurrent(ahead, now: now))
        #expect(WatchSummary.isCurrent(WatchReport(state: .idle, since: nil, waitingParts: 0, at: now.addingTimeInterval(-600)), now: now))
    }

    /// ASTRA-20261112-IT2-01: "Upload to your server" said "Nothing waiting" while this iPhone held a Watch part it set
    /// aside; an unreadable outbox is unknown. Only a readable, empty outbox is "Nothing waiting".
    @Test func theWatchUploadLineNamesSetAsideAudioAndAnUnknownOutbox() {
        func line(waiting: Int = 0, aside: Int = 0, readable: Bool = true) -> String {
            WatchSummary.uploadLine(waiting: waiting, othersWaiting: 0, setAside: aside, inventoryReadable: readable,
                                    lastUploadedAt: now.addingTimeInterval(-3600), received: 10, now: now)
        }
        #expect(line(aside: 1) == "1 part set aside")
        #expect(line(waiting: 2, aside: 2) == "Watch audio waiting to upload · 2 parts set aside")
        #expect(line(readable: false) == "Unknown right now")
        #expect(line().hasPrefix("Nothing waiting · last uploaded"))
    }

    // TRANSFERS-50 (Alan, 2026-11-09/10: "uploading 卡片很多余"; "都有进度条了我为什么要知道文件数量"): no
    // state heading and no file or part counts on the main screen. A problem line only when something is
    // wrong; the time estimate sits on the iPhone → server bar; the Watch bar says how much audio is left.

    func fixture(_ name: String) throws -> TransferSummary { try #require(TransferSummary.debugFixture(name, now: now)) }
    static let names = ["backlog", "sending", "waiting", "offline", "retrying", "kept-aside", "all-sent", "unknown-watch"]

    @Test func theMainLinesNameNoCounts() throws {
        for name in Self.names {
            let t = try fixture(name)
            let lines = [t.problemLine(now: now), t.phoneLine, t.watchLine(now: now), t.serverLine(now: now), t.cardLine(now: now)?.text].compactMap { $0 }
            for line in lines {
                for word in ["file", "part", "to process", "left on", "Uploading"] {
                    #expect(!line.contains(word), "\(name): \(line)")
                }
                #expect(!line.contains(/\d\s*(个|件|份|段)/), "no counted items: \(name): \(line)")
                #expect(t.phone.queuedFiles == 0 || !line.contains(t.phone.queuedFiles.formatted()), "\(name): \(line)")
            }
        }
    }

    @Test func theEstimateSitsOnTheServerBarAndNeedsAMeasuredRate() throws {
        let backlog = try fixture("backlog")
        let bytes = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        #expect(backlog.phoneLine == "\(bytes(46_600_000)) / \(bytes(46_600_000 + 5_390_000_000)) · 约 13 小时")
        #expect(!backlog.phoneLine.contains("/s"), "the speed is in Details while there are byte totals")
        #expect(try fixture("sending").phoneLine.hasSuffix(" · 不到 1 分钟"))
        let waiting = try fixture("waiting")
        #expect(waiting.phoneLine == "待上传 \(bytes(9_400_000))", "no rate, no estimate: \(waiting.phoneLine)")
        #expect(TransferSummary.estimateText(25 * 60) == "约 25 分钟")
        #expect(TransferSummary.estimateText(3 * 86_400) == "约 3 天")
        var onlyRate = waiting
        onlyRate.phone.since = nil; onlyRate.phone.queuedBytes = 0; onlyRate.phone.rate = 48_200
        #expect(onlyRate.phoneLine == "48.2 KB/s", "the speed when it is the only progress signal")
    }

    @Test func theWatchBarSaysHowMuchAudioIsLeftAndUnknownIsNeverZero() throws {
        func line(_ r: WatchReport) -> String { summary(r).watchLine(now: now) }
        #expect(line(WatchReport(state: .recording, since: nil, waitingParts: 4, waitingSeconds: 720, at: now)) == "还剩 12 分钟录音")
        #expect(line(WatchReport(state: .recording, since: nil, waitingParts: 4, waitingSeconds: 45, at: now)) == "还剩 45 秒录音")
        #expect(line(WatchReport(state: .recording, since: nil, waitingParts: 4, waitingSeconds: 3_900, at: now)) == "还剩 1 小时 5 分钟录音")
        #expect(line(WatchReport(state: .recording, since: nil, waitingParts: 4, waitingSeconds: nil, at: now)) == "手表未报告剩余时长",
                "parts without a duration: unknown, not 0")
        #expect(line(WatchReport(state: .recording, since: nil, waitingParts: 4, waitingSeconds: 0, at: now)) == "手表未报告剩余时长",
                "parts waiting are never \"0 s left\"")
        #expect(line(WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now, stats: ["orphan_parts": 0])) == "手表上已无录音")
        let stale = WatchReport(state: .idle, since: nil, waitingParts: 0, waitingSeconds: 0, at: now.addingTimeInterval(-3 * 3600), stats: ["orphan_parts": 0])
        #expect(line(stale) == "等待手表报告", "an old report is no statement about now")
        var unknown = try fixture("unknown-watch")
        #expect(unknown.watchLine(now: now) == "正在检查 Apple Watch")
        unknown.watch.inUse = true
        #expect(unknown.watchLine(now: now) == "等待手表报告")
    }

    @Test func aProblemLineOnlyWhenSomethingIsWrong() throws {
        for name in ["backlog", "sending", "waiting", "all-sent", "unknown-watch"] {
            #expect(try fixture(name).problemLine(now: now) == nil, "\(name)")
        }
        #expect(try fixture("offline").problemLine(now: now) == "连不上服务器")
        #expect(try fixture("retrying").problemLine(now: now) == "上传失败，稍后重试")
        #expect(try fixture("kept-aside").problemLine(now: now) == "有文件被搁置，未上传")
        var t = try fixture("waiting")
        t.phone.state = .paused("storage")
        #expect(t.problemLine(now: now) == "上传已暂停")
        t.phone.state = .offline(TransferSummary.rejectedReason)
        #expect(t.problemLine(now: now) == "服务器拒绝了这台 iPhone")
        t = try fixture("all-sent")
        t.server.reachable = false
        #expect(t.problemLine(now: now) == "连不上服务器", "unreachable with nothing queued is still a problem")
        t = try fixture("waiting")
        t.watch.reportFresh = false
        t.watch.reportAt = now.addingTimeInterval(-3 * 3600)
        #expect(t.problemLine(now: now) == "手表报告已过时")
        t.watch.reportAt = now.addingTimeInterval(3600)
        #expect(t.problemLine(now: now) == "手表时间与 iPhone 不一致")
        t = try fixture("waiting")
        t.watch.keptOnWatch = 2
        #expect(t.problemLine(now: now) == "手表上有录音无法发送")
        t.phone.state = .offline("timed out")
        #expect(t.problemLine(now: now) == "连不上服务器 · 手表上有录音无法发送")
    }

    @Test func theServerLineIsAStateNotACount() throws {
        var t = try fixture("all-sent")
        #expect(t.serverLine(now: now) == "服务器处理中")
        t.server.chunksPending = 0; t.server.conversationsPending = 0
        #expect(t.everythingSent && t.serverLine(now: now) == "已是最新")
        t.watch.waitingParts = 2
        #expect(t.serverLine(now: now) == "服务器已处理完收到的录音", "not up to date while the Watch still has audio")
        t.server.conversationsPending = nil
        #expect(t.serverLine(now: now) == nil, "a missing count is unknown")
        t = try fixture("all-sent")
        t.server.checkedAt = now.addingTimeInterval(-600)
        #expect(t.serverLine(now: now) == nil, "an old answer says nothing about now")
        t = try fixture("all-sent")
        t.server.reachable = false
        #expect(t.serverLine(now: now) == nil, "the problem line says it")
        #expect(try fixture("offline").serverLine(now: now) == nil, "no server state beside \"连不上服务器\"")
    }

    @Test func timesReadInChineseAndAFutureTimeIsNoAge() {
        #expect(TransferSummary.agoText(now.addingTimeInterval(-20), now: now) == "刚刚")
        #expect(TransferSummary.agoText(now.addingTimeInterval(-25 * 60), now: now) == "25 分钟前")
        #expect(TransferSummary.agoText(now.addingTimeInterval(-3 * 3600), now: now) == "3 小时前")
        #expect(TransferSummary.agoText(now.addingTimeInterval(-2 * 86_400), now: now) == "2 天前")
        #expect(TransferSummary.agoText(now.addingTimeInterval(3600), now: now) == "晚于本机时间")
    }

    @Test func theDevicesCardShowsAProblemOrAnEstimate() throws {
        let backlog = try #require(try fixture("backlog").cardLine(now: now))
        #expect(backlog.text == "约 13 小时传完" && !backlog.attention)
        let offline = try #require(try fixture("offline").cardLine(now: now))
        #expect(offline.text == "连不上服务器" && offline.attention)
        #expect(try fixture("waiting").cardLine(now: now) == nil)
        #expect(try fixture("all-sent").cardLine(now: now)?.text == "全部已发送")
        var unknown = try fixture("all-sent")
        unknown.watch.waitingParts = nil
        #expect(unknown.cardLine(now: now) == nil, "no all-sent while the Watch is unknown")
    }
}

