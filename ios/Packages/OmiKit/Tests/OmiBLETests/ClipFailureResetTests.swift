import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

/// ASTRA-20261113-IT1-03 (its two checks): a new clip or a retry showed the previous load's failure while loading.
@MainActor @Suite(.serialized) struct ClipFailureResetTests {
    @Test func anotherCardStartsLoadingWithoutOldNoAudioFailure() async {
        let p = ClipPlayback(tap: .pause, makeAudio: { _ in FakeClipAudio() }, center: NotificationCenter())
        await p.load("gone", version: "old") { _ in throw APIError.http(404, "gone") }
        #expect(p.failure == .noAudio)
        // Matches VoiceReviewView's .task(id: current.id): stop, then preload the new clip.
        p.stop()
        let server = ClipServer()
        let task = Task { await p.load("exists", version: "new") { try await server.fetch($0) } }
        for _ in 0..<100 where server.requests.isEmpty { await Task.yield() }
        #expect(server.requests == ["exists"])
        let item = ReviewItem(id: "new", playable: true, clip: SpeakerClip(id: "exists", seconds: 3))
        let state = ReviewClipState.of(item, loading: p.loading != nil, failure: p.failure)
                #expect(state == .loading, "old 404 hides the next card's loading/play area")
        server.answer("exists"); await task.value
        #expect(ReviewClipState.of(item, loading: p.loading != nil, failure: p.failure) == .ready)
    }
    @Test func retryStartsLoadingWithoutStaleNetworkFailure() async {
        let p = ClipPlayback(tap: .pause, makeAudio: { _ in FakeClipAudio() }, center: NotificationCenter())
        await p.load("exists") { _ in throw URLError(.timedOut) }
        let server=ClipServer()
        let task=Task { await p.load("exists") { try await server.fetch($0) } }
        for _ in 0..<100 where server.requests.isEmpty { await Task.yield() }
        let item=ReviewItem(id:"same",playable:true,clip:SpeakerClip(id:"exists"))
        let state=ReviewClipState.of(item,loading:p.loading != nil,failure:p.failure)
                #expect(state == .loading)
        server.answer("exists");await task.value
        #expect(p.failure == nil)
    }
}
