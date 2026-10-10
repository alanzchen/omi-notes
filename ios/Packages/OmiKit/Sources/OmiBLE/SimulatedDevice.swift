import Foundation
import OmiCapture
import OmiProtocol

/// A recorded notification trace: `"OMITRC01"` then entries `[t_offset_us u32 LE][len u16 LE][bytes]`,
/// each `bytes` a raw audio notification `[seq u16 LE][fragment_index u8][opus…]`.
public struct SimulatedTrace: Sendable {
    public static let magic = Data("OMITRC01".utf8)

    public struct Entry: Sendable, Equatable {
        public var tOffsetUs: UInt32
        public var bytes: Data
    }

    public var entries: [Entry]
    public var codec: OmiCodec = .opus20ms

    public init(entries: [Entry]) { self.entries = entries }

    public static func parse(_ data: Data) -> SimulatedTrace? {
        let b = [UInt8](data)
        guard b.count >= 8, Data(b[0..<8]) == magic else { return nil }
        var off = 8
        var out: [Entry] = []
        while off + 6 <= b.count {
            let t = UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
            let len = Int(UInt16(b[off + 4]) | UInt16(b[off + 5]) << 8)
            guard off + 6 + len <= b.count else { break }
            out.append(Entry(tOffsetUs: t, bytes: Data(b[(off + 6)..<(off + 6 + len)])))
            off += 6 + len
        }
        return out.isEmpty ? nil : SimulatedTrace(entries: out)
    }

    public func serialized() -> Data {
        var d = Self.magic
        for e in entries {
            d.append(withUnsafeBytes(of: e.tOffsetUs.littleEndian) { Data($0) })
            d.append(withUnsafeBytes(of: UInt16(e.bytes.count).littleEndian) { Data($0) })
            d.append(e.bytes)
        }
        return d
    }

    /// Fallback when no bundled trace exists: 10 s of 20 ms notifications with pseudo-random payloads.
    public static func synthetic(seconds: Int = 10) -> SimulatedTrace {
        var rng = SplitMix64(seed: 42)
        var entries: [Entry] = []
        for i in 0..<(seconds * 50) {
            var bytes = Data([UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF), 0, 0xB8])  // header + CELT WB 20 ms TOC
            for _ in 0..<(60 + Int(rng.next() % 40)) { bytes.append(UInt8(truncatingIfNeeded: rng.next())) }
            entries.append(Entry(tOffsetUs: UInt32(i * 20_000), bytes: bytes))
        }
        return SimulatedTrace(entries: entries)
    }

    /// Opus frames (payload after the 3-byte header) for building ring records.
    public var opusFrames: [Data] { entries.map { Data($0.bytes.dropFirst(3)) } }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Packs Opus frames into 444-byte ring records like the firmware (`[ts u32 BE][len][frame]…`, zero
/// padded; a frame that does not fit starts the next record).
public enum RingRecordPacker {
    public static func pack(frames: [Data], startTimestamp: UInt32, framesPerSecond: Int = 50) -> [Data] {
        var records: [Data] = []
        var payload = Data()
        var frameIndex = 0
        var recordFirstFrame = 0
        func flush() {
            guard !payload.isEmpty else { return }
            var rec = RingProtocol.be(startTimestamp &+ UInt32(recordFirstFrame / framesPerSecond))
            rec.append(payload)
            rec.append(Data(count: RingProtocol.audioPayloadBytes - payload.count))
            records.append(rec)
            payload = Data()
            recordFirstFrame = frameIndex
        }
        for f in frames where !f.isEmpty && f.count < 255 {
            // Parse rule stops when offset + 1 + len >= 440, so a frame must end before byte 439.
            if payload.count + 1 + f.count >= RingProtocol.audioPayloadBytes { flush() }
            payload.append(UInt8(f.count))
            payload.append(f)
            frameIndex += 1
        }
        flush()
        return records
    }
}

/// Simulator stand-in for an Omi CV1: exposes every characteristic, replays a trace on the audio
/// characteristic in real time (with a silence gap between loops so idle rotation happens), and
/// serves a fake offline backlog over the ring protocol. Runs on the engine queue.
public final class SimulatedDevice: DeviceTransport, @unchecked Sendable {
    public static let deviceIdentifier = UUID(uuidString: "5EED0000-0000-4000-8000-00000000C0DE")!

    public let identifier = SimulatedDevice.deviceIdentifier
    public let name: String? = "Omi (Simulated)"
    public let maximumWriteValueLength = 244
    public let isSimulated = true
    public weak var delegate: DeviceTransportDelegate?

    public var firmwareRevision = "3.0.21"
    public var codecId: UInt8 = 21
    public var loopGapSeconds: Double = 8
    public var battery = 87

    private let queue: DispatchQueue
    private let clock: CaptureClock
    private let trace: SimulatedTrace
    private var timer: DispatchSourceTimer?
    private var streaming = false
    private var connected = false
    private var seq: UInt16 = 0xFFE0
    private var playbackStartMono: UInt64 = 0
    private var nextIndex = 0
    private var deviceTimeOffset: TimeInterval = 0
    /// The pendant's settings (in flash: they survive reconnects), as the CV1 firmware keeps them.
    public var ledBrightness = PendantSetting.ledBrightness.firmwareDefault
    public var micGain = PendantSetting.micGain.firmwareDefault
    /// Vibrations played (`HapticPulse` raw values).
    public private(set) var vibrations: [UInt8] = []
    /// Debug: settings and vibration writes fail, as a pendant that rejects them would.
    public var failControlWrites = false
    /// Debug: the features read fails (what it supports is then unknown).
    public var failFeaturesRead = false

    // Firmware update (MCUmgr SMP), as the firmware's image manager answers.
    /// What the device reports after restarting with an installed update.
    public var firmwareAfterUpdate: String?
    /// Debug: refuse uploads (MCUmgr error 3).
    public var refuseFirmwareUpload = false
    /// Debug: the link drops in the middle of the next upload (out of range).
    public var dropLinkDuringUpload = false
    /// The pendant restarted (an update's reset): the engine drops the link and reconnects.
    public var onRestart: (() -> Void)?
    /// The link was lost (out of range): the engine drops it and reconnects.
    public var onLinkLost: (() -> Void)?
    public private(set) var uploaded: [Int: Data] = [:]
    public private(set) var markedForInstall: Set<Data> = []
    private var smpAssembler = SMPAssembler()
    private var ring: [UInt64: Data] = [:]
    private var readSeq: UInt64 = 1000
    private var writeSeq: UInt64 = 1000
    private var transfer: (next: UInt64, end: UInt64, buffer: Data)?
    private var storageNotify = false
    private var disconnectedAt: Date?

    public init(queue: DispatchQueue, clock: CaptureClock, trace: SimulatedTrace, initialBacklogSeconds: Int = 20) {
        self.queue = queue
        self.clock = clock
        self.trace = trace
        appendBacklog(seconds: initialBacklogSeconds, endingAt: clock.wallNow())
    }

    public var unreadRecords: Int { Int(writeSeq - readSeq) }

    /// Called by the engine when the simulated link comes up.
    public func linkUp() {
        connected = true
        if let d = disconnectedAt {
            // "Recorded to SD" while the simulated phone was away.
            appendBacklog(seconds: min(120, Int(clock.wallNow().timeIntervalSince(d))), endingAt: clock.wallNow())
            disconnectedAt = nil
        }
    }

    public func linkDown() {
        connected = false
        streaming = false
        storageNotify = false
        transfer = nil
        disconnectedAt = clock.wallNow()
        timer?.cancel()
        timer = nil
    }

    public func press(_ code: Int32) {
        guard connected else { return }
        var d = withUnsafeBytes(of: code.littleEndian) { Data($0) }
        d.append(Data(count: 4))
        delegate?.transport(self, didUpdateValue: d, for: .button, error: nil)
    }

    // MARK: DeviceTransport

    public func discover() {
        after(0.05) { [weak self] in
            guard let self else { return }
            self.delegate?.transport(self, didDiscover: Set(OmiCharacteristic.allCases).subtracting([.serialNumber]), complete: true)
        }
    }

    public func read(_ c: OmiCharacteristic) {
        after(0.02) { [weak self] in
            guard let self, self.connected else { return }
            if c == .features, self.failFeaturesRead {
                self.delegate?.transport(self, didUpdateValue: nil, for: c, error: SimulatedControlError.rejected)
                return
            }
            self.delegate?.transport(self, didUpdateValue: self.value(for: c), for: c, error: nil)
        }
    }

    public func write(_ data: Data, to c: OmiCharacteristic) {
        after(0.02) { [weak self] in
            guard let self, self.connected else { return }
            if c == .timeSyncWrite, data.count == 4 {
                let secs = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                self.deviceTimeOffset = TimeInterval(UInt32(littleEndian: secs)) - self.clock.wallNow().timeIntervalSince1970
            }
            if [.ledDimRatio, .micGain, .haptic].contains(c) {
                if self.failControlWrites {
                    self.delegate?.transport(self, didWriteTo: c, error: SimulatedControlError.rejected)
                    return
                }
                // As the firmware: one byte, capped (transport.c), haptic levels 1–3 (haptic.c).
                if c == .ledDimRatio, data.count == 1 { self.ledBrightness = min(Int(data[0]), 100) }
                if c == .micGain, data.count == 1 { self.micGain = min(Int(data[0]), 8) }
                if c == .haptic, let level = data.first { self.vibrations.append(level) }
            }
            self.delegate?.transport(self, didWriteTo: c, error: nil)
            if c == .storageControl { self.handleStorageCommand(data) }
        }
    }

    public func writeWithoutResponse(_ data: Data, to c: OmiCharacteristic) -> Bool {
        guard connected, c == .smp, data.count <= maximumWriteValueLength else { return false }
        guard let request = smpAssembler.append(data) else { return true }
        after(0.005) { [weak self] in self?.answerSMP(request) }
        return true
    }

    private func answerSMP(_ r: SMPMessage) {
        guard connected else { return }
        var body: [(String, CBOR)] = [("rc", .uint(0))]
        switch (r.group, r.id, r.op) {
        case (SMPMessage.imageGroup, SMPMessage.imageUpload, .write):
            let image = r.body["image"]?.int ?? currentUploadImage
            let off = r.body["off"]?.int ?? -1
            if dropLinkDuringUpload, off > 0 {
                dropLinkDuringUpload = false
                onLinkLost?()
                return
            }
            if refuseFirmwareUpload {
                body = [("rc", .uint(3))]
            } else {
                if off == 0 { currentUploadImage = image; uploaded[image] = Data() }
                if off == uploaded[currentUploadImage]?.count, let chunk = r.body["data"]?.data { uploaded[currentUploadImage]?.append(chunk) }
                body.append(("off", .uint(UInt64(uploaded[currentUploadImage]?.count ?? 0))))
            }
        case (SMPMessage.imageGroup, SMPMessage.imageState, .read):
            let slots: [CBOR] = uploaded.sorted { $0.key < $1.key }.compactMap { image, bytes in
                guard let img = try? MCUbootImage(bytes) else { return nil }
                return .map([("image", .uint(UInt64(image))), ("slot", .uint(1)), ("hash", .bytes(img.hash)),
                             ("pending", .bool(markedForInstall.contains(img.hash)))])
            }
            body = [("images", .array(slots))]
        case (SMPMessage.imageGroup, SMPMessage.imageState, .write):
            if let hash = r.body["hash"]?.data, uploaded.values.contains(where: { (try? MCUbootImage($0))?.hash == hash }) {
                markedForInstall.insert(hash)
            } else {
                body = [("rc", .uint(3))]
            }
        case (SMPMessage.osGroup, SMPMessage.osReset, .write):
            after(0.3) { [weak self] in self?.restartAfterReset() }
        default:
            body = [("rc", .uint(8))]
        }
        let op: SMPMessage.Op = r.op == .read ? .readResponse : .writeResponse
        let answer = SMPMessage(op: op, group: r.group, id: r.id, sequence: r.sequence, body: .map(body)).encoded()
        var rest = answer[...]
        while !rest.isEmpty {  // notifications of at most one packet each
            let part = rest.prefix(maximumWriteValueLength)
            rest = rest.dropFirst(part.count)
            delegate?.transport(self, didUpdateValue: Data(part), for: .smp, error: nil)
        }
    }

    private var currentUploadImage = 0

    private func restartAfterReset() {
        if !markedForInstall.isEmpty, markedForInstall.count == uploaded.count, let version = firmwareAfterUpdate {
            firmwareRevision = version
        }
        uploaded = [:]
        markedForInstall = []
        smpAssembler.reset()
        onRestart?()
    }

    public func setNotify(_ enabled: Bool, for c: OmiCharacteristic) {
        after(0.03) { [weak self] in
            guard let self, self.connected else { return }
            self.delegate?.transport(self, didUpdateNotificationStateFor: c, enabled: enabled, error: nil)
            if c == .audioData, enabled, !self.streaming { self.startStreaming() }
            if c == .audioData, !enabled, self.streaming {
                // connected but not subscribed: the firmware drops its audio (transport.c pusher())
                self.streaming = false
                self.timer?.cancel()
                self.timer = nil
            }
            if c == .storageControl { self.storageNotify = enabled }
        }
    }

    // MARK: Values

    private func value(for c: OmiCharacteristic) -> Data {
        switch c {
        case .audioCodec: return Data([codecId])
        case .batteryLevel: return Data([UInt8(clamping: battery)])
        case .modelNumber: return Data("Omi CV 1".utf8)
        case .firmwareRevision: return Data(firmwareRevision.utf8)
        case .hardwareRevision: return Data("5.0".utf8)
        case .manufacturerName: return Data("Based Hardware (simulated)".utf8)
        case .features: return withUnsafeBytes(of: UInt32(0x1EC).littleEndian) { Data($0) }
        case .charging: return Data([0])
        case .ledDimRatio: return Data([UInt8(ledBrightness)])
        case .micGain: return Data([UInt8(micGain)])
        case .timeSyncRead:
            let t = UInt32(clamping: Int64(clock.wallNow().timeIntervalSince1970 + deviceTimeOffset))
            return withUnsafeBytes(of: t.littleEndian) { Data($0) }
        case .storageStatus:
            let unread = UInt32(writeSeq - readSeq)
            var d = Data()
            for v: UInt32 in [unread * 444, unread, 50_000_000, 1] { d.append(withUnsafeBytes(of: v.littleEndian) { Data($0) }) }
            return d
        default: return Data()
        }
    }

    // MARK: Live audio replay

    private func startStreaming() {
        streaming = true
        playbackStartMono = clock.monotonicNanoseconds()
        nextIndex = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.pumpAudio() }
        timer = t
        t.resume()
    }

    private func pumpAudio() {
        guard streaming, connected, let last = trace.entries.last else { return }
        let elapsedUs = Double(clock.monotonicNanoseconds() &- playbackStartMono) / 1000
        while nextIndex < trace.entries.count, Double(trace.entries[nextIndex].tOffsetUs) <= elapsedUs {
            var bytes = trace.entries[nextIndex].bytes
            if bytes.count >= 3 {
                bytes[bytes.startIndex] = UInt8(seq & 0xFF)
                bytes[bytes.startIndex + 1] = UInt8(seq >> 8)
            }
            seq &+= 1
            nextIndex += 1
            delegate?.transport(self, didUpdateValue: bytes, for: .audioData, error: nil)
        }
        if nextIndex >= trace.entries.count, elapsedUs >= Double(last.tOffsetUs) + loopGapSeconds * 1_000_000 {
            // Silence gap over (the mic "slept"); loop the trace.
            playbackStartMono = clock.monotonicNanoseconds()
            nextIndex = 0
        }
        pumpRing()
    }

    // MARK: Ring storage

    private func appendBacklog(seconds: Int, endingAt end: Date) {
        guard seconds > 0 else { return }
        let framesNeeded = seconds * 50
        var frames: [Data] = []
        let source = trace.opusFrames
        while frames.count < framesNeeded, !source.isEmpty { frames.append(source[frames.count % source.count]) }
        let start = UInt32(clamping: Int64(end.timeIntervalSince1970) - Int64(seconds))
        for rec in RingRecordPacker.pack(frames: frames, startTimestamp: start) {
            ring[writeSeq] = rec
            writeSeq += 1
        }
    }

    private func notifyStorage(_ bytes: [UInt8]) {
        guard storageNotify else { return }
        delegate?.transport(self, didUpdateValue: Data(bytes), for: .storageControl, error: nil)
    }

    private func handleStorageCommand(_ cmd: Data) {
        let b = [UInt8](cmd)
        guard let op = b.first else { return }
        switch op {
        case RingProtocol.Command.info:
            var d: [UInt8] = [RingProtocol.Opcode.info]
            d += [UInt8](RingProtocol.be(readSeq)) + [UInt8](RingProtocol.be(writeSeq))
            d += [UInt8](RingProtocol.be(UInt32(100_000))) + [UInt8](RingProtocol.be(UInt64(0)))
            d += [UInt8](RingProtocol.be(UInt16(444)))
            notifyStorage(d)
        case RingProtocol.Command.read:
            guard b.count == 9 || b.count == 13 else { notifyStorage([1, 6]); return }
            var start: UInt64 = 0
            for i in 1...8 { start = start << 8 | UInt64(b[i]) }
            guard start >= readSeq, start <= writeSeq else { notifyStorage([1, 10]); return }
            let count: UInt32 = b.count == 13 ? UInt32(b[9]) << 24 | UInt32(b[10]) << 16 | UInt32(b[11]) << 8 | UInt32(b[12]) : 0
            let end = count == 0 ? writeSeq : min(writeSeq, start + UInt64(count))
            notifyStorage([RingProtocol.Opcode.readBegin] + [UInt8](RingProtocol.be(start)) + [UInt8](RingProtocol.be(UInt32(end - start))))
            transfer = (start, end, Data())
        case RingProtocol.Command.advance:
            guard b.count == 9 else { notifyStorage([1, 6]); return }
            var seq: UInt64 = 0
            for i in 1...8 { seq = seq << 8 | UInt64(b[i]) }
            if seq >= readSeq, seq <= writeSeq { advance(to: seq); notifyStorage([1, 0]) } else { notifyStorage([1, 10]) }
        case RingProtocol.Command.stop:
            transfer = nil
        default:
            notifyStorage([1, 6])
        }
    }

    private func advance(to seq: UInt64) {
        while readSeq < seq { ring.removeValue(forKey: readSeq); readSeq += 1 }
    }

    /// Streams DATA notifications (unaligned, MTU-sized) a few per audio tick.
    private func pumpRing() {
        guard var t = transfer, connected else { return }
        let chunk = maximumWriteValueLength - 1
        for _ in 0..<6 {
            while t.buffer.count < chunk, t.next < t.end, let rec = ring[t.next] {
                t.buffer.append(rec)
                t.next += 1
            }
            if t.buffer.isEmpty {
                transfer = nil
                advance(to: t.next)  // firmware checkpoints the read pointer at DONE
                notifyStorage([RingProtocol.Opcode.done, 0] + [UInt8](RingProtocol.be(t.next)))
                return
            }
            let n = min(chunk, t.buffer.count)
            notifyStorage([RingProtocol.Opcode.data] + [UInt8](t.buffer.prefix(n)))
            t.buffer = Data(t.buffer.dropFirst(n))
        }
        transfer = t
    }

    private func after(_ seconds: Double, _ body: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + seconds, execute: body)
    }
}

enum SimulatedControlError: Error, LocalizedError {
    case rejected
    var errorDescription: String? { "the simulated pendant rejected the write" }
}
