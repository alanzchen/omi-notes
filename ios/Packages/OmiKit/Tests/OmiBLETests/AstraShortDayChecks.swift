// ASTRA-20261119-IT2 review checks (reused unchanged).
import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol

@MainActor @Suite(.serialized) struct AstraShortDayChecks {
    let day = "2026-11-18"
    let path = "/v1/conversations/recent"
    func configured() async throws -> (AppModel, URL) {
        let (m, root) = try RetryFlowTests().model()
        AppServerStub.routes["/v1/status"] = [(200, RetryFlowTests.status.replacingOccurrences(of: "\"search\"", with: "\"search\",\"deferred_transcription\""))]
        await m.refreshServer()
        #expect(m.serverStatus?.supportsDeferredTranscription == true)
        m.engine.queue.sync {}
        return (m, root)
    }
    func empty() -> String { #"{"conversations":[],"next_cursor":null,"days":{"2026-11-18":{"short":0,"deferred":0,"requested":0,"issues":0}}}"# }
    func nonempty() -> String { #"{"conversations":[{"id":"new","status":"done","day":"2026-11-18","speech_s":8}],"next_cursor":null,"days":{"2026-11-18":{"short":1,"deferred":0,"requested":0,"issues":0}}}"# }

    @Test func oldFailedLoadMustNotOverrideNewSuccessfulLoad() async throws {
        let (m, root) = try await configured()
        defer { try? FileManager.default.removeItem(at: root) }
        AppServerStub.holdNext.insert(path)
        let old = Task { await m.loadShortSessions(day: day) }
        try await AppServerStub.waitUntilHeld(path)
        AppServerStub.routes[path] = [(200, empty())]
        await m.loadShortSessions(day: day)
        #expect(m.shortDayRows[day]?.isEmpty == true)
        #expect(!m.shortDayFailed.contains(day))
        AppServerStub.release(path, offline: true)
        await old.value
        #expect(!m.shortDayFailed.contains(day), "older failed request must not mark newer successful day as failed")
    }

    @Test func retryMustReplaceFailureWhileItIsLoading() async throws {
        let (m, root) = try await configured()
        defer { try? FileManager.default.removeItem(at: root) }
        AppServerStub.routes[path] = [(500, #"{"error":"test","detail":"synthetic"}"#)]
        await m.loadShortSessions(day: day)
        #expect(m.shortDayFailed.contains(day))
        AppServerStub.holdNext.insert(path)
        let retry = Task { await m.loadShortSessions(day: day) }
        try await AppServerStub.waitUntilHeld(path)
        #expect(!m.shortDayFailed.contains(day), "the retry is running but the view still presents failed + enabled Retry")
        AppServerStub.routes[path] = [(200, nonempty())]
        AppServerStub.release(path, offline: false)
        await retry.value
        #expect(!m.shortDayFailed.contains(day))
    }

    @Test func completedEmptyDayMustNotSelectSpinner() async throws {
        let (m, root) = try await configured()
        defer { try? FileManager.default.removeItem(at: root) }
        m.recent = [ShortSessionsReviewTests().row("old", day: day, start: "2026-11-18T12:00:00Z", speech: 8)]
        m.shortDays[day] = ShortDay(short: 1)
        AppServerStub.routes[path] = [(200, empty())]
        await m.loadShortSessions(day: day)
        #expect(m.shortDayRows[day]?.isEmpty == true)
        #expect(!m.shortDayFailed.contains(day))
        let section = try #require(HomeDay.sections(m.recent, filter: .talk, shortSeconds: 60, shortDays: m.shortDays, day: { $0.day ?? "" }) { _ in "auto" }.first)
        let shown = m.shortDayRows[day] ?? section.home.shortClips
        // Exact conditions in ShortClipsGroup; source-derived view state, not a SwiftUI render. (2026-11-19 R4: the view now
        // takes its choice from `shortDayPhase`, so this check asks it rather than repeating the old inline condition.)
        let spinnerSelected = section.showsFold && m.shortDayPhase(day: day, hasRows: !HomeDay.byKind(shown).isEmpty) == .loading
        #expect(!spinnerSelected, "a completed successful empty response still selects ProgressView indefinitely")
    }

    @Test func differentDaySuccessPreservesFailureUntilThatDaySucceeds() async throws {
        let (m, root) = try await configured()
        defer { try? FileManager.default.removeItem(at: root) }
        m.finishShortDay(day, .failure(URLError(.cannotConnectToHost)))
        AppServerStub.routes[path] = [(200, empty())]
        await m.loadShortSessions(day: "2026-11-17")
        #expect(m.shortDayFailed.contains(day))
        await m.loadShortSessions(day: day)
        #expect(!m.shortDayFailed.contains(day))
    }

    @Test func serverChangeDropsOldFailureAndOfflineConfigurationStaysConfigured() async throws {
        let (m, root) = try await configured()
        defer { try? FileManager.default.removeItem(at: root) }
        AppServerStub.holdNext.insert(path)
        let old = Task { await m.loadShortSessions(day: day) }
        try await AppServerStub.waitUntilHeld(path)
        try m.engine.settings.setServer(url: URL(string:"https://second.invalid")!, token:"test")
        await m.refreshServer()
        AppServerStub.release(path, offline: true)
        await old.value
        #expect(m.shortDayFailed.isEmpty)
        #expect(m.shortDayRows.isEmpty)
        AppServerStub.offline = true
        await m.refreshServer()
        #expect(m.serverURL != nil, "Home's search gate remains true while a configured server is offline")
    }
}
