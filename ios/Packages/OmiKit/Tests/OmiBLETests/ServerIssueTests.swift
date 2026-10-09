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
}
