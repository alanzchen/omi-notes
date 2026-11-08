import Foundation
import Testing
@testable import OmiCapture

/// The rolling diagnostic log the phone uploads to its own server: only diagnostic categories and
/// warnings/errors, tokens redacted, bounded batches after a cursor, bounded file. Synthetic lines.
@Suite struct PhoneLogTests {
    func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("omi-phonelog-\(UUID().uuidString).jsonl") }

    @Test func onlyDiagnosticLinesAreKeptWithTokensRedacted() {
        let url = file(), log = OmiLog()
        log.persist(to: url)
        log.registerSecret("tok-secret-123")
        log.log(.info, "upload", "PUT chunk_a → 201 (Bearer abcdef)")
        log.log(.info, "cache", "saved the note 'Budget review'")  // not a diagnostic category
        log.log(.warning, "cache", "couldn't save a note")
        log.log(.info, "app", "configured with token=tok-secret-123")
        let lines = PhoneLogTail.lines(at: url, after: nil)
        #expect(lines.map(\.category) == ["upload", "cache", "app"] && lines[1].level == "warning")
        #expect(!lines.contains { $0.message.contains("abcdef") || $0.message.contains("tok-secret-123") || $0.message.contains("Budget") })
    }

    @Test func aBatchIsTheNewestLinesAfterTheCursor() throws {
        let url = file()
        let rows = (0..<10).map { i in PhoneLogLine(at: String(format: "2026-11-07T21:00:%02d.000Z", i), level: "info", category: "upload", message: "line \(i)") }
        try Data(rows.map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! + "\n" }.joined().utf8).write(to: url)
        #expect(PhoneLogTail.lines(at: url, after: rows[6].at).map(\.message) == ["line 7", "line 8", "line 9"])
        #expect(PhoneLogTail.lines(at: url, after: nil, limit: 2).map(\.message) == ["line 8", "line 9"], "the newest when capped")
    }

    @Test func theFileStaysBounded() {
        let url = file(), log = OmiLog()
        log.persist(to: url)
        for i in 0..<2_500 { log.log(.info, "upload", "line \(i) " + String(repeating: "x", count: 250)) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 0 && size <= OmiLog.persistMaxBytes + 1_000)
        #expect(PhoneLogTail.lines(at: url, after: nil, limit: 1).first?.message.hasPrefix("line 2499") == true)
    }

    // R42-01 (astra-review-42-20261108): percent-encoding must not hide a credential from redaction.

    /// Every %XX decoded, as often as it nests, ignoring malformed escapes (what a reader could recover).
    func recoverable(_ s: String) -> String {
        var cur = s
        for _ in 0..<4 { cur = OmiLog.percentDecoded(cur) }
        return cur
    }

    @Test(arguments: [false, true])
    func encodedCredentialsAreRedacted(registered: Bool) {
        let url = file(), log = OmiLog()
        log.persist(to: url)
        if registered { log.registerSecret("SYNTHETIC-PAIRING-SECRET") }
        log.log(.warning, "app", "link omi-notes://configure?%74oken=SYNTHETIC%2DPAIRING%2DSECRET")
        log.log(.warning, "app", "link omi-notes://configure?url=x&%2574oken=SYNTHETIC%252DPAIRING%252DSECRET")
        log.log(.warning, "app", "link omi-notes://configure?TOKEN=SYNTHETIC-PAIRING-SECRET%ZZ&url=%E2%9C")
        log.log(.warning, "app", "nested https://a.example/?next=omi-notes%3A%2F%2Fconfigure%3Ftoken%3DSYNTHETIC-PAIRING-SECRET")
        let lines = PhoneLogTail.lines(at: url, after: nil)
        #expect(lines.count == 4)
        for line in lines { #expect(!recoverable(line.message).contains("SYNTHETIC-PAIRING-SECRET"), "\(line.message)") }
    }

    @Test func anExistingRawTailIsSanitizedBeforeItLeaves() throws {
        let url = file()
        let raw = PhoneLogLine(at: "2026-11-07T21:00:00.000Z", level: "warning", category: "app",
                               message: "ignored URL omi-notes://configure?%74oken=SYNTHETIC%2DOLD%2DSECRET")
        try (String(data: try JSONEncoder().encode(raw), encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        let sent = PhoneLogTail.lines(at: url, after: nil, sanitize: OmiLog().sanitize)
        #expect(sent.count == 1 && !recoverable(sent[0].message).contains("SYNTHETIC-OLD-SECRET"), "an upload re-sanitizes old lines")
        let log = OmiLog()
        log.persist(to: url)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(!recoverable(onDisk).contains("SYNTHETIC-OLD-SECRET"), "and the file itself is scrubbed when logging starts")
    }

    // R42-02: the batch is bounded by its real encoded body, envelope included.

    @Test(arguments: [String(repeating: "\"", count: 300), String(repeating: "\\", count: 300),
                      String(repeating: "\u{01}", count: 300), String(repeating: "\u{1F600}é", count: 150)])
    func aBatchFitsTheEncodedBodyLimit(message: String) throws {
        let url = file()
        let rows = (0..<400).map { PhoneLogLine(at: String(format: "2026-11-07T21:%02d:%02d.000Z", $0 / 60, $0 % 60), level: "warning",
                                                category: "upload", message: message) }
        try Data(rows.map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! + "\n" }.joined().utf8).write(to: url)
        let tail = PhoneLogTail.lines(at: url, after: nil)
        #expect(!tail.isEmpty && tail.last?.at == rows.last?.at, "the newest lines")
        let (body, sent) = PhoneLogTail.body(deviceId: "phone-" + UUID().uuidString.lowercased(), appVersion: "0.1.0 (43)", lines: tail)
        #expect(body.count <= PhoneLogTail.maxBodyBytes && body.count <= 64 * 1024)
        #expect(sent == tail, "the tail already fits the body")
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect((decoded?["lines"] as? [Any])?.count == sent.count)
    }

    @Test func anOversizedBatchKeepsItsOldestLinesSoTheCursorSkipsNothing() {
        let rows = (0..<400).map { PhoneLogLine(at: String(format: "2026-11-07T21:%02d:%02d.000Z", $0 / 60, $0 % 60), level: "warning",
                                                category: "upload", message: String(repeating: "\"", count: 500)) }
        let (body, sent) = PhoneLogTail.body(deviceId: "phone-x", appVersion: nil, lines: rows)
        #expect(body.count <= PhoneLogTail.maxBodyBytes && !sent.isEmpty && sent.count < rows.count)
        #expect(sent == Array(rows.prefix(sent.count)))
    }

    /// Pendant-storage sync lines (category "ring") are uploaded too, successes included, so the
    /// server can show whether offline audio is being collected (the re-subscribe fix, 2026-11-08).
    @Test func pendantStorageSyncLinesAreKept() {
        let url = file(), log = OmiLog()
        log.persist(to: url)
        log.log(.info, "ring", "sync complete: 12 records, 0 duplicates dropped, next_seq 40")
        log.log(.info, "ring", "re-subscribing to storage notifications")
        #expect(PhoneLogTail.lines(at: url, after: nil).map(\.category) == ["ring", "ring"])
    }
}
