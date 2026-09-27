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
