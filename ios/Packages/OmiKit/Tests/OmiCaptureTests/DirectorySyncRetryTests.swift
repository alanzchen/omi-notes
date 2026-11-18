import Foundation
import Testing
@testable import OmiCapture

/// ASTRA-20261118-IT2-02: the directory-sync loop went on after a successful fsync (100 syncs for one) and, after 100
/// interruptions, returned as if it had synced. One call on success; an immediate throw on any other error; a throw
/// once the retries run out. The same semantics as OmiWatchKit's `Files.fsync` (`anInterruptedSyncIsRetried…`).
@Suite struct DirectorySyncRetryTests {
    final class Calls: @unchecked Sendable { var count = 0 }

    func run(_ results: [Int32]) -> (calls: Int, error: Error?) {
        let calls = Calls()
        do {
            try FileIO.retryInterrupted("fsync directory") {
                let r = results[min(calls.count, results.count - 1)]
                calls.count += 1
                if r == 0 { return 0 }
                errno = r
                return -1
            }
            return (calls.count, nil)
        } catch { return (calls.count, error) }
    }

    @Test func aSuccessfulSyncIsCalledOnce() {
        let r = run([0])
        #expect(r.calls == 1 && r.error == nil)
    }

    @Test func oneInterruptionThenSuccessReturns() {
        let r = run([EINTR, 0])
        #expect(r.calls == 2 && r.error == nil)
    }

    @Test func anotherErrorThrowsAtOnceWithItsErrno() {
        let r = run([EIO])
        #expect(r.calls == 1)
        #expect(r.error?.localizedDescription.contains("errno \(EIO)") == true)
    }

    @Test func endlessInterruptionsThrowWhenTheRetriesRunOut() {
        let r = run([EINTR])
        #expect(r.calls == 100)
        #expect(r.error?.localizedDescription.contains("errno \(EINTR)") == true, "\(String(describing: r.error))")
    }

    @Test func aRealDirectorySyncSucceeds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omi-dirsync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileIO.syncDirectory(dir)
    }
}
