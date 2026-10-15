import Foundation
import OmiProtocol

/// A batch of Watch performance samples on its way to the phone (and, as a `watch_perf` event, to
/// the server). `id` is the event id: stable across resends, so every hop is idempotent.
public struct WatchPerfBatch: Codable, Equatable, Sendable {
    public var id: String
    public var deviceId: String
    public var binding: String
    public var data: WatchPerfData
}

/// The Watch's telemetry, kept apart from audio: the open batch is saved after every sample (a
/// crash loses none), sealed batches wait in a queue until the phone acknowledges them. Bounded:
/// at most `maxBatches` sealed batches; beyond that the oldest are discarded and counted in the next
/// batch's `dropped_batches`, so the gap is reported. Audio is never touched to make room.
public final class WatchPerfQueue: @unchecked Sendable {
    public static let maxSamplesPerBatch = 12
    public static let maxBatchAge: TimeInterval = 30 * 60
    public static let maxBatches = 200

    public let root: URL
    private let lock = NSLock()
    private var queueDir: URL { root.appendingPathComponent("queue", isDirectory: true) }
    private var openURL: URL { root.appendingPathComponent("open.json") }
    private var droppedURL: URL { root.appendingPathComponent("dropped") }
    private var seqURL: URL { root.appendingPathComponent("seq") }

    private struct Open: Codable {
        var openedAt: Date
        var samples: [WatchPerfSample]
    }

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
    }

    /// Adds a sample to the open batch; seals it when full or old, or when `seal` is set (end of a
    /// recording, a pause): a stopped recording's samples don't wait for the next one.
    public func append(_ sample: WatchPerfSample, deviceId: String, binding: String, seal: Bool = false, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var open = WatchWire.decode(Open.self, try? Data(contentsOf: openURL)) ?? Open(openedAt: now, samples: [])
        open.samples.append(sample)
        try? Files.durableWrite(WatchWire.encode(open), to: openURL)
        if seal || open.samples.count >= Self.maxSamplesPerBatch || now.timeIntervalSince(open.openedAt) >= Self.maxBatchAge {
            sealOpen(open, deviceId: deviceId, binding: binding)
        }
    }

    /// Seals whatever is open (e.g. at launch, for a previous run's samples).
    public func seal(deviceId: String, binding: String) {
        lock.lock(); defer { lock.unlock() }
        if let open = WatchWire.decode(Open.self, try? Data(contentsOf: openURL)), !open.samples.isEmpty {
            sealOpen(open, deviceId: deviceId, binding: binding)
        }
    }

    private func sealOpen(_ open: Open, deviceId: String, binding: String) {
        let dropped = (try? String(contentsOf: droppedURL, encoding: .utf8)).flatMap { Int($0) } ?? 0
        let id = UUID().uuidString.lowercased()
        let batch = WatchPerfBatch(id: id, deviceId: deviceId, binding: binding,
                                   data: WatchPerfData(batchId: id, samples: open.samples, droppedBatches: dropped))
        // named by a saved sequence number so the queue keeps its order; written before the open
        // batch is cleared
        let seq = ((try? String(contentsOf: seqURL, encoding: .utf8)).flatMap { Int($0) } ?? 0) + 1
        guard (try? Files.durableWrite(Data(String(seq).utf8), to: seqURL)) != nil else { return }
        let name = String(format: "%012d-%@.json", seq, id)
        guard (try? Files.durableWrite(WatchWire.encode(batch), to: queueDir.appendingPathComponent(name))) != nil else { return }
        try? FileManager.default.removeItem(at: openURL)
        if dropped > 0 { try? FileManager.default.removeItem(at: droppedURL) }
        var names = Files.names(queueDir, suffix: ".json").sorted()
        while names.count > Self.maxBatches {
            try? FileManager.default.removeItem(at: queueDir.appendingPathComponent(names.removeFirst()))
            let n = ((try? String(contentsOf: droppedURL, encoding: .utf8)).flatMap { Int($0) } ?? 0) + 1
            try? Files.durableWrite(Data(String(n).utf8), to: droppedURL)
        }
    }

    /// Sealed batches, oldest first.
    public func batches() -> [WatchPerfBatch] {
        lock.lock(); defer { lock.unlock() }
        return Files.names(queueDir, suffix: ".json").sorted().compactMap {
            WatchWire.decode(WatchPerfBatch.self, try? Data(contentsOf: queueDir.appendingPathComponent($0)))
        }
    }

    /// Ids of the sealed batches, oldest first (from file names: nothing is read).
    public func ids() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Files.names(queueDir, suffix: ".json").sorted().map { String($0.dropLast(5).suffix(36)) }
    }

    public func batch(_ id: String) -> WatchPerfBatch? {
        lock.lock(); defer { lock.unlock() }
        guard let name = Files.names(queueDir, suffix: ".json").first(where: { $0.hasSuffix("-\(id).json") }) else { return nil }
        return WatchWire.decode(WatchPerfBatch.self, try? Data(contentsOf: queueDir.appendingPathComponent(name)))
    }

    /// The phone stored these (as outbox events): only now are they removed.
    public func acknowledge(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        let gone = Set(ids)
        for name in Files.names(queueDir, suffix: ".json") where gone.contains(String(name.dropLast(5).suffix(36))) {
            try? FileManager.default.removeItem(at: queueDir.appendingPathComponent(name))
        }
    }
}
