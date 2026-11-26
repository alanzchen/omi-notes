import Foundation
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiProtocol

extension NoteRecordingLifecycleTests {
    @Test func astraNetworkAndAuthNeverClaimMissingAudio() async {
        let errors: [Error] = [URLError(.timedOut), URLError(.notConnectedToInternet), APIError.unauthorized,
            APIError.http(403, "refused"), APIError.http(404, "not found"), APIError.http(410, "expired"),
            APIError.http(503, "busy"), APIError.transport("The request timed out."), APIError.notConfigured,
            APIError.decoding("malformed"), CancellationError()]
        for error in errors {
            let h = harness()
            let tap = Task { await h.controller.toggle() }
            await settle()
            h.info.open(.failure(error))
            await tap.value
            guard case .failed(let message) = h.controller.state else { Issue.record("not a failure"); continue }
            #expect(!message.contains("can't read") && !message.contains("expired"))
            #expect(message == "Couldn't load the recording." || message == "Loading the recording timed out.")
            h.controller.stop()
        }
    }
    @Test func astraControlsTrackReadyAcrossPlaybackLifecycle() async {
        let (c, engines) = await ready(Self.info)
        #expect(c.state == .ready && c.isPlaying)
        c.pause()
        #expect(c.state == .ready && !c.isPlaying)
        c.seek(to: 12)
        await c.toggle()
        #expect(c.state == .ready && c.isPlaying && c.current == 12)
        engines[0].onEnd?()
        #expect(c.state == .ready && !c.isPlaying && c.current == c.duration)
        await c.toggle()
        #expect(c.state == .ready && c.isPlaying && c.current == 0)
        engines[0].onFailure?("no audio arrived for 15 s")
        #expect(c.state != .ready && !c.isPlaying && engines[0].teardowns > 0)
        c.stop()
        let h = harness()
        let tap = Task { await h.controller.toggle() }
        await settle()
        h.info.open(.success(Self.info)); await settle()
        h.engines[0].ready.open(.success(())); await tap.value
        h.controller.stop()
        #expect(h.controller.state == .idle && !h.controller.isPlaying)
    }
    @Test func astraEncodedURLsNeverReachActualLog() async {
        let (c, _) = await ready(Self.info)
        c.engineFailed("HTTP 500: https%3A%2F%2Fprobe.invalid%2Fpath%3F%74oken%3DsecretXYZ%26q%3DprivateQ")
        let line = OmiLog.shared.recent().last { $0.category == "recording" }!.message
        #expect(!line.contains("secretXYZ"), "encoded token must not leak")
        #expect(!line.contains("probe.invalid") && !line.contains("privateQ"), "no URL or query should reach log: \(line)")
    }
    @Test func astraLogKeepsUsefulAPIClassification() {
        let auth = NoteRecordingController.errorSummary(APIError.unauthorized)
        let server = NoteRecordingController.errorSummary(APIError.http(503, "busy"))
        let transport = NoteRecordingController.errorSummary(APIError.transport("offline"))
        #expect(auth != server && server != transport, "authentication, HTTP status and transport cannot all log as APIError")
    }
}
