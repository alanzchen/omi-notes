import Foundation
import Testing
@testable import OmiCapture
@testable import OmiProtocol

final class RangeStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRange: String?
    nonisolated(unsafe) static var lastAuth: String?
    static let file = Data((0..<1000).map { UInt8($0 % 256) })

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRange = request.value(forHTTPHeaderField: "Range")
        Self.lastAuth = request.value(forHTTPHeaderField: "Authorization")
        let parts = (Self.lastRange ?? "bytes=0-999").dropFirst(6).split(separator: "-").compactMap { Int($0) }
        let (a, b) = (parts[0], min(parts[1], Self.file.count - 1))
        let resp = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil,
                                   headerFields: ["Content-Range": "bytes \(a)-\(b)/\(Self.file.count)", "Content-Type": "audio/wav"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.file.subdata(in: a..<(b + 1)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct RecordingTests {
    static let info = #"""
    {"available":true,"reason":null,"duration_s":742.5,"partial":true,
     "span":{"started_at":"2026-10-09T10:00:00.000Z","ended_at":"2026-10-09T10:12:30.500Z","seconds":750.5},
     "gaps":[{"started_at":"2026-10-09T10:05:00.000Z","ended_at":"2026-10-09T10:05:08.000Z","seconds":8.0}],
     "timemap":[[0.0,1791540000.0,300.0],[300.0,1791540308.0,442.5]],"url":"/v1/conversations/c1/recording.wav"}
    """#

    @Test func playableTimeGapsAndClockAreReadHonestly() throws {
        let info = try APIClient.snakeDecoder.decode(RecordingInfo.self, from: Data(Self.info.utf8))
        #expect(info.available && info.partial == true && info.durationS == 742.5 && info.span?.seconds == 750.5)
        let timeline = RecordingTimeline(info)
        #expect(timeline.gapMarks.count == 1 && abs(timeline.gapMarks[0] - 300 / 742.5) < 1e-9)
        // after the gap the clock jumps by 8 s: offset 301 s is 10:05:09, not 10:05:01
        #expect(timeline.wallClock(at: 301)?.timeIntervalSince1970 == 1_791_540_309)
        #expect(timeline.wallClock(at: 10)?.timeIntervalSince1970 == 1_791_540_010)
    }

    @Test func expiredIsNotPlayable() throws {
        let json = #"{"available":false,"reason":"expired","duration_s":null,"span":{"seconds":60},"gaps":[],"partial":false,"timemap":[],"url":null}"#
        let info = try APIClient.snakeDecoder.decode(RecordingInfo.self, from: Data(json.utf8))
        #expect(!info.available && info.reason == "expired" && info.durationS == nil && RecordingTimeline(info).gapMarks.isEmpty)
    }

    @Test func rangesAreFetchedWithTheTokenInAHeaderAndTheSizeIsRead() async throws {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [RangeStub.self]
        let api = APIClient(endpoint: ServerEndpoint(baseURL: URL(string: "https://mac.ts.net")!, token: "tok"), session: URLSession(configuration: c))
        let (data, total) = try await api.recordingBytes("c1", offset: 100, length: 50)
        #expect(RangeStub.lastRange == "bytes=100-149" && RangeStub.lastAuth == "Bearer tok")
        #expect(data == RangeStub.file.subdata(in: 100..<150) && total == 1000)
    }
}
