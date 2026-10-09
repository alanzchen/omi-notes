import Foundation
import Testing
@testable import OmiProtocol

@Suite struct ServerIssueTests {
    @Test func plainGuidanceAndServerStepsAreSeparate() throws {
        let json = #"{"issues":[{"code":"conversation_failed","severity":"action","message":"m","next_step":"This needs a fix on the server.","server_step":"run `omi-notes retry-failed`","retryable":false,"conversation_id":"c1"}]}"#
        let issue = try JSONDecoder().decode(ServerIssuesResponse.self, from: Data(json.utf8)).issues[0]
        #expect(issue.serverStep == "run `omi-notes retry-failed`" && issue.retryable == false && !issue.canRetryFromPhone == true)
        #expect(issue.phoneStep == "This needs a fix on the server.")
    }

    @Test func olderServersKeepWorkingAndCommandsStayOffTheMainScreen() throws {
        // An older server put its command in next_step and had no retryable flag.
        let json = #"{"issues":[{"code":"conversation_failed","severity":"action","message":"m","next_step":"Fix it, then run `omi-notes retry-failed`.","conversation_id":"c1"}]}"#
        let issue = try JSONDecoder().decode(ServerIssuesResponse.self, from: Data(json.utf8)).issues[0]
        #expect(issue.canRetryFromPhone && issue.phoneStep == nil)
        #expect(issue.serverStep == nil && issue.technicalStep == "Fix it, then run `omi-notes retry-failed`.")
    }

    @Test func retryStatesAreWordedFromTheState() throws {
        func op(_ state: String, _ message: String? = "Waiting for the server to start") throws -> RetryOperation {
            try JSONDecoder().decode(RetryOperation.self, from: Data(#"{"id":"o","state":"\#(state)","message":\#(message.map { "\"\($0)\"" } ?? "null")}"#.utf8))
        }
        #expect(try op("queued").displayMessage == "Queued on the server")
        #expect(try op("accepted").displayMessage == "Queued on the server")
        #expect(try op("running").displayMessage == "Retrying now")
        #expect(try op("failed", "The retry failed again").displayMessage == "The retry failed again")
    }

    @Test func aNoSpeakerResultOffersKeepAndOlderServersDoNot() throws {
        let json = #"{"issues":[{"code":"conversation_failed","severity":"action","message":"m","retryable":false,"can_keep":true,"conversation_id":"c1"},{"code":"conversation_failed","severity":"action","message":"m","conversation_id":"c2"}]}"#
        let issues = try JSONDecoder().decode(ServerIssuesResponse.self, from: Data(json.utf8)).issues
        #expect(issues[0].canKeepFromPhone && !issues[0].canRetryFromPhone)
        #expect(!issues[1].canKeepFromPhone && issues[1].canRetryFromPhone)
    }

    @Test func aKeptConversationKeepsItsHistoryAndNamesNoSpeaker() throws {
        let json = #"""
        {"id":"c1","status":"done","state":{"code":"kept_speaker_unknown","message":"Kept as a transcript; the speaker is unknown"},
         "speech_s":0.35,"duration_s":3.2,"summary_state":"not_applicable","transcript_state":"ready",
         "speakers":[{"label":"unknown","name":null}],
         "transcript":{"total":1,"from":0,"next_from":null,"segments":[{"start":"2026-09-29T22:08:09.000Z","end":"2026-09-29T22:08:10.000Z","speaker":"unknown","name":null,"text":"t"}]},
         "resolution":{"kind":"kept_speaker_unknown","resolved_at":"2026-10-09T20:00:00.000Z","message":"Kept from the phone as a transcript with the speaker unknown.",
                       "original":{"code":"speakers_unknown","stage":"transcribing","message":"Words were transcribed, but no speaker was found."}}}
        """#
        let d = try JSONDecoder().decode(ConversationDetail.self, from: Data(json.utf8))
        #expect(d.resolution?.original?.code == "speakers_unknown" && d.resolution?.resolvedAt != nil)
        #expect(d.speakerName("unknown") == "Speaker unknown")
        // a saved copy decodes the same (the phone shows it offline after a relaunch)
        let again = try JSONDecoder().decode(ConversationDetail.self, from: JSONEncoder().encode(d))
        #expect(again.resolution == d.resolution)
    }

    @Test func keepStatesAreWordedAsAKeep() throws {
        let op = try JSONDecoder().decode(RetryOperation.self, from: Data(#"{"id":"o","kind":"keep","state":"running"}"#.utf8))
        #expect(op.displayMessage == "Keeping it now")
    }
}
