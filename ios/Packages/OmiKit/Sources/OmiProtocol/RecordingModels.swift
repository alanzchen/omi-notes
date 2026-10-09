import Foundation

/// `GET /v1/conversations/{id}/recording`: what of a note's recording can be played.
public struct RecordingInfo: Decodable, Equatable, Sendable {
    public struct Span: Decodable, Equatable, Sendable {
        public var startedAt: String?
        public var endedAt: String?
        public var seconds: Double
    }

    public struct Gap: Decodable, Equatable, Sendable {
        public var startedAt: String?
        public var endedAt: String?
        public var seconds: Double
    }

    public var available: Bool
    /// `expired`, `no_audio`, `in_progress`, `too_long` when not available.
    public var reason: String?
    /// What can be played (time with no recorded audio is a gap, not included).
    public var durationS: Double?
    public var span: Span?
    public var gaps: [Gap]?
    public var partial: Bool?
    /// `[playable offset s, wall-clock epoch, seconds]` per playable part.
    public var timemap: [[Double]]?
    public var url: String?
}

/// Where each playable part sits on the clock, and where the unrecorded gaps fall.
public struct RecordingTimeline: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public var offset: Double
        public var wallStart: Double
        public var seconds: Double
    }

    public var parts: [Part]
    public var duration: Double

    public init(_ info: RecordingInfo) {
        parts = (info.timemap ?? []).compactMap { $0.count == 3 ? Part(offset: $0[0], wallStart: $0[1], seconds: $0[2]) : nil }
        duration = info.durationS ?? 0
    }

    /// The clock time heard at a playable offset.
    public func wallClock(at offset: Double) -> Date? {
        guard let part = parts.last(where: { $0.offset <= offset }) ?? parts.first else { return nil }
        return Date(timeIntervalSince1970: part.wallStart + min(max(offset - part.offset, 0), part.seconds))
    }

    /// The playable offset where a clock time was recorded; nil when that moment has no audio (a
    /// gap, or outside the recording).
    public func offset(at wall: Date) -> Double? {
        let t = wall.timeIntervalSince1970
        guard let part = parts.first(where: { t >= $0.wallStart - 0.5 && t <= $0.wallStart + $0.seconds }) else { return nil }
        return part.offset + min(max(t - part.wallStart, 0), part.seconds)
    }

    /// Playable offsets (0…1 of the duration) where an unrecorded gap sits between two parts.
    public var gapMarks: [Double] {
        guard duration > 0 else { return [] }
        return zip(parts, parts.dropFirst()).compactMap { a, b in
            b.wallStart - (a.wallStart + a.seconds) > 0.05 ? b.offset / duration : nil
        }
    }
}
