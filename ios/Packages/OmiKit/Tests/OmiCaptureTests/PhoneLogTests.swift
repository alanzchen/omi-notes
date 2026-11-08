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
}
