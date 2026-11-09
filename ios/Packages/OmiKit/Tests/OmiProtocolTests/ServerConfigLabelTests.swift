import Foundation
import Testing
@testable import OmiProtocol

/// The Server page's configuration rows: one short line each, with the full model names kept for
/// the details. Build-42 feedback (2026-11-08): long values wrapped into multi-line right-aligned text.
@Suite struct ServerConfigLabelTests {
    /// The live deployment's `/v1/status` with the local sidecar (2026-11-09, trimmed to the fields used).
    static let local = #"{"ok": true, "server_version": "0.1.0", "protocol_version": 1, "stt": {"provider": "local", "model": "MOSS-Transcribe-Diarize (speakers) · Qwen3-ASR-1.7B-bf16 (text) · Qwen3-ForcedAligner-0.6B-bf16 (timing)", "diarization": "provider", "ready": true, "engine": {"name": "omi-asr sidecar", "healthy": true, "self_test": "ok", "models": {"diarization": "OpenMOSS-Team/MOSS-Transcribe-Diarize", "text": "mlx-community/Qwen3-ASR-1.7B-bf16", "aligner": "mlx-community/Qwen3-ForcedAligner-0.6B-bf16"}}}, "llm": {"provider": "openai", "model": "gpt-6-luna", "ready": true}, "local_transcription": {"available": true, "checked_at": "2026-11-09T06:22:22.701Z", "down_since": null, "down_seconds": 0}}"#

    private func status(_ json: String) throws -> ServerStatus {
        try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
    }

    @Test func theLocalEngineIsOneShortLineWithItsModelsInTheDetails() throws {
        let s = try status(Self.local)
        #expect(s.stt?.engine?.healthy == true && s.stt?.engine?.models?["text"] == "mlx-community/Qwen3-ASR-1.7B-bf16")
        #expect(s.localTranscription?.available == true)
        let t = s.transcriptionLabel
        #expect(t.text == "Local · MOSS + Qwen")
        #expect(t.health == .ok)
        let details = Dictionary(t.details.map { ($0.title, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(details["Speakers"] == "OpenMOSS-Team/MOSS-Transcribe-Diarize")
        #expect(details["Text"] == "mlx-community/Qwen3-ASR-1.7B-bf16")
        #expect(details["Timing"] == "mlx-community/Qwen3-ForcedAligner-0.6B-bf16")
        #expect(details["Engine"] == "omi-asr sidecar · self-test ok")
        #expect(s.summariesLabel.text == "gpt-6-luna" && s.summariesLabel.health == .ok)
    }

    @Test func theModelStringAloneStillGivesTheShortName() throws {
        let s = try status(#"{"stt": {"provider": "local", "model": "MOSS-Transcribe-Diarize (speakers) · Qwen3-ASR-1.7B-bf16 (text) · Qwen3-ForcedAligner-0.6B-bf16 (timing)", "ready": true}}"#)
        #expect(s.transcriptionLabel.text == "Local · MOSS + Qwen")
        #expect(s.transcriptionLabel.details.contains { $0.value.contains("Qwen3-ForcedAligner-0.6B-bf16") })
    }

    @Test func aDownEngineSaysSoInTheLine() throws {
        var s = try status(Self.local)
        s.stt?.engine?.healthy = false
        #expect(s.transcriptionLabel.health == .down && s.transcriptionLabel.text == "Local · not responding")
        s = try status(Self.local)
        s.localTranscription?.available = false
        let answered = try #require(ISO8601UTC.parse("2026-11-09T06:22:30.000Z"))
        #expect(s.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered).transcription.health == .down,
                "the server's own recent check counts too")
        s = try status(Self.local)
        s.stt?.ready = false
        #expect(s.transcriptionLabel.health == .down, "a local engine that isn't ready isn't answering")
    }

    @Test func otherProvidersFallBackGracefully() throws {
        let old = try status(#"{"stt": {"provider": "openai", "model": "gpt-transcribe", "ready": true}, "llm": {"provider": "anthropic", "model": "claude-opus-5", "ready": false}}"#)
        #expect(old.transcriptionLabel.text == "gpt-transcribe")
        #expect(old.summariesLabel.text == "Anthropic · not set up" && old.summariesLabel.health == .notSetUp)
        #expect(old.summariesLabel.details.contains { $0.value == "claude-opus-5" })
        let deepgram = try status(#"{"stt": {"provider": "deepgram", "ready": true}, "llm": {"provider": "none"}}"#)
        #expect(deepgram.transcriptionLabel.text == "Deepgram")
        #expect(deepgram.summariesLabel.text == "Turned off" && deepgram.summariesLabel.health == .unknown)
        let unknown = try status(#"{"stt": {"provider": "whisperx", "model": "org/some-very-long-model-name-with-a-suffix-v2"}}"#)
        #expect(unknown.transcriptionLabel.text.hasPrefix("whisperx · "))
        #expect(unknown.transcriptionLabel.text.count <= 32, "\(unknown.transcriptionLabel.text)")
        #expect(unknown.transcriptionLabel.health == .unknown)
        #expect(unknown.transcriptionLabel.details.contains { $0.value == "org/some-very-long-model-name-with-a-suffix-v2" })
        let none = try status(#"{"ok": true}"#)
        #expect(none.transcriptionLabel.text == "—" && none.transcriptionLabel.details.isEmpty)
    }

    /// ASTRA-20261109-IT1-05: the dots stayed green from a cached status after a refresh failed or the
    /// answer got old, and the engine check's own age was ignored. The names stay; a health is shown
    /// only from a current answer (latest request answered, within `currentFor`), and the local engine's
    /// last check counts only while it is recent too.
    @Test func aHealthIsShownOnlyFromACurrentAnswer() throws {
        let s = try status(Self.local)
        let answered = try #require(ISO8601UTC.parse("2026-11-09T06:22:30.000Z"))
        let fresh = s.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered.addingTimeInterval(30))
        #expect(fresh.transcription.health == .ok && fresh.summaries.health == .ok)
        #expect(fresh.transcription == s.transcriptionLabel)

        let offline = s.serviceLabels(answeredAt: answered, latestRequestFailed: true, now: answered.addingTimeInterval(30))
        #expect(offline.transcription.health == .lastKnown && offline.summaries.health == .lastKnown)
        #expect(offline.transcription.text == "Local · MOSS + Qwen" && offline.summaries.text == "gpt-6-luna", "the names stay")
        #expect(offline.transcription.details == fresh.transcription.details)

        let expired = s.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered.addingTimeInterval(ServiceLabel.currentFor + 1))
        #expect(expired.transcription.health == .lastKnown && expired.summaries.health == .lastKnown, "green expires with no new answer")
        let future = s.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered.addingTimeInterval(-600))
        #expect(future.transcription.health == .lastKnown, "an answer dated ahead of this phone isn't current")
        let never = s.serviceLabels(answeredAt: nil, latestRequestFailed: false, now: answered)
        #expect(never.transcription.health == .lastKnown)

        var down = s
        down.stt?.engine?.healthy = false
        #expect(down.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered).transcription.health == .down)
        let staleDown = down.serviceLabels(answeredAt: answered, latestRequestFailed: true, now: answered)
        #expect(staleDown.transcription.health == .lastKnown && staleDown.transcription.text == "Local · MOSS + Qwen",
                "an old \"not responding\" isn't a statement about now either")
    }

    @Test func theLocalEngineCheckCountsOnlyWhileRecent() throws {
        // only the worker's check says the engine answers (no engine block)
        let base = #"{"server_time": "2026-11-09T06:30:00.000Z", "stt": {"provider": "local", "model": "Qwen3-ASR-1.7B-bf16", "ready": true}, "local_transcription": {"available": AVAIL, "checked_at": "CHECKED", "down_since": null}}"#
        func at(_ checked: String, available: String = "true") throws -> ServerStatus {
            try status(base.replacingOccurrences(of: "AVAIL", with: available).replacingOccurrences(of: "CHECKED", with: checked))
        }
        let answered = try #require(ISO8601UTC.parse("2026-11-09T06:30:00.000Z"))
        let recent = try at("2026-11-09T06:29:30.000Z")
        #expect(recent.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered).transcription.health == .ok)
        let old = try at("2026-11-09T06:20:00.000Z")
        #expect(old.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered).transcription.health == .unknown,
                "a ten-minute-old check isn't evidence the engine answers now")
        // the check's age counts by the server's clock at the answer, plus the answer's own age here
        #expect(recent.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered.addingTimeInterval(280)).transcription.health == .unknown)
        let recentDown = try at("2026-11-09T06:29:30.000Z", available: "false")
        #expect(recentDown.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered).transcription.health == .down)
    }

    /// ASTRA-20261109-IT2-04: a worker check dated after the answer was clamped to age zero, and a
    /// missing or malformed `checked_at` defaulted to fresh, so `available: true` showed green with no
    /// proof it was current. The worker's word counts only with a valid, not-future, recent check; an
    /// engine block that is itself healthy stays separate evidence.
    @Test func aWorkerCheckWithoutAValidRecentDateIsUnknown() throws {
        let answered = try #require(ISO8601UTC.parse("2026-11-09T06:30:00.000Z"))
        func health(_ local: String, engine: String = "", serverTime: Bool = true) throws -> ServiceLabel.Health {
            let time = serverTime ? #""server_time": "2026-11-09T06:30:00.000Z", "# : ""
            let s = try status(#"{\#(time)"stt": {"provider": "local", "model": "Qwen", "ready": true\#(engine)}, "local_transcription": {\#(local)}}"#)
            return s.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered).transcription.health
        }
        #expect(try health(#""available": true, "checked_at": "2026-11-10T06:30:00.000Z""#) == .unknown, "a check a day ahead")
        #expect(try health(#""available": true, "checked_at": "2026-11-09T06:30:01.000Z""#) == .unknown, "ahead of the server's own clock")
        #expect(try health(#""available": true"#) == .unknown, "no check time")
        #expect(try health(#""available": true, "checked_at": null"#) == .unknown)
        #expect(try health(#""available": true, "checked_at": "not-a-date""#) == .unknown, "malformed check time")
        #expect(try health(#""available": false, "checked_at": "not-a-date""#) == .unknown, "an undated \"down\" isn't current either")
        // controls: a valid recent check is trusted, an old one isn't
        #expect(try health(#""available": true, "checked_at": "2026-11-09T06:30:00.000Z""#) == .ok)
        #expect(try health(#""available": true, "checked_at": "2026-11-09T06:29:30.000Z""#) == .ok)
        #expect(try health(#""available": false, "checked_at": "2026-11-09T06:29:30.000Z""#) == .down)
        #expect(try health(#""available": true, "checked_at": "2026-11-09T06:20:00.000Z""#) == .unknown)
        // without the server's time the check is dated by this phone's clock (within its usual skew)
        #expect(try health(#""available": true, "checked_at": "2026-11-09T06:29:30.000Z""#, serverTime: false) == .ok)
        #expect(try health(#""available": true, "checked_at": "2026-11-09T06:30:30.000Z""#, serverTime: false) == .ok)
        #expect(try health(#""available": true, "checked_at": "2026-11-09T06:35:00.000Z""#, serverTime: false) == .unknown)
        // the engine's own current answer is separate evidence
        #expect(try health(#""available": true, "checked_at": "2026-11-10T06:30:00.000Z""#, engine: #", "engine": {"healthy": true}"#) == .ok)
        #expect(try health(#""available": true"#, engine: #", "engine": {"healthy": false}"#) == .down)
    }

    @Test func absentHealthFieldsStayUnknown() throws {
        let answered = Date(timeIntervalSince1970: 1_800_000_000)
        let local = try status(#"{"stt": {"provider": "local", "model": "Qwen3-ASR-1.7B-bf16", "ready": true}, "llm": {"provider": "openai", "model": "gpt-6-luna"}}"#)
        let labels = local.serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered)
        #expect(labels.transcription.health == .unknown, "configured isn't answering: a local engine needs a health check")
        #expect(labels.summaries.health == .unknown)
        #expect(local.serviceLabels(answeredAt: answered, latestRequestFailed: true, now: answered).transcription.health == .unknown,
                "nothing known stays nothing known, not \"last known\"")
        let none = try status(#"{"ok": true}"#).serviceLabels(answeredAt: answered, latestRequestFailed: false, now: answered)
        #expect(none.transcription.health == .unknown && none.summaries.health == .unknown)
    }

    @Test func modelFamilies() {
        #expect(ServiceNames.family("mlx-community/Qwen3-ASR-1.7B-bf16") == "Qwen")
        #expect(ServiceNames.family("OpenMOSS-Team/MOSS-Transcribe-Diarize") == "MOSS")
        #expect(ServiceNames.family("whisper-large-v3-turbo") == "whisper")
        #expect(ServiceNames.family("3dspeaker") == "3dspeaker", "nothing left after the digits: keep the name")
        #expect(ServiceNames.shortModel("nova-3") == "nova-3")
        #expect(ServiceNames.shortModel("gpt-4o-transcribe-diarize") == "gpt-4o-transcribe")
    }
}
