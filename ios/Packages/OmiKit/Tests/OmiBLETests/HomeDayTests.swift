import OmiBLE
import OmiProtocol
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

    @Test func thirtySecondsIsNotShort() {
        #expect(!HomeDay.isShortClip(conversation("a", "done", seconds: 30)))
        #expect(HomeDay.isShortClip(conversation("b", "done", seconds: 29.9)))
    }
}
