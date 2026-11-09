import Foundation
import Testing
@testable import OmiProtocol

/// The note's Speakers section: a few speakers by talk time (named people first), the rest folded.
/// Build-42 feedback (2026-11-08): a two-person call listed "Speaker 1 … Speaker 41" as one paragraph.
@Suite struct SpeakerRosterTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func seg(_ label: String, _ from: Double, _ seconds: Double, name: String? = nil) -> ConversationDetail.Segment {
        ConversationDetail.Segment(start: ISO8601UTC.format(t0.addingTimeInterval(from)), end: ISO8601UTC.format(t0.addingTimeInterval(from + seconds)),
                                   speaker: label, name: name, text: "x")
    }

    func speakers(_ n: Int, named: [String: String] = [:]) -> [ConversationDetail.Speaker] {
        (1...n).map { ConversationDetail.Speaker(label: "S\($0)", name: named["S\($0)"]) }
    }

    /// The phone call of the feedback: two voices did nearly all the talking, 39 more labels a few seconds each.
    func call(named: [String: String] = [:]) -> SpeakerRoster {
        var segments = [seg("S1", 0, 600), seg("S2", 600, 420)]
        for i in 3...41 { segments.append(seg("S\(i)", 1_100 + Double(i) * 10, 2)) }
        return SpeakerRoster.make(speakers: speakers(41, named: named), segments: segments)
    }

    @Test func manyTinyUnnamedSpeakersFoldBehindTheTopVoices() {
        let r = call()
        #expect(r.count == 41)
        #expect(r.top.map(\.label) == ["S1", "S2"], "tiny unnamed voices aren't chips")
        #expect(r.rest.count == 39)
        #expect(r.top[0].seconds == 600 && r.top[0].displayName == "Speaker 1")
    }

    @Test func namedPeopleComeFirstEvenWithLittleTalk() {
        let r = call(named: ["S7": "Alan"])
        #expect(r.top.map(\.displayName) == ["Alan", "Speaker 1", "Speaker 2"])
        #expect(r.rest.count == 38 && !r.rest.contains { $0.label == "S7" })
    }

    @Test func atMostAFewChipsAndTheRestInTalkOrder() {
        let segments = (1...6).map { seg("S\($0)", Double($0) * 100, Double(100 - $0 * 10)) }
        let r = SpeakerRoster.make(speakers: speakers(6), segments: segments)
        #expect(r.top.map(\.label) == ["S1", "S2", "S3"])
        #expect(r.rest.map(\.label) == ["S4", "S5", "S6"])
    }

    @Test func aSingleLeftoverIsShownRatherThanFolded() {
        let r = SpeakerRoster.make(speakers: speakers(2), segments: [seg("S1", 0, 300), seg("S2", 300, 3)])
        #expect(r.top.map(\.label) == ["S1", "S2"] && r.rest.isEmpty, "no \"+1 more\"")
    }

    @Test func withoutTalkTimeTheFirstFewAreShownInLabelOrder() {
        let r = SpeakerRoster.make(speakers: speakers(12), segments: [])
        #expect(r.top.map(\.label) == ["S1", "S2", "S3"] && r.rest.count == 9)
        #expect(r.rest.first?.label == "S4" && r.rest.last?.label == "S12", "S10 after S9, not after S1")
    }

    @Test func evenlySpreadTalkStillShowsSomeone() {
        let segments = (1...30).map { seg("S\($0)", Double($0) * 10, 5) }
        let r = SpeakerRoster.make(speakers: speakers(30), segments: segments)
        #expect(!r.top.isEmpty && r.top.count + r.rest.count == 30)
    }

    @Test func labelsOnlyInTheTranscriptAreCountedToo() {
        let r = SpeakerRoster.make(speakers: [.init(label: "S1", name: "Alan")], segments: [seg("S1", 0, 60, name: "Alan"), seg("S2", 60, 40)])
        #expect(r.count == 2 && r.top.map(\.displayName) == ["Alan", "Speaker 2"])
    }

    @Test func talkTimeReadsShort() {
        #expect(SpeakerRoster.talkText(0.4) == "<1s")
        #expect(SpeakerRoster.talkText(45) == "45s")
        #expect(SpeakerRoster.talkText(600) == "10m")
        #expect(SpeakerRoster.talkText(3_900) == "1h 5m")
        #expect(SpeakerRoster.talkText(7_200) == "2h")
    }
}
