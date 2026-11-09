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
        #expect(s.transcriptionLabel.health == .down, "the server's own check counts too")
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

    @Test func modelFamilies() {
        #expect(ServiceNames.family("mlx-community/Qwen3-ASR-1.7B-bf16") == "Qwen")
        #expect(ServiceNames.family("OpenMOSS-Team/MOSS-Transcribe-Diarize") == "MOSS")
        #expect(ServiceNames.family("whisper-large-v3-turbo") == "whisper")
        #expect(ServiceNames.family("3dspeaker") == "3dspeaker", "nothing left after the digits: keep the name")
        #expect(ServiceNames.shortModel("nova-3") == "nova-3")
        #expect(ServiceNames.shortModel("gpt-4o-transcribe-diarize") == "gpt-4o-transcribe")
    }
}
