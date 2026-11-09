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

    @Test func recordingClassIsTheAppliedKindWithTheRequestedOneApart() throws {
        let c = try summary(#""status":"done","recording_class":{"class":"dialogue","auto":"dialogue","confidence":"high","#
                            + #""overridden":false,"wearer_share":0.4,"updating":true,"requested":"monologue","#
                            + #""set_at":"2026-11-08T20:00:00Z"}"#)
        #expect(c.recordingClass?.kind == "dialogue", "a requested kind is never shown as applied")
        #expect(c.recordingClass?.isUpdating == true && c.recordingClass?.requested == "monologue")
        #expect(c.recordingClass?.wearerShare == 0.4)
        #expect(try summary(#""status":"done","recording_class":null"#).recordingClass == nil)
        #expect(try summary(#""status":"done""#).recordingClass == nil, "servers without recording classes")
    }

    @Test func anUnreadableChoiceKeepsTheAppliedKind() throws {
        let view = try JSONDecoder().decode(RecordingClassView.self, from: Data(
            #"{"class":"passive","auto":"passive","confidence":"medium","overridden":false,"wearer_share":0.0,"updating":false,"#
                .appending(#""choice_unreadable":"class.json can't be read","applied":true}"#).utf8))
        #expect(view.kind == "passive" && view.choiceUnreadable != nil && !view.isUpdating)
    }
}
