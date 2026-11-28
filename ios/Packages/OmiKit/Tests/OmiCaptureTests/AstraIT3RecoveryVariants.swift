// ASTRA-20261119-IT3-01 (omi-notes-reviews/nightly-2026-11-19-it3/swift/AstraR3RecoveryVariants.swift), copied
// unchanged in substance. The missing / unreadable header variants ran under `withKnownIssue` from 11-19 to 11-28; the
// publication ledger closes them (build/deployment/nightly/2026-11-28/round1/DESIGN.md), so all four are plain
// expectations now.
import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol
@Suite(.serialized) struct AstraIT3RecoveryVariants {
 @Test(arguments:["missing", "unreadable", "invalid-json", "too-long"])
 func publishedWithoutSuccessorDoesNotChangeIdentity(variant:String) throws {
  var t=TestEnv();let faults=FaultInjector();t.env.faults=faults
  var recorder:LiveCaptureRecorder?=try LiveCaptureTests().recorder(t).0
  let id=try #require(recorder?.captureId)
  let dir=t.dirs.journalLive.appendingPathComponent(id),h=dir.appendingPathComponent("chunk-000000.header")
  defer { AstraR4Checks().allow(t.dirs.outboxPending);AstraR4Checks().allow(dir);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:h.path) }
  #expect(recorder?.append(notification(seq:0)) == true)
  // A real creation failure of the successor journal after the old chunk was published.
  faults.manifestSave={try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:dir.path);throw InjectedFault(what:"checkpoint")}
  try AstraR4Checks().restrict(t.dirs.outboxPending);t.clock.advance(61);recorder?.tick();recorder=nil
  try #require(!FileIO.exists(dir.appendingPathComponent("chunk-000001.journal")))
  let journal=dir.appendingPathComponent("chunk-000000.journal")
  let output=t.dirs.outboxPending.appendingPathComponent(OutboxKind.chunk(captureId:id,sequence:0).fileName)
  let original=try Data(contentsOf:output),raw=try Data(contentsOf:journal)
  try FileManager.default.removeItem(at:output)
  AstraR4Checks().allow(dir);AstraR4Checks().allow(t.dirs.outboxPending)
  switch variant {
  case "missing": try FileManager.default.removeItem(at:h)
  case "unreadable":
    try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:h.path)
    #expect(throws:(any Error).self){_ = try Data(contentsOf:h)}
  case "invalid-json": try Data("{".utf8).write(to:h)
  default: var hdr=try JSONDecoder().decode(EnvelopeHeader.self,from:Data(contentsOf:h));hdr.payloadBytes+=1;try Envelope.headerJSON(hdr).write(to:h)
  }
  _=CaptureRecovery.run(env:TestEnv(root:t.dirs.root).env,codecFallback:{_ in 21})
  if let rebuilt=try? Data(contentsOf:output) {
   let a=try Envelope.parse(original),b=try Envelope.parse(rebuilt)
   print("NO SUCCESSOR \(variant): old=\(a.header.chunkEndOffsetUs) new=\(b.header.chunkEndOffsetUs) samePayload=\(a.payload==b.payload)")
   #expect(a.payload==b.payload)  // the audio itself is never changed
   // 2026-11-28: closed by the capture's publication ledger (published.jsonl), no longer a known issue
   #expect(rebuilt==original,"uncertain published identity must not be re-derived")
  } else {#expect(try Data(contentsOf:journal)==raw)}
 }
 @Test func aNeverPublishedOpenJournalStillRecovers() throws {
  let t=TestEnv();var rec:LiveCaptureRecorder?=try LiveCaptureTests().recorder(t).0
  let id=try #require(rec?.captureId);#expect(rec?.append(notification(seq:0)) == true);rec?.syncNow();rec=nil
  let dir=t.dirs.journalLive.appendingPathComponent(id)
  #expect(!FileIO.exists(dir.appendingPathComponent("chunk-000000.header")))
  _=CaptureRecovery.run(env:TestEnv(root:t.dirs.root).env,codecFallback:{_ in 21})
  #expect(t.outbox.contains(.chunk(captureId:id,sequence:0)))
  #expect(t.outbox.contains(.seal(captureId:id)))
  #expect(!FileIO.exists(dir))
 }
}
