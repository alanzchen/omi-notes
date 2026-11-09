import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol

/// Deferred short sessions on the phone: the list's per-day totals and when a cached note is stale.
@MainActor
@Suite struct ShortSessionsTests {
    func model() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-short-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        let engine = OmiEngine(config: EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "test", useCoreBluetooth: false),
                               settings: settings, uploadTransport: CountingUploadTransport())
        return AppModel(engine: engine, noteCache: NoteCache(root: root.appendingPathComponent("cache")))
    }

    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func aRecentPageCarriesSpeechTheDeferredStateAndTheDaysTotals() throws {
        let page = try decode(RecentConversationsResponse.self, #"""
        {"conversations":[{"id":"a","status":"closed","speech_s":8.4,"duration_s":31.0,"day":"2026-11-08","revision":null,
          "state":{"code":"deferred","message":"Short recording"},
          "deferred":{"state":"waiting","operation_id":null,"threshold_s":60.0,"provisional_class":"undetermined"},
          "recording_class":{"class":"undetermined","auto":"undetermined","confidence":null,"overridden":false,"provisional":true}}],
         "next_cursor":null,"days":{"2026-11-08":{"short":4,"deferred":3,"requested":1,"issues":1}},"short_s":60.0}
        """#)
        let c = try #require(page.conversations.first)
        #expect(c.speechS == 8.4 && c.day == "2026-11-08" && c.deferred?.isWaiting == true)
        #expect(c.recordingClass?.isUndetermined == true && c.recordingClass?.provisional == true)
        #expect(c.isShort(threshold: 60) && c.displayState.code == "deferred")
        let m = model()
        m.mergeFirstPage(page)
        #expect(m.shortDays["2026-11-08"] == ShortDay(short: 4, deferred: 3, requested: 1, issues: 1) && m.shortSeconds == 60)
        let older = try decode(RecentConversationsResponse.self, #"{"conversations":[]}"#)
        #expect(older.days == nil && older.shortS == nil, "older servers")
    }

    @Test func aCachedNoteIsStaleOnceItsRevisionMovesOrItsDeferralEnds() throws {
        let m = model()
        let detail = try decode(ConversationDetail.self, #"""
        {"id":"a","status":"done","revision":1,"recording_class":{"class":"monologue","overridden":false,"updating":false}}
        """#)
        m.details["a"] = detail
        func row(_ json: String) throws -> RecentConversationsResponse {
            try decode(RecentConversationsResponse.self, #"{"conversations":[{"id":"a",\#(json)}]}"#)
        }
        m.mergeFirstPage(try row(#""status":"done","revision":1,"recording_class":{"class":"monologue","overridden":false,"updating":false}"#))
        #expect(!m.detailNeedsReload("a"))
        // the same kind, an entirely new body: only the revision tells
        m.mergeFirstPage(try row(#""status":"done","revision":2,"recording_class":{"class":"monologue","overridden":false,"updating":false}"#))
        #expect(m.detailNeedsReload("a"))
        m.details["a"] = try decode(ConversationDetail.self, #"""
        {"id":"a","status":"closed","deferred":{"state":"requested"},"state":{"code":"processing","message":"x"}}
        """#)
        m.mergeFirstPage(try row(#""status":"done","revision":1,"state":{"code":"ready","message":"Note ready"}"#))
        #expect(m.detailNeedsReload("a"), "a provisional session finished")
    }
}

/// Astra review of e1e7576..ce07e32: server days, folds from totals, paging, reconciliation, request states.
@MainActor
@Suite struct ShortSessionsReviewTests {
    func model() -> AppModel { ShortSessionsTests().model() }

    func row(_ id: String, day: String, start: String, speech: Double, status: String = "done",
             deferred: String? = nil) -> ConversationSummary {
        var c = ConversationSummary(id: id, status: status, startedAt: start)
        c.day = day
        c.speechS = speech
        if let deferred { c.deferred = DeferredTranscription(state: deferred) }
        return c
    }

    @Test func homeGroupsByTheServersDayNotThePhonesClock() {
        // 23:30 in the server's zone is already the next day in UTC (and on a phone set to UTC)
        let rows = [row("a", day: "2026-11-08", start: "2026-11-09T05:30:00.000Z", speech: 300),
                    row("b", day: "2026-11-08", start: "2026-11-08T15:00:00.000Z", speech: 20)]
        let sections = HomeDay.sections(rows, filter: .talk, shortSeconds: 60, shortDays: [:], day: { $0.day ?? "" }) { _ in "auto" }
        #expect(sections.map(\.day) == ["2026-11-08"])
        #expect(sections[0].home.rows.map(\.id) == ["a"] && sections[0].home.shortClips.map(\.id) == ["b"])
    }

    @Test func aDaysFoldShowsFromTheServersTotalsWithNoShortRowLoaded() {
        let rows = [row("long", day: "2026-11-07", start: "2026-11-07T15:00:00.000Z", speech: 300)]
        let totals = ["2026-11-07": ShortDay(short: 2, deferred: 1, requested: 0, issues: 1)]
        let sections = HomeDay.sections(rows, filter: .background, shortSeconds: 60, shortDays: totals,
                                        day: { $0.day ?? "" }) { _ in "auto" }
        #expect(sections.count == 1 && sections[0].home.rows.isEmpty, "filtered out, yet the day stays for its fold")
        #expect(sections[0].totals == ShortDay(short: 2, deferred: 1, requested: 0, issues: 1))
        #expect(sections[0].showsFold)
    }

    @Test func aDayIsLoadedPageByPage() async throws {
        var asked: [String?] = []
        let pages: [String?: RecentConversationsResponse] = [
            nil: RecentConversationsResponse(conversations: [row("1", day: "d", start: "s", speech: 9)], nextCursor: "c1"),
            "c1": RecentConversationsResponse(conversations: [row("2", day: "d", start: "s", speech: 9)], nextCursor: "c2"),
            "c2": RecentConversationsResponse(conversations: [row("3", day: "d", start: "s", speech: 9)], nextCursor: nil),
        ]
        let rows = try await AppModel.collectPages { cursor in
            asked.append(cursor)
            return pages[cursor]!
        }
        #expect(rows.map(\.id) == ["1", "2", "3"] && asked == [nil, "c1", "c2"])
    }

    @Test func aRefreshReconcilesLoadedDayRowsAndNeverTheOtherWay() throws {
        let m = model()
        m.shortDayRows["2026-11-08"] = [row("a", day: "2026-11-08", start: "s", speech: 9, status: "closed", deferred: "waiting"),
                                         row("b", day: "2026-11-08", start: "s", speech: 9, status: "closed", deferred: "waiting")]
        var done = row("a", day: "2026-11-08", start: "s", speech: 9)
        done.title = "Dentist"
        m.mergeFirstPage(RecentConversationsResponse(conversations: [done], nextCursor: nil))
        #expect(m.shortDayRows["2026-11-08"]?.map(\.deferred) == [nil, DeferredTranscription(state: "waiting")])
        #expect(m.shortDayRows["2026-11-08"]?.first?.title == "Dentist")
        m.applyRecordingClass(RecordingClassView(kind: "monologue", overridden: true, provisional: true), to: "b")
        #expect(m.shortDayRows["2026-11-08"]?.last?.recordingClass?.kind == "monologue")
        #expect(m.recent.map(\.id) == ["a"], "day rows never enter the main list")
    }

    @Test func aTranscribeRequestShowsItsStateAndItsRefusal() {
        let m = model()
        let waiting = row("w", day: "d", start: "s", speech: 9, status: "closed", deferred: "waiting")
        m.shortDayRows["d"] = [waiting]
        #expect(m.transcribeState(of: waiting) == .offer(nil) || m.transcribeState(of: waiting) == .unavailable)
        m.retries["w"] = RetryOperation(id: "op", kind: "transcribe", state: "running")
        #expect(m.transcribeState(of: waiting) == .asked)
        m.retries["w"] = RetryOperation(id: "op", kind: "transcribe", state: "failed", message: "Transcription failed")
        #expect(m.transcribeState(of: waiting) == .offer("Transcription failed"), "the error beside the action, offered again")
        m.retries["w"] = nil
        m.retryMessages["w"] = "Processing failed; retry it instead."
        #expect(m.transcribeState(of: waiting) == .offer("Processing failed; retry it instead."))
        // finished on the server: the refreshed row has its note, no spinner and no 转写 left
        m.retryMessages["w"] = nil
        m.retries["w"] = RetryOperation(id: "op", kind: "transcribe", state: "done")
        m.shortDayRows["d"] = [row("w", day: "d", start: "s", speech: 9)]
        #expect(m.transcribeState(of: waiting) == .none)
    }
}
