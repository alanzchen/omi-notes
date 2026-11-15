import Foundation
import Testing
@testable import OmiProtocol

/// Decoding the app views. The "current" payloads were captured from the real backend
/// (fake providers) so the Swift types track what the server actually sends.
@Suite struct AppViewsDecodingTests {
    static let status = #"{"ok": true, "server_version": "0.1.0", "protocol_version": 1, "server_time": "2026-09-27T22:20:31.150Z", "server_started_at": "2026-09-27T22:20:31.057Z", "stt": {"provider": "fake", "model": "fake-stt", "diarization": "auto", "ready": true}, "llm": {"provider": "fake", "model": "fake-llm", "ready": true}, "queue": {"chunks_pending": 0, "conversations_open": 0, "conversations_pending": 0, "failed": 0, "conversations_failed": 0, "chunks_failed": 0, "conversations_retrying": 0, "notes_conflicted": 0}, "worker": {"present": false}, "last_note_at": "2026-09-26T19:06:40.000Z", "vault_dir": "/var/folders/s4/x210ybkn0rl1r8spzgcgxg6w0000gr/T/tmpt_n68ntd/notes", "notes_dir": "/var/folders/s4/x210ybkn0rl1r8spzgcgxg6w0000gr/T/tmpt_n68ntd/notes", "read_only": null, "features": ["voice_enrollment", "conversation_detail", "issues"]}"#
    static let recent = #"{"conversations": [{"id": "01a0df16-af68-7236-88dd-0f3fda13b580", "status": "done", "state": {"code": "ready", "message": "Note ready"}, "issues": [], "started_at": "2026-09-26T19:00:01.000Z", "ended_at": "2026-09-26T19:00:13.000Z", "duration_s": 12.0, "title": "Fake Conversation With 1 Segments", "emoji": "🧪", "preview": "Deterministic fake summary of 1 transcript segments.", "speaker_names": [], "note_path": "Conversations/2026/2026-09/2026-09-26 1400 Fake Conversation With 1 Segments.md", "late_audio": false, "provisional": false, "speakers_ready": true}], "next_cursor": null}"#
    static let detail = #"{"id": "01a0df16-af68-7236-88dd-0f3fda13b580", "status": "done", "state": {"code": "ready", "message": "Note ready"}, "issues": [], "started_at": "2026-09-26T19:00:01.000Z", "ended_at": "2026-09-26T19:00:13.000Z", "duration_s": 12.0, "title": "Fake Conversation With 1 Segments", "emoji": "🧪", "preview": "Deterministic fake summary of 1 transcript segments.", "speaker_names": [], "note_path": "Conversations/2026/2026-09/2026-09-26 1400 Fake Conversation With 1 Segments.md", "late_audio": false, "provisional": false, "speakers_ready": true, "speech_s": 12.0, "lost_s": 0.0, "note_state": "matches", "note_frozen": false, "my_notes": null, "my_notes_unreadable": false, "discard_reason": null, "transcript_sha": "7de7560c5c1b9cd1c9809a018266cc8884b839d1638370dce858b2fbceaa1a0a", "speakers_revision": 0, "revision": 1, "summary_state": "ready", "summary": {"overview": "Deterministic fake summary of 1 transcript segments.", "sections": [{"heading": "What Was Said", "bullets": ["We should review the quarterly plan and send the updated budget to the team before friday so everyone can agree on the launch date."]}], "action_items": [{"description": "Review the fake transcript", "owner": "unknown", "owner_name": null, "due_date": null}], "decisions": [], "open_questions": []}, "transcript_state": "ready", "speakers": [{"label": "S1", "name": null}], "transcript": {"total": 1, "from": 0, "next_from": null, "segments": [{"start": "2026-09-26T19:00:00.700Z", "end": "2026-09-26T19:00:14.000Z", "speaker": "S1", "name": null, "text": "We should review the quarterly plan and send the updated budget to the team before friday so everyone can agree on the launch date."}]}}"#
    static let issues = #"{"issues": [{"code": "worker_stopped", "severity": "action", "message": "The processing worker isn't running.", "next_step": "Restart the omi-notes service on the Mac."}]}"#
    static let olderStatus = #"{"ok": true, "server_version": "0.1.0", "protocol_version": 1, "stt": {"provider": "deepgram", "ready": true}, "llm": {"provider": "anthropic", "ready": true}, "queue": {"chunks_pending": 0, "conversations_open": 1, "conversations_pending": 0, "failed": 2}, "notes_dir": "/x", "features": ["voice_enrollment"]}"#
    static let olderRecent = #"{"conversations": [{"id": "a", "status": "failed", "started_at": "2026-09-26T19:00:00.000Z", "ended_at": "2026-09-26T19:05:00.000Z", "title": null, "note_path": "n.md", "late_audio": false, "provisional": false}]}"#

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func aPartialTranscriptShowsEachGapWhereItWas() throws {
        // 2026-11-15: the app showed a transcript with a stretch nobody could put into words as if it were complete
        let page = { (gaps: String, next: String) in #"{"total": 3, "from": 0, "next_from": \#(next), "segments": [{"start": "2026-11-14T23:03:00.000Z", "end": "2026-11-14T23:03:05.000Z", "speaker": "S1", "name": null, "text": "a"}, {"start": "2026-11-14T23:03:30.000Z", "end": "2026-11-14T23:03:35.000Z", "speaker": "S2", "name": null, "text": "b"}]\#(gaps)}"# }
        let gaps = #", "untranscribed": [{"start": "2026-11-14T23:03:40.000Z", "end": "2026-11-14T23:03:55.000Z", "speech_s": 12.5}, {"start": "2026-11-14T23:03:10.000Z", "end": "2026-11-14T23:03:25.000Z", "speech_s": 9.6}]"#
        let full = try decode(ConversationDetail.Transcript.self, page(gaps, "null"))
        #expect(full.untranscribed?.count == 2 && full.untranscribed?.first?.speechS == 12.5)
        let rows = full.rows
        #expect(rows.count == 4 && rows[0] == .segment(0) && rows[2] == .segment(1))
        if case .gap(let g) = rows[1] { #expect(g.speechS == 9.6) } else { Issue.record("the earlier gap sits between the two segments") }
        if case .gap(let g) = rows[3] { #expect(g.speechS == 12.5) } else { Issue.record("the later gap follows the last segment") }
        // more pages to come: a gap after the last segment shown may belong between later ones, so it waits
        #expect(try decode(ConversationDetail.Transcript.self, page(gaps, "2")).rows.count == 3)
        // an older server, or no gap: just the segments
        #expect(try decode(ConversationDetail.Transcript.self, page("", "null")).rows == [.segment(0), .segment(1)])
    }

    /// A transcript page for the gap tests: segments and gaps at seconds after a fixed base.
    private func gapPage(_ segs: [(Double, Double)], _ gaps: [(Double, Double, Double)]?, from: Int = 0, next: Int? = nil,
                         total: Int? = nil, incomplete: Bool? = nil) throws -> ConversationDetail.Transcript {  // fmt: skip
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ x: Double) -> String { ISO8601UTC.format(base.addingTimeInterval(x)) }
        var d: [String: Any] = ["total": total ?? segs.count, "from": from, "next_from": next as Any? ?? NSNull(),
                                "segments": segs.map { ["start": at($0.0), "end": at($0.1), "speaker": "S1", "text": "synthetic"] }]  // fmt: skip
        if let gaps { d["untranscribed"] = gaps.map { ["start": at($0.0), "end": at($0.1), "speech_s": $0.2] } }
        if let incomplete { d["untranscribed_incomplete"] = incomplete }
        return try JSONDecoder().decode(ConversationDetail.Transcript.self, from: JSONSerialization.data(withJSONObject: d))
    }

    private func gapRows(_ t: ConversationDetail.Transcript) -> [ConversationDetail.Gap] {
        t.rows.compactMap { if case .gap(let g) = $0 { g } else { nil } }
    }

    @Test func repeatedOverlappingOrImpossibleGapsAreShownOnceOrNotAtAll() throws {
        // ASTRA-20261115-IT2-03: two identical stretches made two rows, overlapping ones two warnings for the same
        // speech, and impossible ones (no speech, reversed, more speech than the stretch) a row with an invented amount
        #expect(gapRows(try gapPage([(0, 5), (20, 25)], [(6, 9, 3), (6, 9, 3)])).count == 1)
        let overlap = gapRows(try gapPage([(0, 5), (20, 25)], [(6, 10, 4), (8, 12, 4)]))
        #expect(overlap.count == 1 && overlap[0].speechS == 6, "6-12 s: 8 s claimed is capped at its 6 s")
        let bad = try gapPage([(0, 5), (20, 25)], [(6, 9, 0), (7, 10, -5), (11, 10, 1), (12, 13, 1e12)])
        #expect(gapRows(bad).isEmpty && bad.droppedGaps, "left out, and said so")
    }

    @Test func eachPageAddsItsOwnGapsAndTheTailWaitsForTheLastPage() throws {
        // ASTRA-20261115-IT2-02: pages carry only the stretches they own; the phone keeps them all, once each
        var detail = try JSONDecoder().decode(ConversationDetail.self, from: Data(Self.detail.utf8))
        detail.transcript = try gapPage([(0, 5), (10, 15)], [(-3, -1, 2), (7, 8, 1), (17, 18, 1)], next: 2, total: 3)
        #expect(gapRows(detail.transcript!).count == 2, "17-18 s may belong after a later segment: it waits")
        detail.append(try gapPage([(20, 25)], [(30, 32, 2), (7, 8, 1)], from: 2, total: 3, incomplete: true))
        #expect(detail.transcript!.untranscribed?.count == 4 && gapRows(detail.transcript!).count == 4)
        #expect(detail.transcript!.rows.map { if case .segment(let i) = $0 { i } else { -1 } } == [-1, 0, -1, 1, -1, 2, -1])
        #expect(detail.transcript!.untranscribedIncomplete == true)
    }

    @Test func preparedRowsCostLittleAndReadingThemCostsNothing() throws {
        // ASTRA-20261115-IT2-01: the view's rows parsed every segment's time on every draw (791 ms for 3,000 lines
        // without a gap, optimized). They are prepared once; a bound generous enough for a loaded CI host
        let segs = (0..<3000).map { (Double($0 * 4), Double($0 * 4 + 2)) }
        let plain = try gapPage(segs, nil)
        var clock = ContinuousClock.now
        for _ in 0..<1000 { _ = plain.rows.count }
        #expect(ContinuousClock.now - clock < .milliseconds(50) && plain.rows.count == 3000)
        let gaps = (0..<1000).map { i in let k = (i * 337) % 1000; return (Double(k * 4 + 2), Double(k * 4 + 3), 1.0) }
        clock = ContinuousClock.now
        let gapped = try gapPage(segs, gaps)
        let prepared = ContinuousClock.now - clock
        #expect(prepared < .seconds(2) && gapRows(gapped).count == 1000, "prepared once in \(prepared)")
        clock = ContinuousClock.now
        for _ in 0..<1000 { _ = gapped.rows.count }
        #expect(ContinuousClock.now - clock < .milliseconds(50))
    }

    @Test func appendingAPageReadsOnlyItsOwnSegmentsTimes() throws {
        // ASTRA-20261115-IT4-04: an append re-read every loaded segment's time on the main actor (201 ms for 500 onto
        // 3,000 with one gap, optimized). Loaded times are kept; a bound generous enough for a loaded CI host
        for gapCount in [1, 1000] {
            let gaps = (0..<gapCount).map { i in let k = (i * 337) % 3500; return (Double(k * 4 + 2), Double(k * 4 + 3), 1.0) }
            var t = try gapPage((0..<3000).map { (Double($0 * 4), Double($0 * 4 + 2)) }, gaps, next: 3000, total: 3500)
            let more = try gapPage((3000..<3500).map { (Double($0 * 4), Double($0 * 4 + 2)) }, nil, from: 3000, total: 3500)
            let clock = ContinuousClock.now
            t.append(more)
            let took = ContinuousClock.now - clock
            let bound: Duration = _isDebugAssertConfiguration() ? .seconds(1) : .milliseconds(150)  // optimized: the real bound
            #expect(took < bound && t.segments.count == 3500, "appended in \(took)")
            #expect(gapRows(t).count == Set(gaps.map(\.0)).count, "every stretch placed once the last page is in")
        }
    }

    @Test func currentStatus() throws {
        let s = try decode(ServerStatus.self, Self.status)
        #expect(s.worker?.present == false && s.readOnly == nil && s.lastNoteAt != nil)
        #expect(s.queue?.conversationsFailed == 0 && s.queue?.chunksFailed == 0 && s.queue?.notesConflicted == 0)
        #expect(s.stt?.model == "fake-stt" && s.llm?.model == "fake-llm")
        #expect(s.supportsConversationDetail && s.supportsIssues && s.supportsVoiceEnrollment)
    }

    @Test func olderStatusLeavesNewFieldsUnknown() throws {
        let s = try decode(ServerStatus.self, Self.olderStatus)
        #expect(s.worker == nil && s.lastNoteAt == nil && s.queue?.conversationsFailed == nil && s.queue?.failed == 2)
        #expect(!s.supportsConversationDetail && !s.supportsIssues)
    }

    @Test func currentRecentPage() throws {
        let page = try decode(RecentConversationsResponse.self, Self.recent)
        let c = try #require(page.conversations.first)
        #expect(page.nextCursor == nil)
        #expect(c.displayState.code == "ready" && c.preview != nil && c.duration == 12 && c.speakerNames == [])
    }

    @Test func olderRecentDerivesAState() throws {
        let page = try decode(RecentConversationsResponse.self, Self.olderRecent)
        let c = try #require(page.conversations.first)
        #expect(page.nextCursor == nil && c.state == nil)
        #expect(c.displayState.code == "transcript_only" && c.duration == 300)
    }

    @Test func currentDetail() throws {
        let d = try decode(ConversationDetail.self, Self.detail)
        #expect(d.entry.status == "done" && d.summaryState == "ready" && d.transcriptState == "ready")
        #expect(d.summary?.actionItems.first?.description == "Review the fake transcript")
        #expect(d.transcript?.segments.count == d.transcript?.total && d.noteState == "matches")
        #expect(d.speakerName("S1") == "Speaker 1")
        #expect(d.summary?.assistantRequests == nil, "servers before assistant requests were listed apart")
    }

    @Test func assistantRequestsStayApartFromActionItems() throws {
        let json = Self.detail.replacingOccurrences(of: #""decisions": [], "open_questions": []"#,
                                                    with: #""assistant_requests": [{"description": "Draft the hotel email"}], "decisions": [], "open_questions": []"#)
        let d = try decode(ConversationDetail.self, json)
        #expect(d.summary?.assistantRequests?.map(\.description) == ["Draft the hotel email"])
        #expect(d.summary?.actionItems.map(\.description) == ["Review the fake transcript"])
    }

    @Test func detailOfAnOpenConversation() throws {
        let json = #"{"id":"x","status":"open","state":{"code":"listening","message":"Waiting"},"summary_state":"pending","summary":null,"transcript_state":"pending","transcript":null,"speakers":[]}"#
        let d = try decode(ConversationDetail.self, json)
        #expect(d.summary == nil && d.transcript == nil && d.entry.displayState.code == "listening")
    }

    @Test func transcriptPagesAppendOnlyInOrder() throws {
        var d = try decode(ConversationDetail.self, #"{"id":"x","status":"done","summary_state":"ready","transcript_state":"ready","speakers":[],"transcript":{"total":3,"from":0,"next_from":1,"segments":[{"start":"a","end":"b","speaker":"S1","text":"one"}]}}"#)
        let skip = ConversationDetail.Transcript(total: 3, from: 2, nextFrom: nil, segments: [])
        d.append(skip)
        #expect(d.transcript?.segments.count == 1)
        let next = ConversationDetail.Transcript(total: 3, from: 1, nextFrom: nil,
                                                 segments: [.init(start: "b", end: "c", speaker: "S2", name: "Priya", text: "two")])
        d.append(next)
        #expect(d.transcript?.segments.map(\.text) == ["one", "two"] && d.transcript?.nextFrom == nil)
    }

    @Test func issues() throws {
        let r = try decode(ServerIssuesResponse.self, Self.issues)
        #expect(r.issues.first?.code == "worker_stopped" && r.issues.first?.needsAction == true)
    }
}
