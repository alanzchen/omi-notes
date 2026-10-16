import AVFoundation
import Foundation
import OmiCapture
import OmiProtocol
import OmiWatchKit

/// Turns Apple Watch segments the phone has received into upload envelopes (`watch_mic`,
/// `pcm16le_v1`): one capture per Watch recording, one chunk per segment, sealed after its last
/// segment. Runs on the engine queue; every step is idempotent (the outbox refuses to publish an
/// identity twice with different bytes, and repeats with the same bytes are no-ops).
final class WatchRelayProcessor {
    let inbox: PhoneWatchInbox
    let outbox: Outbox
    let appVersion: String?
    let timezone: String?

    /// The server keeps and decodes the Watch's AAC itself (`watch_aac`).
    let serverTakesAAC: () -> Bool

    init(inbox: PhoneWatchInbox, outbox: Outbox, appVersion: String?, timezone: String?, serverTakesAAC: @escaping () -> Bool = { false }) {
        self.inbox = inbox
        self.outbox = outbox
        self.appVersion = appVersion
        self.timezone = timezone
        self.serverTakesAAC = serverTakesAAC
    }

    /// The part's own AAC file as the payload (no decode, no re-encode), with its frame count from
    /// the file's header; nil if it isn't the 16 kHz mono file the Watch writes.
    static func aacPayload(_ url: URL) throws -> (data: Data, frames: Int)? {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.sampleRate == 16_000, file.fileFormat.channelCount == 1, file.length > 0 else { return nil }
        return (try Data(contentsOf: url), Int(file.length))
    }

    /// Converts what is waiting; returns how many outbox items were written.
    @discardableResult
    func process() -> Int {
        var written = 0
        for (segment, file) in inbox.pending() {
            do {
                let payload: Data, samples: Int, format: PayloadFormat
                if inbox.format(of: segment.recordingId, choosing: { serverTakesAAC() ? "aac" : "pcm" }) == "aac",
                   let aac = try Self.aacPayload(file) {
                    (payload, samples, format) = (aac.data, aac.frames, .aacM4aV1)
                } else {
                    let pcm = try WatchAudio.pcm16(from: file)
                    (payload, samples, format) = (pcm, pcm.count / 2, .pcm16leV1)
                }
                let end = segment.startOffsetUs + Int64(samples) * 1_000_000 / 16_000
                let header = EnvelopeHeader(
                    captureId: segment.recordingId, chunkSequence: segment.index, deviceId: segment.deviceId,
                    deviceName: segment.deviceName, modelNumber: "Apple Watch", firmwareRevision: nil, hardwareRevision: nil,
                    source: .watchMic, payloadFormat: format, codecId: 0,
                    captureStartedAt: ISO8601UTC.format(segment.recordingStartedAt),
                    chunkStartOffsetUs: segment.startOffsetUs, chunkEndOffsetUs: end, clockQuality: .unknown,
                    timezone: timezone, recordCount: samples, payloadBytes: payload.count, offlineStorage: nil, ring: nil,
                    appVersion: appVersion)
                try outbox.write(try Envelope.build(header: header, payload: payload), kind: .chunk(captureId: segment.recordingId, sequence: segment.index))
                try inbox.markConverted(segment, chunkEndUs: end)
                written += 1
            } catch let e as OutboxError {
                log(.error, "watch", "segment \(segment.id) conflicts with what was already queued: \(e)")
                inbox.quarantine(segment, reason: "\(e)")
            } catch {
                // unreadable audio: kept aside (never deleted), and the recording can still be sealed
                log(.error, "watch", "segment \(segment.id) couldn't be converted: \(error)")
                inbox.quarantine(segment, reason: "\(error)")
            }
        }
        for (end, lastChunkEnd) in inbox.readyEnds() {
            let seal = SealBody(lastChunkSequence: end.lastIndex, reason: end.reason == .userStopped ? .userStopped : .appRecovered,
                                endedAt: ISO8601UTC.format(end.endedAt), endOffsetUs: lastChunkEnd ?? end.endOffsetUs,
                                deviceId: end.deviceId, source: .watchMic)
            do {
                try outbox.write(try ContractJSON.encode(seal), kind: .seal(captureId: end.recordingId))
                try inbox.markSealed(end)
                written += 1
            } catch {
                log(.error, "watch", "couldn't seal Watch recording \(end.recordingId): \(error)")
            }
        }
        if written > 0 { log(.info, "watch", "queued \(written) Apple Watch upload item(s)") }
        return written
    }
}

/// Audio decoding for Watch segments (AAC in .m4a, any rate) to 16 kHz mono PCM16 LE.
enum WatchAudio {
    static func pcm16(from url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(max(file.length, 1))) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / source.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw CocoaError(.fileReadCorruptFile) }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .endOfStream; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? CocoaError(.fileReadCorruptFile) }
        guard let samples = output.int16ChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}
