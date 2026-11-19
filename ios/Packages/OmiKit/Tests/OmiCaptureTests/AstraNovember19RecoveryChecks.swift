// ASTRA-20261119-IT1 review checks (reused unchanged).
import Foundation
import Testing
@testable import OmiCapture
import OmiProtocol
@Suite(.serialized) struct AstraNovember19RecoveryChecks {
 @Test func frozenRecoveryIsStableAcrossTwoFailedPassesAndThenSuccess() throws {
  var t=TestEnv();let faults=FaultInjector();t.env.faults=faults
  var recorder:LiveCaptureRecorder?=try LiveCaptureTests().recorder(t).0
  let id=try #require(recorder?.captureId)
  defer { AstraR4Checks().allow(t.dirs.outboxPending) }
  #expect(recorder?.append(notification(seq:0)) == true)
  faults.manifestSave={throw InjectedFault(what:"manifest")}
  try AstraR4Checks().restrict(t.dirs.outboxPending);t.clock.advance(61);recorder?.tick();recorder=nil
  let dir=t.dirs.journalLive.appendingPathComponent(id)
  let output=t.dirs.outboxPending.appendingPathComponent(OutboxKind.chunk(captureId:id,sequence:0).fileName)
  let original=try Data(contentsOf:output)
  try FileManager.default.removeItem(at:output)
  for _ in 0..<2 {
   _=CaptureRecovery.run(env:TestEnv(root:t.dirs.root).env,codecFallback:{_ in 21})
   #expect(try Data(contentsOf:output)==original)
   #expect(FileIO.exists(dir))
  }
  AstraR4Checks().allow(t.dirs.outboxPending)
  _=CaptureRecovery.run(env:TestEnv(root:t.dirs.root).env,codecFallback:{_ in 21})
  #expect(!FileIO.exists(dir));#expect(try Data(contentsOf:output)==original)
  let seal=t.dirs.outboxPending.appendingPathComponent(OutboxKind.seal(captureId:id).fileName)
  let s=try JSONDecoder().decode(SealBody.self,from:Data(contentsOf:seal))
  #expect(s.endOffsetUs == 61_000_000)
 }
 @Test(arguments:["missing","invalid-json","wrong-length"])
 func staleManifestWithUnusableFrozenHeaderPreservesIdentity(variant:String) throws {
  var t=TestEnv();let faults=FaultInjector();t.env.faults=faults
  var recorder:LiveCaptureRecorder?=try LiveCaptureTests().recorder(t).0
  let id=try #require(recorder?.captureId)
  defer { AstraR4Checks().allow(t.dirs.outboxPending) }
  #expect(recorder?.append(notification(seq:0)) == true)
  faults.manifestSave={throw InjectedFault(what:"manifest")}
  try AstraR4Checks().restrict(t.dirs.outboxPending);t.clock.advance(61);recorder?.tick();recorder=nil
  let dir=t.dirs.journalLive.appendingPathComponent(id),header=dir.appendingPathComponent("chunk-000000.header"),journal=dir.appendingPathComponent("chunk-000000.journal")
  let output=t.dirs.outboxPending.appendingPathComponent(OutboxKind.chunk(captureId:id,sequence:0).fileName)
  let original=try Data(contentsOf:output),raw=try Data(contentsOf:journal)
  try FileManager.default.removeItem(at:output)
  if variant=="missing" {try FileManager.default.removeItem(at:header)}
  else if variant=="invalid-json" {try Data("{".utf8).write(to:header)}
  else {var h=try JSONDecoder().decode(EnvelopeHeader.self,from:Data(contentsOf:header));h.payloadBytes+=1;try Envelope.headerJSON(h).write(to:header)}
  AstraR4Checks().allow(t.dirs.outboxPending)
  _=CaptureRecovery.run(env:TestEnv(root:t.dirs.root).env,codecFallback:{_ in 21})
  let rebuilt=try? Data(contentsOf:output)
  if let rebuilt {
   let a=try Envelope.parse(original),b=try Envelope.parse(rebuilt)
   print("UNUSABLE HEADER \(variant): samePayload=\(a.payload==b.payload), oldEnd=\(a.header.chunkEndOffsetUs), newEnd=\(b.header.chunkEndOffsetUs)")
   #expect(a.payload==b.payload)
  } else {#expect(try Data(contentsOf:journal)==raw)}
  #expect(rebuilt==nil || rebuilt==original,"preserve the known published identity, or retain the journal")
 }
}
