import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

/// TestFlight 2026-11-12 (build 53): a review card said "无法试听" with "网络有点慢，点这里重试" under it, for a sample
/// the server already called unplayable; Alan: "我都无法试听我怎么选？这些以后就舍弃吧".
@Suite struct ReviewClipStateTests {
    let playable = ReviewItem(id: "s.a.0", kind: "sample", playable: true, clip: SpeakerClip(id: "sample.a.0", seconds: 3))
    let unplayable = ReviewItem(id: "s.b.0", kind: "sample", playable: false)

    @Test func theCardSaysNoAudioLoadingOrRetryForTheRightReason() {
        #expect(ReviewClipState.of(unplayable, loading: false, failure: nil) == .noAudio)
        #expect(ReviewClipState.of(unplayable, loading: false, failure: .network(.slow)) == .noAudio, "never 'slow' for no audio")
        #expect(ReviewClipState.of(playable, loading: true, failure: nil) == .loading)
        #expect(ReviewClipState.of(playable, loading: false, failure: nil) == .ready)
        #expect(ReviewClipState.of(playable, loading: false, failure: .noAudio) == .noAudio, "404/410: no retry")
        #expect(ReviewClipState.of(playable, loading: false, failure: .network(.slow)) == .retry("网络有点慢，点播放重试"))
        #expect(ReviewClipState.of(playable, loading: false, failure: .network(.unreachable)) == .retry("连不上服务器，点播放重试"))
    }

    @Test func aClipFailureIsClassifiedByWhatHappened() {
        #expect(ClipFailure(APIError.http(410, "gone")) == .noAudio)
        #expect(ClipFailure(APIError.http(404, "not found")) == .noAudio)
        #expect(ClipFailure(URLError(.timedOut)) == .network(.slow))
        #expect(ClipFailure(URLError(.notConnectedToInternet)) == .network(.unreachable))
        #expect(ClipFailure(APIError.http(500, "x")) == .other)
    }

    @Test func aBatchNeverHoldsAnItemTheServerCantPlay() {
        let batch = ReviewBatch.make([unplayable, playable, ReviewItem(id: "l.c.S1.1.p.e", kind: "label", playable: true)],
                                     excluding: [])
        #expect(batch.map(\.id) == ["s.a.0"], "unplayable and clip-less items are left out")
    }
}
