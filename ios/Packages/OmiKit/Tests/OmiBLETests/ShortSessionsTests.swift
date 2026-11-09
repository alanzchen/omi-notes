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
