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
        var p = try decode(Person.self, Self.alanJSON)
        p.autoActive = true
        #expect(VoicesHub.measuredLine(p, calibrationSupported: false) == nil)
        #expect(VoicesHub.measuredLine(p, calibrationSupported: true) != nil)
    }

    /// Live calibration 2026-11-09: an inactive person's measurement is of the gated decision, so it
    /// found nobody ("认出 ≥ 0%" would read as a broken model). Only an active person's line shows.
    @Test func measuredIsShownOnlyForAnActivePerson() throws {
        let inactive = try decode(Person.self, #"""
        {"id":"p-alan","name":"Alan","me":true,"auto_active":false,
         "measured":{"conversations":213,"found_at_least":0.0,"negative_conversations":30,"wrong_at_most":0.133}}
        """#)
        #expect(VoicesHub.measuredLine(inactive, calibrationSupported: true) == nil)
        var unknown = inactive
        unknown.autoActive = nil  // an answer without auto_active isn't active either
        #expect(VoicesHub.measuredLine(unknown, calibrationSupported: true) == nil)
        var active = inactive
        active.autoActive = true
        #expect(VoicesHub.measuredLine(active, calibrationSupported: true) == "243 段 · 认出 ≥ 0% · 误认 ≤ 14%")
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

    // MARK: Astra review (deployed backend 1b7ef4e)

    /// `POST /v1/samples/{id}/move` answers the original sample, now `moved`, pointing at its copy
    /// (`journal.py`: `moved_to: {person_id, sample_id}`); the copy carries `moved_from` (with `import_id`
    /// for an enrollment). Both are objects, never strings.
    @Test func aMoveAnswerAndTheMovedCopyDecode() throws {
        let answer = #"""
        {"sample":{"id":"5b0c2a52-0000-4000-8000-000000000001","person_id":"p-alan","state":"moved","revision":4,"source":"user",
          "seconds":5.2,"created_at":"2026-10-10T02:14:00.000Z","day":"2026-10-09","label":"S2","f0":180.2,"f0_source":"voices",
          "flag":{"reasons":["pitch"],"open":false,"resolved":{"decision":"move","at":"2026-11-09T18:00:00.000Z","fingerprint":"ab"}},
          "moved_to":{"person_id":"p-gigi","sample_id":"5b0c2a52-0000-4000-8000-000000000002"},"moved_from":null,
          "playable":true,"clip":{"id":"sample.5b0c2a52-0000-4000-8000-000000000001.0","seconds":5.2,"started_at":null},
          "text":"下一集马上开始","conversation":{"id":"c12","started_at":"2026-11-03T02:05:00.000Z","title":"客厅"},
          "device":"omi-1","review_id":"s.5b0c2a52-0000-4000-8000-000000000001.4"},
         "request_id":"r-9","undo_token":"r-9"}
        """#
        let a = try decode(SampleActionAnswer.self, answer)
        #expect(a.sample?.sampleState == .moved && a.sample?.movedTo?.personId == "p-gigi")
        #expect(a.sample?.movedTo?.sampleId == "5b0c2a52-0000-4000-8000-000000000002" && a.sample?.movedFrom == nil)
        let copy = try decode(VoiceSamplesResponse.self, #"""
        {"samples":[{"id":"5b0c2a52-0000-4000-8000-000000000002","person_id":"p-gigi","state":"active","revision":0,
          "moved_to":null,"moved_from":{"person_id":"p-alan","sample_id":"5b0c2a52-0000-4000-8000-000000000001","import_id":null},
          "playable":false,"text":"下一集马上开始"}]}
        """#)
        #expect(copy.samples.first?.movedFrom?.personId == "p-alan")
        #expect(copy.samples.first?.movedFrom?.sampleId == "5b0c2a52-0000-4000-8000-000000000001")
    }

    /// The 409 codes the backend sends for voices (`journal.py`, `review.py`, `service.py`), each with its own words.
    @Test func eachConflictCodeHasItsOwnExplanation() {
        #expect(VoiceConflict("stale_review: this sample changed") == .staleReview)
        #expect(VoiceConflict("consent_required: no attestation") == .consentRequired)
        #expect(VoiceConflict("recovery_pending: still recovering") == .recoveryPending)
        #expect(VoiceConflict("forget_in_progress: finish it first") == .forgetInProgress)
        #expect(VoiceConflict("superseded: an active import holds overlapping audio") == .superseded)
        #expect(VoiceConflict("sample_not_active: the sample is removed") == .other("sample_not_active"))
        #expect(VoiceConflict.recoveryPending.message == "正在恢复，稍后再试")
        #expect(VoiceConflict.staleReview.reloads && VoiceConflict.superseded.reloads && !VoiceConflict.recoveryPending.reloads)
        #expect(!VoiceConflict.forgetInProgress.reloads && !VoiceConflict.consentRequired.reloads)
    }

    /// A failed undo says why, in the backend's own reasons (known ones in Chinese).
    @Test func aFailedUndoListsTheBackendsReasons() throws {
        let u = try decode(UndoNamingResponse.self, #"{"undone":[],"skipped":[],"samples":{"undone":[],"skipped":[{"id":"a","reason":"changed since"},{"id":"b","reason":"that person's consent is withdrawn"},{"id":"c","reason":"something new"}]}}"#)
        #expect(!u.undidAnything)
        #expect(u.skipReasons == ["之后又改过", "这个人的同意已撤回", "something new"])
        #expect(try decode(UndoNamingResponse.self, #"{"undone":[],"skipped":["c1"]}"#).skipReasons == ["之后又改过"])
    }

    /// The backend returns no queue total; the badge counts flagged samples and says so.
    /// Without a queue total (older server) the badge counts flagged samples and says so (可疑); with
    /// the server's `total` it is the real queue, under the card's own 待确认.
    @Test func theReviewBadgeSaysWhatItCounts() {
        #expect(VoicesHub.reviewBadge(total: nil, flagged: 148) == "可疑 148")
        #expect(VoicesHub.reviewBadge(total: nil, flagged: 0) == nil)
        #expect(VoicesHub.reviewBadge(total: 163, flagged: 148) == "163")
        #expect(VoicesHub.reviewBadge(total: 0, flagged: 148) == nil)
    }

    // MARK: Build 48 feedback ("TA 是谁？")

    /// The server names the person each item asks about (`person_name`, main 5410801); it comes first,
    /// so the question never depends on the people list having loaded.
    @Test func theItemsOwnNameIsAskedFirst() throws {
        let item = try decode(ReviewItem.self, #"{"id":"s.a.1","kind":"sample","person_id":"p-alan","person_name":"Alan"}"#)
        #expect(item.personName == "Alan")
        #expect(VoicesHub.reviewQuestion(item, people: []) == .isThis(personId: "p-alan", name: "Alan"))
        #expect(VoicesHub.reviewQuestion(item, people: [Person(id: "p-alan", name: "Alan Chen")]) == .isThis(personId: "p-alan", name: "Alan"))
    }

    @Test func withoutTheItemsNameThePeopleListNamesIt() throws {
        let item = try decode(ReviewItem.self, #"{"id":"s.a.1","person_id":"p-alan","person_name":null}"#)
        #expect(VoicesHub.reviewQuestion(item, people: [Person(id: "p-alan", name: "Alan")]) == .isThis(personId: "p-alan", name: "Alan"))
    }

    /// Nobody to name: ask who it is, never "是 TA 吗？".
    @Test func anItemWithoutANameAsksWhoItIs() throws {
        let noPerson = try decode(ReviewItem.self, #"{"id":"l.c.S1.2..x","kind":"label","person_id":null,"person_name":null,"label":"S1"}"#)
        #expect(VoicesHub.reviewQuestion(noPerson, people: [Person(id: "p-alan", name: "Alan")]) == .whoIsThis)
        let unknownName = try decode(ReviewItem.self, #"{"id":"s.a.1","person_id":"p-gone"}"#)
        #expect(VoicesHub.reviewQuestion(unknownName, people: []) == .whoIsThis)
        let blank = try decode(ReviewItem.self, #"{"id":"s.a.1","person_id":"p-alan","person_name":"  "}"#)
        #expect(VoicesHub.reviewQuestion(blank, people: []) == .whoIsThis)
    }

    /// `GET /v1/speakers/review?limit&offset` pages: `next_offset` (null at the end) and `total`.
    @Test func aReviewPageDecodesItsPaging() throws {
        let page = try decode(ReviewItemsResponse.self, #"{"items":[{"id":"s.a.1"}],"next_offset":50,"total":163}"#)
        #expect(page.nextOffset == 50 && page.total == 163 && page.paginated)
        let last = try decode(ReviewItemsResponse.self, #"{"items":[],"next_offset":null,"total":163}"#)
        #expect(last.nextOffset == nil && last.paginated)
        let old = try decode(ReviewItemsResponse.self, #"{"items":[]}"#)
        #expect(old.nextOffset == nil && old.total == nil && !old.paginated)
    }
}
