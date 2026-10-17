import Foundation
import Testing
@testable import OmiBLE

@MainActor
final class FakeClipAudio: ClipAudio {
    let duration: Double = 2
    var currentTime: Double = 0
    var isPlaying = false
    var onFinish: (() -> Void)?
    var plays = 0
    func play() { plays += 1; isPlaying = true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}

/// Server clip downloads that answer only when the test says so.
@MainActor
final class ClipServer {
    var requests: [String] = []
    private var waiting: [String: [CheckedContinuation<Data, Error>]] = [:]
    func fetch(_ id: String) async throws -> Data {
        requests.append(id)
        return try await withCheckedThrowingContinuation { waiting[id, default: []].append($0) }
    }
    func answer(_ id: String) { waiting.removeValue(forKey: id)?.forEach { $0.resume(returning: Data("wav-\(id)".utf8)) } }
    func fail(_ id: String) { waiting.removeValue(forKey: id)?.forEach { $0.resume(throwing: URLError(.timedOut)) } }
}

/// UX-AU-001: a clip that is still downloading when its screen closes (or another clip, or another
/// sound, takes over) must never start playing afterwards.
@MainActor
@Suite(.serialized) struct ClipPlaybackTests {
    @MainActor final class Rig {
        let server = ClipServer()
        var made: [FakeClipAudio] = []
        var activations = 0
        let center = NotificationCenter()  // its own: other suites' sounds run in parallel
        var playback: ClipPlayback!
        var fetch: (String) async throws -> Data { { [server] id in try await server.fetch(id) } }
        var plays: Int { made.reduce(0) { $0 + $1.plays } }
    }

    func rig(_ tap: ClipPlayback.Tap = .stop) -> Rig {
        let r = Rig()
        r.playback = ClipPlayback(tap: tap, makeAudio: { _ in let a = FakeClipAudio(); r.made.append(a); return a },
                                  activate: { r.activations += 1 }, center: r.center)
        return r
    }

    func settle() async { for _ in 0..<30 { await Task.yield() } }

    @Test func closingWhileTheClipDownloadsPlaysNothingAfterwards() async {
        let r = rig()
        r.playback.toggle("a", fetch: r.fetch)
        await settle()
        #expect(r.playback.loading == "a")
        r.playback.stop()  // Back / Close
        r.server.answer("a")
        await settle()
        #expect(r.plays == 0 && r.activations == 0 && r.playback.playing == nil)
        #expect(r.playback.loading == nil, "no spinner left behind")
    }

    @Test func anotherClipReplacesTheFirstAndTheFirstNeverRevives() async {
        let r = rig()
        r.playback.toggle("a", fetch: r.fetch)
        await settle()
        r.playback.toggle("b", fetch: r.fetch)
        await settle()
        r.server.answer("a")
        await settle()
        #expect(r.plays == 0, "the replaced clip doesn't start")
        r.server.answer("b")
        await settle()
        #expect(r.playback.playing == "b" && r.plays == 1)
    }

    @Test func tappingAgainWhileItDownloadsSendsOneRequest() async {
        let r = rig()
        r.playback.toggle("a", fetch: r.fetch)
        await settle()
        r.playback.toggle("a", fetch: r.fetch)
        await settle()
        #expect(r.server.requests == ["a"])
        r.server.answer("a")
        await settle()
        #expect(r.playback.playing == "a" && r.plays == 1)
    }

    @Test func aFailureAfterClosingIsNotReported() async {
        let r = rig()
        r.playback.toggle("a", fetch: r.fetch)
        await settle()
        r.playback.stop()
        r.server.fail("a")
        await settle()
        #expect(r.playback.message == nil, "the closed screen's error doesn't land on the next one")
    }

    /// Astra's Name-this-voice path: the preload fails, play retries, Close before the answer.
    @Test func aRetriedPlayClosedBeforeTheAnswerStaysSilent() async {
        let r = rig(.pause)
        let preload = Task { await r.playback.load("a", fetch: r.fetch) }
        await settle()
        r.server.fail("a")
        await preload.value
        #expect(r.playback.message != nil && r.playback.loadedId == nil)
        r.playback.toggle("a", fetch: r.fetch)  // tap play to try again
        await settle()
        r.playback.stop()  // Close
        r.server.answer("a")
        await settle()
        #expect(r.plays == 0 && r.playback.playing == nil)
    }

    @Test func anotherSoundStartingWhileLoadingCancelsThePlay() async {
        let r = rig()
        r.playback.toggle("a", fetch: r.fetch)
        await settle()
        r.center.post(name: .omiAudioWillPlay, object: NSObject())
        r.server.answer("a")
        await settle()
        #expect(r.plays == 0)
    }

    // UX-LT-ASTRA-01: Astra's schedules (astra-review/AcceptanceHarness.swift), on the production controller.

    @Test func closingInTheSameTurnSuppressesALaterError() async {
        let r = rig()
        r.playback.toggle("a", fetch: r.fetch)
        r.playback.stop()  // before the task even starts
        await settle()
        r.server.fail("a")
        await settle()
        #expect(r.playback.message == nil && r.plays == 0)
    }

    @Test func immediateReplacementLeavesTheNewClipLoadedAndPlaying() async {
        let r = rig()
        r.playback.toggle("a", fetch: r.fetch)
        r.playback.toggle("b", fetch: r.fetch)  // same turn
        await settle()
        r.server.answer("b")
        await settle()
        r.server.answer("a")  // the replaced one answers last
        await settle()
        #expect(r.playback.playing == "b" && r.playback.loadedId == "b", "playing \(r.playback.playing ?? "nil"), loaded \(r.playback.loadedId ?? "nil")")
        #expect(r.made.count == 1, "the replaced clip is never prepared")
    }

    @Test func returningToTheLoadedClipCancelsTheOneDownloading() async {
        let r = rig(.pause)
        let first = Task { await r.playback.load("a", fetch: r.fetch) }
        await settle()
        r.server.answer("a")
        await first.value
        r.playback.toggle("b", fetch: r.fetch)
        await settle()
        r.playback.toggle("a", fetch: r.fetch)  // back to the prepared one while b downloads
        r.server.answer("b")
        await settle()
        #expect(r.playback.playing == "a", "the latest choice stays: \(r.playback.playing ?? "nil")")
    }

    @Test func aRetiredClipsFinishDoesNotStopTheCurrentOne() async {
        let r = rig()
        r.playback.toggle("a", fetch: r.fetch)
        await settle()
        r.server.answer("a")
        await settle()
        r.playback.toggle("b", fetch: r.fetch)
        await settle()
        r.server.answer("b")
        await settle()
        #expect(r.playback.playing == "b")
        r.made[0].onFinish?()  // a's player reports its end late
        #expect(r.playback.playing == "b")
    }

    @Test func aDoubleTapInTheSameTurnPreparesOnePlayer() async {
        let r = rig()
        r.playback.toggle("a", fetch: r.fetch)
        r.playback.toggle("a", fetch: r.fetch)
        await settle()
        r.server.answer("a")
        await settle()
        #expect(r.made.count == 1 && r.plays == 1 && r.server.requests == ["a"])
    }

    @Test func aPreparedClipPlaysPausesAndResumes() async {
        let r = rig(.pause)
        let loading = Task { await r.playback.load("a", fetch: r.fetch) }
        await settle()
        r.server.answer("a")
        await loading.value
        r.playback.toggle("a", fetch: r.fetch)
        #expect(r.playback.playing == "a" && r.activations == 1)
        r.playback.toggle("a", fetch: r.fetch)
        #expect(r.playback.playing == nil && r.made.count == 1)
    }
}
