import Foundation
import Testing
@testable import OmiProtocol

@Suite struct ConversationSummaryTests {
    private func summary(_ fields: String) throws -> ConversationSummary {
        try JSONDecoder().decode(ConversationSummary.self, from: Data("{\"id\":\"conversation\",\(fields)}".utf8))
    }

    @Test func speakerAvailabilityFollowsServerReadiness() throws {
        #expect(try summary(#""status":"open","speakers_ready":false"#).canReviewSpeakers == false)
        #expect(try summary(#""status":"summarizing","speakers_ready":true"#).canReviewSpeakers == true)
        #expect(try summary(#""status":"failed","speakers_ready":true"#).canReviewSpeakers == true)
        #expect(try summary(#""status":"done","note_path":"note.md","speakers_ready":false"#).canReviewSpeakers == false)
    }

    @Test func olderServersOnlyOfferCompletedNotes() throws {
        #expect(try summary(#""status":"open""#).canReviewSpeakers == false)
        #expect(try summary(#""status":"discarded""#).canReviewSpeakers == false) // enrollment has no note
        #expect(try summary(#""status":"done","note_path":"note.md""#).canReviewSpeakers == true)
        #expect(try summary(#""status":"discarded","note_path":"_discarded/note.md""#).canReviewSpeakers == true)
    }
}
