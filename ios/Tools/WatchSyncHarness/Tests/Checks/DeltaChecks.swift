import Foundation
// Checks from Astra's review OMI-NIGHTLY-2026-11-15-IT1-REVIEW (ASTRA-20261115-IT1-02/04), on the real WatchSync.
import CryptoKit
import Testing
import OmiWatchKit
import WatchConnectivity
@Suite(.serialized) @MainActor struct DeltaChecks {
 func setup() async throws -> (WatchSync,WatchSegment,URL) {
  WCSession.default.reset();ReviewDefaults.shared.values=[:];ReviewClock.now=Date(timeIntervalSince1970:10000)
  ReviewDefaults.shared.set("phone-A",forKey:"omi.phoneBinding")
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("watch-sync-harness-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let bytes=Data("synthetic audio for receipt safety".utf8),source=root.appendingPathComponent("source.m4a")
  try bytes.write(to:source)
  let m=WatchSegment(recordingId:UUID().uuidString,index:0,deviceId:"test",deviceName:"synthetic",binding:"phone-A",recordingStartedAt:ReviewClock.now,startOffsetUs:0,endOffsetUs:1000000,bytes:bytes.count,sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
  let out=WatchOutbox(root:root.appendingPathComponent("watch"));try out.add(segmentFile:source,segment:m)
  let sync=WatchSync(outbox:out,perf:WatchPerfQueue(root:root.appendingPathComponent("perf")))
  sync.session(WCSession.default,activationDidCompleteWith:.activated,error:nil)
  for _ in 0..<20 { await Task.yield() }
  ReviewClock.now=ReviewClock.now.addingTimeInterval(1);sync.pump()
  return (sync,m,root)
 }
 // 2026-11-15 round 7: the automatic cancel-and-resend is reverted. A stalled transfer is never cancelled, never sent a
 // second time beside itself, across a relaunch too, and its audio stays until a receipt.
 @Test func aStalledTransferIsNeverCancelledOrDuplicated() async throws {
  let (w,_,root)=try await setup();let t=try #require(WCSession.default.allFiles.first)
  for minutes in [31.0,61.0] { ReviewClock.now=ReviewClock.now.addingTimeInterval(minutes*60);w.pump() }
  let fresh=WatchSync(outbox:w.outbox,perf:WatchPerfQueue(root:root.appendingPathComponent("perf")))
  fresh.session(WCSession.default,activationDidCompleteWith:.activated,error:nil)
  for _ in 0..<20 { await Task.yield() }
  ReviewClock.now=ReviewClock.now.addingTimeInterval(1801);fresh.pump()
  #expect(t.cancelCount==0 && WCSession.default.allFiles.count==1 && fresh.outbox.segments().count==1)
 }
 @Test func ordinaryDeliveryAndPlainAckKeepAudioButMatchingReceiptRetiresIt() async throws {
  let (w,m,_)=try await setup();let t=try #require(WCSession.default.allFiles.first)
  WCSession.default.outstandingFileTransfers=[]
  w.session(WCSession.default,didFinish:t,error:nil)
  for _ in 0..<20 {await Task.yield()}
  w.session(WCSession.default,didReceiveUserInfo:[WatchWire.binding:"phone-A",WatchWire.acks:[m.id]])
  for _ in 0..<20 {await Task.yield()}
  #expect(w.outbox.segments().count==1)
  w.session(WCSession.default,didReceiveUserInfo:[WatchWire.binding:"phone-A",WatchWire.receipts:WatchWire.inventoryItems([WatchInventoryItem(id:m.id,sha256:m.sha256)])])
  for _ in 0..<20 {await Task.yield()}
  #expect(w.outbox.segments().isEmpty)
 }
}
