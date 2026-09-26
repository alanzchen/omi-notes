import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

@Suite struct ServerURLPolicyTests {
    @Test func httpsAcceptedHttpOnlyForLocalHosts() {
        #expect(ServerURLPolicy.evaluate("https://mac.tail1234.ts.net").verdict == .ok)
        #expect(ServerURLPolicy.evaluate("  https://mac.tail1234.ts.net/omi  ").url?.absoluteString == "https://mac.tail1234.ts.net/omi")
        let local = [
            "http://localhost:8765", "http://127.0.0.1:8765", "http://192.168.1.20:8765", "http://10.0.0.5",
            "http://172.16.0.1", "http://172.31.255.254", "http://169.254.3.4", "http://studio.local:8765",
            "http://100.64.0.1:8765", "http://100.127.255.255", "http://[::1]:8765", "http://[fe80::1]",
            "http://[fd7a:115c:a1e0::1]:8765", "http://[::ffff:192.168.0.2]",
        ]
        for u in local {
            if case .insecureLocal = ServerURLPolicy.evaluate(u).verdict {} else { Issue.record("\(u) should be allowed with a warning") }
        }
        let rejected = [
            "http://mac.tail1234.ts.net", "http://example.com", "http://mac", "http://172.32.0.1", "http://172.15.0.1",
            "http://100.128.0.1", "http://100.63.255.255", "http://8.8.8.8", "http://[2606:4700:4700::1111]:8000",
            "http://[::ffff:8.8.8.8]", "http://[fe00::1]", "http://1.2.3", "http://local", "ftp://x.y", "not a url",
            "https://x.y/?token=1", "https://user:pw@x.y", "",
        ]
        for bad in rejected {
            #expect(!ServerURLPolicy.evaluate(bad).verdict.isAcceptable, "\(bad)")
        }
    }
}

@Suite struct ConfigureLinkTests {
    @Test func parsesPairingQR() throws {
        let url = URL(string: "omi-notes://configure?url=https%3A%2F%2Fmac.tail1234.ts.net&token=0123456789abcdef")!
        let link = try #require(ConfigureLink.parse(url))
        #expect(link.url == "https://mac.tail1234.ts.net")
        #expect(link.token == "0123456789abcdef")
        #expect(link.maskedToken == "0123…cdef")
        #expect(ConfigureLink.parse(URL(string: "omi-notes://configure?url=https%3A%2F%2Fx")!) == nil)
        #expect(ConfigureLink.parse(URL(string: "omi-notes://other?url=a&token=b")!) == nil)
        #expect(ConfigureLink.parse(URL(string: "https://configure?url=a&token=b")!) == nil)
    }

    @Test func settingsStoreKeepsTokenOutOfDefaults() throws {
        let defaults = UserDefaults(suiteName: "omi-settings-\(UUID().uuidString)")!
        let tokens = InMemoryTokenStore()
        let s = SettingsStore(defaults: defaults, tokens: tokens)
        #expect(s.endpoint == nil)
        try s.setServer(url: URL(string: "https://mac.ts.net")!, token: "tok-123456")
        #expect(s.endpoint == ServerEndpoint(baseURL: URL(string: "https://mac.ts.net")!, token: "tok-123456"))
        #expect(try tokens.load() == "tok-123456")
        #expect(!(defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("tok-123456") == true }))
    }
}

@Suite struct SimulatorPiecesTests {
    @Test func traceRoundTrip() throws {
        let t = SimulatedTrace.synthetic(seconds: 2)
        #expect(t.entries.count == 100)
        let parsed = try #require(SimulatedTrace.parse(t.serialized()))
        #expect(parsed.entries == t.entries)
        #expect(SimulatedTrace.parse(Data("nope".utf8)) == nil)
    }

    @Test func packerMatchesFirmwareParseRule() {
        var rng = SplitMix64(seed: 7)
        let frames = (0..<200).map { _ in Data((0..<(60 + Int(rng.next() % 100))).map { _ in UInt8(truncatingIfNeeded: rng.next()) | 1 }) }
        let records = RingRecordPacker.pack(frames: frames, startTimestamp: 1_790_000_000)
        #expect(records.allSatisfy { $0.count == 444 })
        let back = records.flatMap { RingProtocol.parseAudioPayload($0.dropFirst(4)) }
        #expect(back == frames)
        #expect(RingProtocol.recordTimestamp(records[0]) == 1_790_000_000)
    }
}

final class CountingUploadTransport: UploadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [String] = []
    var started: [String] { lock.lock(); defer { lock.unlock() }; return _started }
    func activeTaskIdentifiers(_ completion: @escaping @Sendable (Set<String>) -> Void) { completion(Set(started)) }
    func startUpload(_ request: URLRequest, fromFile: URL, identifier: String, earliestBeginDate: Date?) {
        lock.lock(); _started.append(identifier); lock.unlock()
    }
    func cancel(identifiers: Set<String>) { lock.lock(); _started.removeAll { identifiers.contains($0) }; lock.unlock() }
    func cancelAll() { lock.lock(); _started.removeAll(); lock.unlock() }
    var startedNames: Set<String> { Set(started.compactMap { UploadTaskID.parse($0)?.name }) }
}

/// End-to-end in real time: simulated device → session → journal/ring sync → outbox → uploader.
@Suite(.serialized) struct EngineSimulatedDeviceTests {
    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @Test func simulatedDeviceStreamsSyncsAndSeals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-engine-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "omi-engine-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.tail1234.ts.net")!, token: "tok-engine-test")
        let uploads = CountingUploadTransport()
        let engine = OmiEngine(
            config: EngineConfiguration(
                dirs: CaptureDirectories(root: root), appVersion: "test", timezone: "UTC",
                simulatedTrace: SimulatedTrace.synthetic(seconds: 3), useCoreBluetooth: false, tickInterval: 0.2),
            settings: settings, uploadTransport: uploads)

        engine.setSimulatedMode(true)
        let streaming = await waitFor(10) {
            let s = engine.snapshotNow()
            if case .complete = s.offline { return s.connection == .streaming && (s.live?.totalRecords ?? 0) > 20 }
            return false
        }
        let snap = engine.snapshotNow()
        #expect(streaming, "snapshot: \(snap.connection) \(snap.offline) \(String(describing: snap.live))")
        #expect(snap.device?.codec == .opus20ms)
        #expect(snap.device?.offlineSupport == .supported)

        engine.simulateButton(code: 2)  // double tap: event + rotation
        try await Task.sleep(nanoseconds: 300_000_000)
        engine.sendHeartbeatNow()  // coverage now references the rotated chunk(s)
        try await Task.sleep(nanoseconds: 100_000_000)
        engine.simulateOutOfRange(returnAfter: 60)
        try await Task.sleep(nanoseconds: 800_000_000)

        let outbox = Outbox(dirs: CaptureDirectories(root: root))
        let items = outbox.pending() + outbox.sent()
        let chunks = items.compactMap { item -> EnvelopeHeader? in
            guard item.kind.isChunk, let d = try? Data(contentsOf: item.url) else { return nil }
            return try? Envelope.parse(d).header
        }
        let seals = items.compactMap { item -> SealBody? in
            guard case .seal = item.kind, let d = try? Data(contentsOf: item.url) else { return nil }
            return try? JSONDecoder().decode(SealBody.self, from: d)
        }
        let events = items.filter { if case .event = $0.kind { return true } else { return false } }
            .compactMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: $0.url)) as? [String: Any] }

        #expect(chunks.contains { $0.source == .liveBLE && $0.codecId == 21 && $0.recordCount > 0 })
        #expect(chunks.contains { $0.source == .deviceRing && $0.ring?.recordSize == 444 })
        #expect(seals.contains { $0.source == .liveBLE && $0.reason == .bleDisconnected && $0.lastChunkSequence >= 1 })
        #expect(seals.contains { $0.source == .deviceRing && $0.reason == .syncComplete && $0.ring?.doneNextSeq != nil })
        #expect(events.contains { $0["type"] as? String == "button" && ($0["data"] as? [String: Any])?["code"] as? Int == 2 })
        let liveCapture = try #require(seals.first { $0.source == .liveBLE })
        _ = liveCapture
        let coverages = events.compactMap { ($0["data"] as? [String: Any])?["coverage"] as? [String: Any] }
        #expect(!coverages.isEmpty)
        for c in coverages {
            // Coverage only references rotated chunks, and ends exactly at that chunk's end.
            let seq = c["through_chunk_sequence"] as? Int ?? -1
            let chunk = chunks.first { $0.captureId == c["capture_id"] as? String && $0.chunkSequence == seq }
            #expect(chunk?.chunkEndOffsetUs == (c["through_offset_us"] as? NSNumber)?.int64Value)
        }
        // Back-to-back live chunks; seal end == last chunk end.
        let live = chunks.filter { $0.source == .liveBLE }.sorted { $0.chunkSequence < $1.chunkSequence }
        for (a, b) in zip(live, live.dropFirst()) { #expect(a.chunkEndOffsetUs == b.chunkStartOffsetUs) }
        #expect(liveCapture.endOffsetUs == live.last?.chunkEndOffsetUs)
        #expect(liveCapture.lastChunkSequence == live.last?.chunkSequence)
        // Everything written was handed to the upload transport.
        let uploaded = await waitFor(3) { Set(outbox.pending().map(\.name)).isSubset(of: uploads.startedNames) }
        #expect(uploaded)
        #expect(FileIO.contents(of: CaptureDirectories(root: root).journalLive).isEmpty)
        #expect(FileIO.contents(of: CaptureDirectories(root: root).journalRing).isEmpty)
        engine.setSimulatedMode(false)
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
