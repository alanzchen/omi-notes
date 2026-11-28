// ASTRA-20261119-IT1 review checks (reused unchanged).
import Foundation
import CryptoKit
import Testing
@testable import OmiBLE
@testable import OmiCapture
@testable import OmiWatchKit
@Suite(.serialized) struct AstraNovember19WatchChecks {
 @Test func missingSourceLeavesTheExistingBytesAndManifest() throws {
  let p=try WatchReceiptDurabilityTests().part();let box=WatchOutbox(root:p.root.appendingPathComponent("watch"))
  defer {try? FileManager.default.removeItem(at:p.root);try? FileManager.default.removeItem(at:p.file)}
  let original=try Data(contentsOf:p.file);try box.add(segmentFile:p.file,segment:p.segment)
  let held=try #require(box.segments().first?.file)
  #expect(throws:(any Error).self) {try box.add(segmentFile:p.file,segment:p.segment)}
  #expect(try Data(contentsOf:held)==original)
  #expect(WatchOutbox(root:box.root).segments().first?.segment==p.segment)
 }
 @Test func aTruncatedReplacementCannotDestroyTheOnlyGoodCopy() throws {
  let p=try WatchReceiptDurabilityTests().part();let box=WatchOutbox(root:p.root.appendingPathComponent("watch"))
  defer {try? FileManager.default.removeItem(at:p.root);try? FileManager.default.removeItem(at:p.file)}
  let original=try Data(contentsOf:p.file);try box.add(segmentFile:p.file,segment:p.segment)
  let held=try #require(box.segments().first?.file)
  try original.prefix(1).write(to:p.file)
  try? box.add(segmentFile:p.file,segment:p.segment)
  // 2026-11-28: publish checks a replacement against its manifest first (no longer a known issue)
  let now=try Data(contentsOf:held)
  #expect(now==original,"a replacement must match the manifest before replacing good audio")
 }
 @Test func quarantineDoesNotRetireItsDurableInboxUntilDestinationConfirmed() throws {
  let p=try WatchReceiptDurabilityTests().part();defer {try? FileManager.default.removeItem(at:p.root);try? FileManager.default.removeItem(at:p.file)}
  try p.inbox.accept(file:p.file,segment:p.segment);#expect(try p.held())
  let q=p.root.appendingPathComponent("quarantine")
  try FileManager.default.createDirectory(at:q,withIntermediateDirectories:true)
  try FileManager.default.setAttributes([.posixPermissions:0o300],ofItemAtPath:q.path)
  defer {try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:q.path)}
  let fd=open(q.path,O_RDONLY),error=errno;if fd>=0{close(fd)};try #require(fd<0 && error==EACCES)
  p.inbox.quarantine(p.segment,reason:"synthetic decode rejection")
  #expect(FileManager.default.fileExists(atPath:p.inboxDir.appendingPathComponent("\(p.segment.id).m4a").path),"keep durable inbox source until quarantine directory sync succeeds")
 }
}
// nested in RetryFlowTests (serialized): every suite on the shared AppServerStub runs one at a time
extension RetryFlowTests {
@MainActor @Suite(.serialized) struct AstraNovember19SearchChecks {
 @Test func immediateOfflineFailureCompletesTheRealModel() async throws {
  let(m,root)=try RetryFlowTests().model();defer {try? FileManager.default.removeItem(at:root)}
  AppServerStub.offline=true
  await m.refreshServer()
  let result=await m.search("synthetic",personId:nil,range:.any)
  if case .failure(let e)=result {#expect(!(e is CancellationError))} else {Issue.record("no cache: expected immediate transport error")}
 }
 @Test func cancelledSearchReturnsCancellationWithoutChangingViewTaskKey() async throws {
  let(m,root)=try RetryFlowTests().model();defer {try? FileManager.default.removeItem(at:root)}
  AppServerStub.offline=true;await m.refreshServer()
  let key=m.serverIdentity
  let task=Task {await m.search("synthetic",personId:nil,range:.any)}
  task.cancel()
  let result=await task.value
  if case .failure(let e)=result {#expect(e is CancellationError)} else {Issue.record("expected cancellation")}
  #expect(m.serverIdentity==key)
 }
}
}

/// 2026-11-19 R3: a search left on "Searching…" in the field said nothing in the phone log. Each finished search now
/// leaves one rate-limited `[search]` line: whether the server was asked and the outcome, never the query.
// nested in RetryFlowTests (serialized): every suite on the shared AppServerStub runs one at a time
extension RetryFlowTests {
@MainActor @Suite(.serialized) struct SearchLogTests {
    @Test func aSearchLeavesALineWithItsOutcomeButNotItsQuery() async throws {
        let (m, root) = try RetryFlowTests().model()
        defer { try? FileManager.default.removeItem(at: root) }
        AppServerStub.offline = true
        await m.refreshServer()
        SearchLog.reset()
        _ = await m.search("zebra-synthetic-query", personId: nil, range: .any)
        let lines = OmiLog.shared.recent().filter { $0.category == "search" }
        let line = try #require(lines.last)
        #expect(line.message.contains("asked server") && line.message.contains("outcome"), "\(line.message)")
        #expect(!lines.contains { $0.message.contains("zebra") }, "never the query text")
    }
}
}

/// 2026-11-28 R1: a replacement only takes a part's place after it matches the part's manifest (size and SHA-256).
@Suite(.serialized) struct WatchReplacementChecks {
    @Test func aMatchingReAddOfAPublishedPartIsStillAccepted() throws {
        // a part published the way build 66 publishes it, then the same bytes offered again (e.g. after a relaunch)
        let p = try WatchReceiptDurabilityTests().part(); let box = WatchOutbox(root: p.root.appendingPathComponent("watch"))
        defer { try? FileManager.default.removeItem(at: p.root); try? FileManager.default.removeItem(at: p.file) }
        let original = try Data(contentsOf: p.file); try box.add(segmentFile: p.file, segment: p.segment)
        try original.write(to: p.file)
        try box.add(segmentFile: p.file, segment: p.segment)
        #expect(try Data(contentsOf: try #require(box.segments().first?.file)) == original)
    }

    @Test func aMismatchedFirstAddPublishesNothingAndLeavesTheSourceInPlace() throws {
        let p = try WatchReceiptDurabilityTests().part(); let box = WatchOutbox(root: p.root.appendingPathComponent("watch"))
        defer { try? FileManager.default.removeItem(at: p.root); try? FileManager.default.removeItem(at: p.file) }
        let original = try Data(contentsOf: p.file)
        try original.prefix(100).write(to: p.file)
        #expect(throws: (any Error).self) { try box.add(segmentFile: p.file, segment: p.segment) }
        #expect(box.segments().isEmpty, "never a part whose bytes don't match its manifest")
        #expect(try Data(contentsOf: p.file) == original.prefix(100), "the source is kept, never deleted")
    }
}
