import Foundation

/// Cuts one continuous stream of audio frames into segments of a fixed length. A buffer that
/// crosses a boundary is split between the two segments, so rotating to a new file loses or
/// repeats no frame (the recorder doesn't stop between segments).
public struct SegmentClock: Sendable {
    public let framesPerSegment: Int
    /// Frames already in the open segment.
    public private(set) var framesInSegment = 0

    public init(framesPerSegment: Int) {
        self.framesPerSegment = max(1, framesPerSegment)
    }

    /// Where `count` incoming frames go: runs to append to the open segment, each saying whether
    /// that segment is complete after it (and the next run starts a new one).
    public mutating func split(_ count: Int) -> [(frames: Int, closesSegment: Bool)] {
        var left = count, runs: [(Int, Bool)] = []
        while left > 0 {
            let n = min(left, framesPerSegment - framesInSegment)
            framesInSegment += n
            left -= n
            let full = framesInSegment == framesPerSegment
            if full { framesInSegment = 0 }
            runs.append((n, full))
        }
        return runs
    }
}

/// When the Watch must stop adding audio: it keeps everything until the iPhone has it, so a Watch
/// that can't reach its iPhone for a long time fills up. Recording pauses (it never deletes).
public enum WatchStorage {
    /// Free space the Watch keeps for itself.
    public static let minimumFree: Int64 = 300_000_000
    /// Audio waiting on the Watch, at most: about 40 h at 32 kbit/s.
    public static let maximumWaiting: Int64 = 600_000_000

    /// Why recording can't continue, or nil.
    public static func pauseReason(freeBytes: Int64?, waitingBytes: Int64) -> String? {
        if waitingBytes >= maximumWaiting {
            return "Paused: too much is waiting for your iPhone. Open Omi Notes on the iPhone, then tap Resume."
        }
        if let freeBytes, freeBytes < minimumFree {
            return "Paused: the Watch is almost full. Open Omi Notes on your iPhone to send what's waiting, then tap Resume."
        }
        return nil
    }
}
