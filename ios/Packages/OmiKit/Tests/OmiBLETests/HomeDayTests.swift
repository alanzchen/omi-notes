import OmiBLE
@testable import OmiProtocol
import Testing

/// Home folds short and skipped recordings into one collapsed row per day; nothing is dropped.
@Suite struct HomeDayTests {
    func conversation(_ id: String, _ status: String, seconds: Double?) -> ConversationSummary {
        var c = ConversationSummary(id: id, status: status)
        c.durationS = seconds
        return c
    }

    @Test func shortAndSkippedFoldAndNothingIsDropped() {
        let all = [
            conversation("long", "done", seconds: 600),
            conversation("short", "done", seconds: 12),
            conversation("skipped", "discarded", seconds: 300),
            conversation("listening", "open", seconds: 5),
            conversation("failed", "failed", seconds: 8),
            conversation("starred", "done", seconds: 10),
            conversation("demoted", "done", seconds: 9),
            conversation("unknown-length", "done", seconds: nil),
        ]
        let day = HomeDay(all) { c in c.id == "starred" ? "important" : c.id == "demoted" ? "less_useful" : "auto" }
        #expect(day.rows.map(\.id) == ["long", "listening", "failed", "starred", "unknown-length"])
        #expect(day.shortClips.map(\.id) == ["short", "skipped"])
        #expect(day.lessUseful.map(\.id) == ["demoted"])
        #expect(day.rows.count + day.shortClips.count + day.lessUseful.count == all.count)
    }

    @Test func anythingWrongStaysInViewHoweverShort() {
        var transcriptOnly = conversation("t", "failed", seconds: 5)
        transcriptOnly.notePath = "Notes/old.md"
        #expect(transcriptOnly.displayState.code == "transcript_only")
        #expect(!HomeDay.isShortClip(transcriptOnly), "a failed reprocess beside an older note")
        var conflict = conversation("c", "done", seconds: 5)
        conflict.issues = [ConversationFlag(code: "note_conflict", message: "Edited in both places")]
        #expect(!HomeDay.isShortClip(conflict))
        var retrying = conversation("r", "done", seconds: 5)
        retrying.state = ConversationFlag(code: "render_retrying", message: "Saving the note again")
        #expect(!HomeDay.isShortClip(retrying))
        var skippedWithIssue = conversation("s", "discarded", seconds: 5)
        skippedWithIssue.issues = [ConversationFlag(code: "x", message: "y")]
        #expect(!HomeDay.isShortClip(skippedWithIssue))
    }

    @Test func thirtySecondsIsNotShort() {
        #expect(!HomeDay.isShortClip(conversation("a", "done", seconds: 30)))
        #expect(HomeDay.isShortClip(conversation("b", "done", seconds: 29.9)))
    }
}
