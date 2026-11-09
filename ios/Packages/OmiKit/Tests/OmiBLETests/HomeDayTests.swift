import Foundation
import OmiBLE
@testable import OmiProtocol
import Testing

/// Home folds short sessions (under a minute of speech) into one row per day, whatever the filter; the filter
/// picks the main list's kind, and anything not yet known stays with the conversations. Nothing is dropped.
@Suite struct HomeDayTests {
    func conversation(_ id: String, _ status: String, speech: Double?, kind: String? = nil, seconds: Double? = nil) -> ConversationSummary {
        var c = ConversationSummary(id: id, status: status)
        c.speechS = speech
        c.durationS = seconds ?? speech.map { $0 * 2 }
        if let kind { c.recordingClass = RecordingClassView(kind: kind) }
        return c
    }

    @Test func shortSessionsFoldWhateverTheFilterAndNothingIsDropped() {
        let all = [
            conversation("talk", "done", speech: 600, kind: "dialogue"),
            conversation("me", "done", speech: 300, kind: "monologue"),
            conversation("bg", "done", speech: 120, kind: "passive"),
            conversation("unknown-kind", "done", speech: 90, kind: "something-new"),
            conversation("unclassified", "done", speech: 90),
            conversation("short-done", "done", speech: 40, kind: "monologue"),
            conversation("short-deferred", "closed", speech: 12, kind: "undetermined"),
            conversation("short-failed", "failed", speech: 20),
            conversation("listening", "open", speech: 5),
            conversation("demoted", "done", speech: 200, kind: "dialogue"),
        ]
        let priority: (ConversationSummary) -> String = { $0.id == "demoted" ? "less_useful" : "auto" }
        let talk = HomeDay(all, filter: .talk, priority: priority)
        #expect(talk.rows.map(\.id) == ["talk", "unknown-kind", "unclassified", "listening"])
        #expect(talk.lessUseful.map(\.id) == ["demoted"])
        #expect(talk.shortClips.map(\.id) == ["short-done", "short-deferred", "short-failed"])
        #expect(HomeDay(all, filter: .me, priority: priority).rows.map(\.id) == ["me"])
        let background = HomeDay(all, filter: .background, priority: priority)
        #expect(background.rows.map(\.id) == ["bg"] && background.shortClips.count == 3, "the fold doesn't follow the filter")
        let every = HomeDay(all, priority: priority)
        #expect(every.rows.count + every.shortClips.count + every.lessUseful.count == all.count)
    }

    @Test func sixtySecondsOfSpeechIsNotShortAndElapsedTimeDoesntCount() {
        #expect(!conversation("a", "done", speech: 60, seconds: 60).isShort(threshold: 60))
        #expect(conversation("b", "done", speech: 59.9, seconds: 900).isShort(threshold: 60), "a long span with little speech")
        #expect(!conversation("c", "open", speech: 3).isShort(threshold: 60), "an open session may still grow")
    }

    @Test func olderServersWithoutSpeechKeepTheEarlierFold() {
        #expect(conversation("a", "done", speech: nil, seconds: 29.9).isShort(threshold: 60))
        #expect(!conversation("b", "done", speech: nil, seconds: 45).isShort(threshold: 60))
        #expect(conversation("c", "discarded", speech: nil, seconds: 300).isShort(threshold: 60))
        #expect(!conversation("d", "failed", speech: nil, seconds: 5).isShort(threshold: 60))
    }

    @Test func theFoldSplitsByKindWithEverythingUnknownAsUndetermined() {
        let clips = [conversation("u1", "closed", speech: 9, kind: "undetermined"), conversation("m", "done", speech: 30, kind: "monologue"),
                     conversation("u2", "closed", speech: 9), conversation("d", "done", speech: 30, kind: "dialogue"),
                     conversation("u3", "done", speech: 9, kind: "future-kind")]
        let groups = HomeDay.byKind(clips)
        #expect(groups.map(\.kind) == ["dialogue", "monologue", "undetermined"])
        #expect(groups.last?.rows.map(\.id) == ["u1", "u2", "u3"])
        #expect(HomeDay.byKind([conversation("u", "closed", speech: 9, kind: "undetermined")]).map(\.kind) == ["undetermined"])
    }

    @Test func theFoldsCountsAreTheWholeDaysWhateverIsLoaded() {
        var waiting = conversation("w", "closed", speech: 9, kind: "undetermined")
        waiting.deferred = DeferredTranscription(state: "waiting")
        var asked = conversation("r", "closed", speech: 9, kind: "undetermined")
        asked.deferred = DeferredTranscription(state: "requested", operationId: "op")
        let failed = conversation("f", "failed", speech: 9)
        let local = HomeDay.totals([waiting, asked, failed], server: nil)
        #expect(local == ShortDay(short: 3, deferred: 1, requested: 1, issues: 1))
        // the server counted the whole day: two more on a page not loaded yet, one of them failed
        let server = HomeDay.totals([waiting], server: ShortDay(short: 5, deferred: 2, requested: 1, issues: 2))
        #expect(server == ShortDay(short: 5, deferred: 2, requested: 1, issues: 2))
    }
}
