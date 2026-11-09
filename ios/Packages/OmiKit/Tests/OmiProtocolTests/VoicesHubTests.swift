import Foundation
import Testing
@testable import OmiProtocol

/// The 声纹 hub's wire models and display rules (docs/speaker-learning.md, "Voices hub" and "API").
/// The server isn't deployed yet: every new field is optional, and an older server's answers still decode.
@Suite struct VoicesHubTests {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try Self.decoder.decode(type, from: Data(json.utf8))
    }

    static let alanJSON = #"""
    {"id":"p-alan","name":"Alan","me":true,"note_path":"People/Alan.md","samples":168,"sessions":30,"auto_active":false,
     "voice_ready":true,"samples_active":168,"samples_flagged":126,"samples_removed":0,"review_count":126,
     "status_line":"停用：样本不一致","calibrated_at":"2026-11-09T09:10:00.000Z",
     "measured":{"conversations":23,"found_at_least":0.7123,"negative_conversations":12,"wrong_at_most":0.0718,
                 "target_absent_conversations":0,"confidence":0.95}}
    """#

    // MARK: Decoding

    @Test func aPersonDecodesTheHubFields() throws {
        let p = try decode(Person.self, Self.alanJSON)
        #expect(p.isMe && p.samples == 168 && p.reviewCount == 126 && p.samplesFlagged == 126 && p.samplesRemoved == 0)
        #expect(p.statusLine == "停用：样本不一致" && p.calibratedAt == "2026-11-09T09:10:00.000Z")
        #expect(p.measured?.conversations == 23 && p.measured?.negativeConversations == 12 && p.measured?.wrongAtMost == 0.0718)
    }

    @Test func anOlderServersPersonStillDecodes() throws {
        let p = try decode(Person.self, #"{"id":"p1","name":"Leo","samples":4,"auto_active":true}"#)
        #expect(p.statusLine == nil && p.reviewCount == nil && p.measured == nil && p.calibratedAt == nil)
        let nulls = try decode(Person.self, #"{"id":"p1","name":"Leo","measured":null,"status_line":null,"calibrated_at":null}"#)
        #expect(nulls.measured == nil)
    }

    @Test func aSampleDecodesWithItsFlagClipAndContext() throws {
        let json = #"""
        {"id":"smp1","person_id":"p-alan","state":"active","revision":3,"source":"user","seconds":5.2,
         "created_at":"2026-10-09T02:14:00.000Z","day":"2026-10-08","label":"S2","f0":118.2,"f0_source":"bench",
         "flag":{"reasons":["pitch","score"],"open":true,"resolved":null},"moved_to":null,"moved_from":null,"playable":true,
         "clip":{"id":"sample.smp1.0","seconds":5.2,"started_at":"2026-10-09T02:14:03.000Z"},"text":"今天我们来看看",
         "conversation":{"id":"c1","started_at":"2026-10-09T02:10:00.000Z","title":"晚间录音"},"device":"omi-1","review_id":"s.smp1.3"}
        """#
        let s = try decode(VoiceSample.self, json)
        #expect(s.isFlagged && s.flag?.reasons == ["pitch", "score"] && s.canPlay && s.clip?.id == "sample.smp1.0")
        #expect(s.sampleState == .active && s.revision == 3 && s.reviewId == "s.smp1.3" && s.conversation?.title == "晚间录音")
        let resolved = try decode(VoiceSample.self, #"{"id":"x","flag":{"reasons":["pitch"],"open":false,"resolved":{"decision":"confirm","at":"t"}},"playable":false,"text":"hi"}"#)
        #expect(!resolved.isFlagged && !resolved.canPlay && resolved.sampleState == .active)  // absent state = active
        let removed = try decode(VoiceSample.self, #"{"id":"y","state":"removed"}"#)
        #expect(removed.sampleState == .removed && !removed.canPlay)
    }

    @Test func aReviewItemDecodesBothKinds() throws {
        let json = #"""
        {"items":[
          {"id":"s.smp1.3","kind":"sample","person_id":"p-alan","sample_id":"smp1","reasons":["pitch"],"playable":true,
           "clip":{"id":"sample.smp1.0","seconds":4.6,"started_at":null},"text":"欢迎回到频道","conversation":{"id":"c1","started_at":"2026-10-09T02:10:00.000Z","title":null},
           "device":"omi-1","source":"user","f0":180.0},
          {"id":"l.c2.S1.4.p-gigi.ab12","kind":"label","person_id":"p-gigi","label":"S1","reasons":["auto"],"playable":false,
           "text":"你今天晚上想吃什么","conversation":{"id":"c2","started_at":"2026-11-02T12:05:00.000Z","title":"客厅"},"device":null}]}
        """#
        let items = try decode(ReviewItemsResponse.self, json).items
        #expect(items.map(\.id) == ["s.smp1.3", "l.c2.S1.4.p-gigi.ab12"])
        #expect(items[0].canPlay && items[0].clip?.seconds == 4.6 && items[0].isSuspicious)
        #expect(!items[1].canPlay && items[1].label == "S1" && items[1].sampleId == nil && !items[1].isSuspicious)
    }

    @Test func anUnplayableItemWithAClipIdIsStillNotPlayable() throws {
        // playable false is the server's word: never fetch a clip it says it can't cut
        let item = try decode(ReviewItem.self, #"{"id":"s.a.1","playable":false,"clip":{"id":"sample.a.0"},"text":"x"}"#)
        #expect(!item.canPlay)
    }

    @Test func decisionAndActionAnswersCarryTheUndoToken() throws {
        let d = try decode(ReviewDecisionAnswer.self, #"{"item_id":"s.smp1.3","decision":"reject","request_id":"r1","undo_token":"r1","sample":{"id":"smp1"}}"#)
        #expect(d.undoToken == "r1" && d.requestId == "r1")
        let a = try decode(SampleActionAnswer.self, #"{"sample":{"id":"smp1","state":"removed","revision":4},"request_id":"r2","undo_token":"r2"}"#)
        #expect(a.sample?.sampleState == .removed && a.undoToken == "r2")
    }

    @Test func undoReportsSampleOutcomesWhenTheServerSendsThem() throws {
        let u = try decode(UndoNamingResponse.self, #"{"undone":[],"skipped":[],"samples":{"undone":["smp1"],"skipped":[{"id":"smp2","reason":"changed"}]}}"#)
        #expect(u.samples?.undone == ["smp1"] && u.samples?.skipped?.first?.id == "smp2")
        let old = try decode(UndoNamingResponse.self, #"{"undone":["c1"],"skipped":[]}"#)
        #expect(old.samples == nil)
    }

    @Test func statusFeaturesGateTheHub() throws {
        let s = try decode(ServerStatus.self, #"{"features":["name_voice","voice_review","voice_calibration","enrollment_import"]}"#)
        #expect(s.supportsVoiceReview && s.supportsVoiceCalibration && s.supportsEnrollmentImport)
        let old = try decode(ServerStatus.self, #"{"features":["name_voice"]}"#)
        #expect(!old.supportsVoiceReview && !old.supportsVoiceCalibration && !old.supportsEnrollmentImport)
    }

    // MARK: Measured performance: only counted results, compact, conservative

    @Test func measuredShowsHeldOutCountsAndBoundsOnly() throws {
        let p = try decode(Person.self, Self.alanJSON)
        // 23 + 12 held-out conversations; the found bound rounds down, the wrong bound rounds up
        #expect(p.measured?.compactLine == "35 段 · 认出 ≥ 71% · 误认 ≤ 8%")
    }

    @Test func measuredWithOnlyNegativesShowsOnlyTheWrongBound() throws {
        let m = try decode(MeasuredPerformance.self, #"{"conversations":0,"found_at_least":null,"negative_conversations":35,"wrong_at_most":0.0821}"#)
        #expect(m.compactLine == "35 段 · 误认 ≤ 9%")
    }

    @Test func measuredWithoutCountsShowsNothing() throws {
        let empty = try decode(MeasuredPerformance.self, #"{"conversations":0,"negative_conversations":0}"#)
        #expect(empty.compactLine == nil)
        let noBounds = try decode(MeasuredPerformance.self, #"{"conversations":5}"#)
        #expect(noBounds.compactLine == nil)  // a count without a bound says nothing about accuracy
        let p = try decode(Person.self, #"{"id":"p","name":"Leo","measured":null}"#)
        #expect(VoicesHub.measuredLine(p, calibrationSupported: true) == nil)
    }

    @Test func measuredIsHiddenWithoutTheCalibrationFeature() throws {
        let p = try decode(Person.self, Self.alanJSON)
        #expect(VoicesHub.measuredLine(p, calibrationSupported: false) == nil)
        #expect(VoicesHub.measuredLine(p, calibrationSupported: true) != nil)
    }

    // MARK: Hub

    @Test func meComesFirstThenOthersInServerOrder() {
        let people = [Person(id: "g", name: "Gigi"), Person(id: "a", name: "Alan", me: true), Person(id: "l", name: "Leo")]
        #expect(VoicesHub.cards(people).map(\.id) == ["a", "g", "l"])
        #expect(VoicesHub.cards([Person(id: "g", name: "Gigi")]).map(\.id) == ["g"])
    }

    @Test func pendingReviewIsTheSumOfEachPersonsCount() throws {
        let people = [try decode(Person.self, Self.alanJSON), try decode(Person.self, #"{"id":"g","name":"Gigi","review_count":22}"#),
                      Person(id: "l", name: "Leo")]
        #expect(VoicesHub.pendingReview(people) == 148)
        #expect(VoicesHub.pendingReview([Person(id: "l", name: "Leo")]) == 0)
    }

    @Test func calibrationTimeIsShortAndLocal() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = try #require(ISO8601UTC.parse("2026-11-09T18:00:00Z"))  // 12:00 in Chicago
        #expect(VoicesHub.shortTime("2026-11-09T09:10:00.000Z", now: now, calendar: cal) == "今天 03:10")
        #expect(VoicesHub.shortTime("2026-11-08T09:10:00.000Z", now: now, calendar: cal) == "昨天 03:10")
        #expect(VoicesHub.shortTime("2026-11-02T09:10:00.000Z", now: now, calendar: cal) == "11-02")
        #expect(VoicesHub.shortTime("2025-11-02T09:10:00.000Z", now: now, calendar: cal) == "2025-11-02")
        #expect(VoicesHub.shortTime(nil, now: now, calendar: cal) == nil)
        #expect(VoicesHub.shortTime("garbage", now: now, calendar: cal) == nil)
    }

    @Test func flagReasonsReadAsShortWords() {
        #expect(VoicesHub.reasonLabel("pitch") == "音高不同")
        #expect(VoicesHub.reasonLabel("score") == "不太像")
        #expect(VoicesHub.reasonLabel("enrollment") == "不像录入")
        #expect(VoicesHub.reasonLabel("auto") == "自动命名")
        #expect(VoicesHub.reasonLabel("possible") == "可能是")
        #expect(VoicesHub.reasonLabel("something_new") == "可疑")  // a newer server's reason is still shown as a flag
    }

    // MARK: Review batches: the server's order, never re-sorted

    @Test func aBatchKeepsTheServerOrderDropsRepeatsAndWhatWasSkipped() throws {
        let ids = ["s.a.1", "s.b.1", "l.c.S1.2.p.x", "s.a.1", "s.d.1"]
        let items = ids.map { ReviewItem(id: $0) }
        let batch = ReviewBatch.make(items, excluding: ["s.b.1"], limit: 10)
        #expect(batch.map(\.id) == ["s.a.1", "l.c.S1.2.p.x", "s.d.1"])
        #expect(ReviewBatch.make(items, excluding: [], limit: 2).map(\.id) == ["s.a.1", "s.b.1"])
        #expect(ReviewBatch.size == 10)
    }
}
