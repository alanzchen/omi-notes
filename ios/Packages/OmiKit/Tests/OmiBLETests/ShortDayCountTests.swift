// R5 (2026-11-19): after the server answers a day with no short sessions, the fold can't say "短片段 1" above
// "没有短片段". A real server's empty page carries `"days": {}` (totals only for days in the page, backend `api.py`
// `day_totals`), so the day's earlier estimate survived the answer.
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiProtocol

extension RetryFlowTests {
@MainActor @Suite(.serialized) struct ShortDayCountTests {
    let day = "2026-11-18"
    let path = "/v1/conversations/recent"

    func configured() async throws -> (AppModel, URL) {
        let (m, root) = try RetryFlowTests().model()
        AppServerStub.routes["/v1/status"] = [(200, RetryFlowTests.status.replacingOccurrences(of: "\"search\"", with: "\"search\",\"deferred_transcription\""))]
        await m.refreshServer()
        m.engine.queue.sync {}
        return (m, root)
    }

    /// The fold label's totals for `day`, as `ShortClipsGroup` asks for them. (Red on 3d671f0 with the view's expression
    /// then: `HomeDay.totals(m.shortDayRows[day] ?? section.home.shortClips, server: m.shortDays[day] ?? section.totals)`.)
    func label(_ m: AppModel) throws -> ShortDay {
        let section = try #require(HomeDay.sections(m.recent, filter: .talk, shortSeconds: 60, shortDays: m.shortDays, day: { $0.day ?? "" }) { _ in "auto" }.first)
        return m.shortDayTotals(day: day, rows: section.home.shortClips, estimate: section.totals)
    }

    @Test func anEmptyAnswerWinsOverTheListsEstimate() async throws {
        let (m, root) = try await configured()
        defer { try? FileManager.default.removeItem(at: root) }
        m.recent = [ShortSessionsReviewTests().row("old", day: day, start: "2026-11-18T12:00:00Z", speech: 8)]
        m.shortDays[day] = ShortDay(short: 1)
        #expect(try label(m).short == 1)  // the list's estimate, before the day is asked
        AppServerStub.routes[path] = [(200, #"{"conversations":[],"next_cursor":null,"days":{}}"#)]
        await m.loadShortSessions(day: day)
        #expect(m.shortDayPhase(day: day, hasRows: false) == .empty)
        #expect(try label(m).short == 0, "the fold says 短片段 1 above 没有短片段")
    }

    @Test func aFailedLoadKeepsTheEstimate() async throws {
        let (m, root) = try await configured()
        defer { try? FileManager.default.removeItem(at: root) }
        m.recent = [ShortSessionsReviewTests().row("old", day: day, start: "2026-11-18T12:00:00Z", speech: 8)]
        m.shortDays[day] = ShortDay(short: 1)
        AppServerStub.routes[path] = [(503, #"{"error":"busy"}"#)]
        await m.loadShortSessions(day: day)
        #expect(m.shortDayPhase(day: day, hasRows: false) == .failed)
        #expect(try label(m).short == 1)  // nothing authoritative arrived: the estimate stays
    }
}
}
