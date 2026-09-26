import Foundation
@testable import OmiCapture
import OmiProtocol

final class FakeClock: CaptureClock, @unchecked Sendable {
    private let lock = NSLock()
    private var mono: UInt64
    private var wall: Date

    init(wall: Date = Date(timeIntervalSince1970: 1_790_451_125.123), mono: UInt64 = 5_000_000_000_000) {
        self.wall = wall
        self.mono = mono
    }

    func monotonicNanoseconds() -> UInt64 { lock.lock(); defer { lock.unlock() }; return mono }
    func wallNow() -> Date { lock.lock(); defer { lock.unlock() }; return wall }

    func advance(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        mono += UInt64((seconds * 1_000_000_000).rounded())
        wall = wall.addingTimeInterval(seconds)
    }

    /// NTP-style wall jump; the monotonic clock is unaffected.
    func jumpWall(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        wall = wall.addingTimeInterval(seconds)
    }
}

final class SequentialIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private let prefix: String
    init(prefix: String = "00000000-0000-4000-8000-") { self.prefix = prefix }
    func next() -> UUID {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return UUID(uuidString: prefix + String(format: "%012d", n))!
    }
}

struct TestEnv {
    let clock: FakeClock
    let dirs: CaptureDirectories
    let outbox: Outbox
    var env: CaptureEnvironment

    init(clock: FakeClock = FakeClock(), root: URL? = nil, appVersion: String? = "test", timezone: String? = "UTC", idGenerator: (@Sendable () -> UUID)? = nil) {
        self.clock = clock
        let r = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("omikit-tests-\(UUID().uuidString)")
        dirs = CaptureDirectories(root: r)
        try! dirs.create()
        outbox = Outbox(dirs: dirs)
        let ids = SequentialIDs()
        env = CaptureEnvironment(dirs: dirs, outbox: outbox, clock: clock, appVersion: appVersion, timezone: timezone, idGenerator: idGenerator ?? { ids.next() })
    }

    func pendingChunks() -> [(OutboxItem, EnvelopeHeader, Data)] {
        outbox.pending().compactMap { item in
            guard item.kind.isChunk, let data = try? Data(contentsOf: item.url), let p = try? Envelope.parse(data) else { return nil }
            return (item, p.header, p.payload)
        }.sorted { $0.1.chunkSequence < $1.1.chunkSequence }
    }

    func seal(_ captureId: String) -> SealBody? {
        let url = dirs.outboxPending.appendingPathComponent(OutboxKind.seal(captureId: captureId).fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SealBody.self, from: data)
    }
}

func notification(seq: UInt16, idx: UInt8 = 0, payload: Data = Data(repeating: 0xAB, count: 80)) -> Data {
    var d = Data([UInt8(seq & 0xFF), UInt8(seq >> 8), idx])
    d.append(payload)
    return d
}

func ringRecord(seq: UInt64) -> Data {
    var d = RingProtocol.be(UInt32(1_790_000_000) &+ UInt32(truncatingIfNeeded: seq))
    d.append(UInt8(80))
    d.append(Data(repeating: UInt8(truncatingIfNeeded: seq), count: 80))
    d.append(Data(count: 444 - d.count))
    return d
}

func loadOpusPackets() -> [Data] {
    guard let url = Bundle.module.url(forResource: "opus_packets", withExtension: "bin", subdirectory: "Resources"),
          let data = try? Data(contentsOf: url) else { return [] }
    let b = [UInt8](data)
    var out: [Data] = []
    var off = 0
    while off + 2 <= b.count {
        let n = Int(b[off]) | Int(b[off + 1]) << 8
        out.append(Data(b[(off + 2)..<(off + 2 + n)]))
        off += 2 + n
    }
    return out
}
