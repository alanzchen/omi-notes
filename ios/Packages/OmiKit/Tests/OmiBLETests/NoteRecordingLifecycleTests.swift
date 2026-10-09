import Foundation
import Testing
@testable import OmiBLE
@testable import OmiProtocol

/// A response the test releases by hand (a slow server, a slow player).
@MainActor
final class Gate<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    var waiting: Bool { continuation != nil }

    func wait() async throws -> T {
        if let pending { self.pending = nil; return try pending.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func open(_ result: Result<T, Error>) {
        if let c = continuation { continuation = nil; c.resume(with: result) } else { pending = result }
    }
}

@MainActor
final class FakeEngine: RecordingEngine {
    let ready = Gate<Void>()
    var plays = 0, pauses = 0, teardowns = 0
    var onFailure: ((String) -> Void)?
    var onTime: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    func waitUntilReady() async throws { try await ready.wait() }
    func play() { plays += 1 }
    func pause() { pauses += 1 }
    func seek(to seconds: Double) {}
    func teardown() { teardowns += 1 }
}

@MainActor
@Suite(.serialized) struct NoteRecordingLifecycleTests {
    static let info = try! JSONDecoder.snake.decode(RecordingInfo.self, from: Data(
        #"{"available":true,"duration_s":49.84,"span":{"seconds":49.84},"gaps":[],"partial":false,"timemap":[[0,1000,49.84]]}"#.utf8))

    @MainActor final class Harness {
        let info = Gate<RecordingInfo>()
        var engines: [FakeEngine] = []
        var controller: NoteRecordingController!
    }

    func harness() -> Harness {
        let h = Harness()
        h.controller = NoteRecordingController(conversationId: "c1", fetchInfo: { try await h.info.wait() },
                                               makeEngine: { _ in let e = FakeEngine(); h.engines.append(e); return e })
        return h
    }

    /// Lets the toggle task run up to its next suspension.
    func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func leavingWhileTheInfoIsSlowCreatesNoPlayerAndPlaysNothing() async {
        let h = harness()
        let tap = Task { await h.controller.toggle() }
        await settle()
        #expect(h.controller.state == .loading)
        h.controller.stop()                       // the note was left
        h.info.open(.success(Self.info))           // the slow reply arrives afterwards
        await settle()
        #expect(h.engines.isEmpty, "no player for a note that was left")
        for e in h.engines { e.ready.open(.success(())) }   // release a player the old code made anyway
        await tap.value
        #expect(h.engines.allSatisfy { $0.plays == 0 }, "and nothing played")
        #expect(h.controller.state == .idle && !h.controller.isPlaying)
    }

    @Test func leavingWhileThePlayerIsGettingReadyNeverStartsIt() async {
        let h = harness()
        let tap = Task { await h.controller.toggle() }
        await settle()
        h.info.open(.success(Self.info))
        await settle()
        #expect(h.engines.count == 1 && h.engines[0].ready.waiting)
        h.controller.stop()
        h.engines[0].ready.open(.success(()))
        await tap.value
        #expect(h.engines[0].plays == 0, "a left note never starts playing")
        #expect(h.engines[0].teardowns >= 1 && h.controller.state == .idle && !h.controller.isPlaying)
    }

    @Test func aLateTimeoutOfAnAbandonedLoadDoesNotTouchTheNextOne() async {
        let h = harness()
        let first = Task { await h.controller.toggle() }
        await settle()
        h.info.open(.success(Self.info))
        await settle()
        h.controller.stop()                        // left while getting ready…
        let second = Task { await h.controller.toggle() }  // …and opened again
        await settle()
        h.info.open(.success(Self.info))
        await settle()
        h.engines[1].ready.open(.success(()))
        await second.value
        #expect(h.controller.state == .ready && h.controller.isPlaying && h.engines[1].plays == 1)
        h.engines[0].ready.open(.failure(URLError(.timedOut)))   // the old load times out late
        await first.value
        #expect(h.controller.state == .ready && h.controller.isPlaying, "the old operation can't fail the new one")
        #expect(h.engines[0].plays == 0 && h.engines[1].teardowns == 0)
    }

    @Test func aFailureWhilePlayingStopsAndOffersRetry() async {
        let h = harness()
        let tap = Task { await h.controller.toggle() }
        await settle()
        h.info.open(.success(Self.info))
        await settle()
        h.engines[0].ready.open(.success(()))
        await tap.value
        #expect(h.controller.isPlaying)
        h.controller.engineFailed("The network connection was lost.")
        #expect(!h.controller.isPlaying)
        guard case .failed(let message) = h.controller.state else { Issue.record("not failed"); return }
        #expect(message.contains("stopped") && h.engines[0].teardowns >= 1)
        let retry = Task { await h.controller.toggle() }  // Retry loads again
        await settle()
        h.info.open(.success(Self.info))
        await settle()
        h.engines[1].ready.open(.success(()))
        await retry.value
        #expect(h.controller.state == .ready && h.controller.isPlaying)
    }

    @Test func aHighlightCueStartsThereOrSaysThereIsNoAudio() async {
        // playable 0–20 s = clock 1000–1020; nothing recorded for clock 1020–1030; 20–30 s = 1030–1040
        let gapped = try! JSONDecoder.snake.decode(RecordingInfo.self, from: Data(
            #"{"available":true,"duration_s":30,"span":{"seconds":40},"gaps":[{"seconds":10}],"partial":true,"timemap":[[0,1000,20],[20,1030,10]]}"#.utf8))
        let engines = Gate<RecordingInfo>()
        var made: [FakeEngine] = []
        let c = NoteRecordingController(conversationId: "c", fetchInfo: { try await engines.wait() },
                                        makeEngine: { _ in let e = FakeEngine(); made.append(e); return e })
        c.cue(at: Date(timeIntervalSince1970: 1035), approximate: true)
        #expect(c.cueNote?.hasPrefix("Play starts around") == true && made.isEmpty)   // nothing plays or loads yet
        let tap = Task { await c.toggle() }
        await settle()
        engines.open(.success(gapped))
        await settle()
        made[0].ready.open(.success(()))
        await tap.value
        #expect(c.isPlaying && c.current == 25 && c.cueNote == nil)                   // after the gap: offset 25 s
        c.pause()
        c.cue(at: Date(timeIntervalSince1970: 1025), approximate: false)              // inside the gap
        #expect(c.current == 25 && c.cueNote?.hasPrefix("That moment has no recorded audio") == true)
    }

    @Test func theWholeInitialLoadIsBounded() async {
        let h = harness()
        h.controller.loadTimeout = .milliseconds(150)
        let tap = Task { await h.controller.toggle() }   // the info doesn't answer
        try? await Task.sleep(for: .milliseconds(600))
        let seen = h.controller.state
        h.info.open(.failure(CancellationError()))       // release it, whatever happened
        await tap.value
        guard case .failed(let message) = seen else { Issue.record("after 0.6 s still \(seen)"); return }
        #expect(message.contains("timed out") && h.engines.isEmpty)
    }
}

extension JSONDecoder {
    static var snake: JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }
}
