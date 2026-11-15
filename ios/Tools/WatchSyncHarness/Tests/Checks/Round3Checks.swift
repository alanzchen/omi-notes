import Foundation
// Checks from Astra's review OMI-NIGHTLY-2026-11-15-IT3-REVIEW (ASTRA-20261115-IT3); the cancel checks are gone with the reverted cancel-and-resend.
import CryptoKit
import Testing
import OmiWatchKit
import WatchConnectivity
@Suite(.serialized) @MainActor struct Round3Checks {
 func settle() async { for _ in 0..<30 { await Task.yield() } }
 func policy() throws -> WatchResendPolicy { try JSONDecoder().decode(WatchResendPolicy.self,from:try #require(ReviewDefaults.shared.data(forKey:"omi.resendPolicy"))) }
 @Test func oldAttemptReceiptStillRetiresAudioAndOffActorCallbacksAreSafe() async throws {
  let (w,m,_)=try await DeltaChecks().setup();let old=try #require(WCSession.default.allFiles.first)
  ReviewClock.now=ReviewClock.now.addingTimeInterval(1801);w.pump()
  await Task.detached {
   w.session(WCSession.default,didFinish:old,error:nil)
   w.session(WCSession.default,didReceiveUserInfo:[WatchWire.binding:"phone-A",WatchWire.receipts:WatchWire.inventoryItems([WatchInventoryItem(id:m.id,sha256:m.sha256)])])
  }.value
  await settle()
  #expect(w.outbox.segments().isEmpty)
  #expect(try policy().entries[m.id]==nil)
 }
 @Test func oldAndDamagedPreferencesAndFutureClockDoNotCrashLaunch() async throws {
  let (old,m,root)=try await DeltaChecks().setup()
  let valid=try #require(ReviewDefaults.shared.data(forKey:"omi.resendPolicy"))
  var value=try #require(JSONSerialization.jsonObject(with:valid) as? [String:Any])
  var entries=try #require(value["entries"] as? [String:[String:Any]])
  entries[m.id]?.removeValue(forKey:"attempt");value["entries"]=entries;value.removeValue(forKey:"nextAttempt")
  let legacy=try JSONSerialization.data(withJSONObject:value)
  for state in [legacy,Data("broken".utf8),valid] {
   for clock in [Data("broken".utf8),Data("{}".utf8),Data("{\"progress\":{\"x\":{\"bytes\":0,\"at\":1e100}}}".utf8)] {
    ReviewDefaults.shared.set(state,forKey:"omi.resendPolicy");ReviewDefaults.shared.set(clock,forKey:"omi.transferStalls")
    let fresh=WatchSync(outbox:old.outbox,perf:WatchPerfQueue(root:root.appendingPathComponent("perf")))
    await Task.detached {fresh.session(WCSession.default,activationDidCompleteWith:.activated,error:nil)}.value
    await settle();#expect(fresh.pending==1)
   }
  }
 }
 @Test func manyStallsAndRelaunchStayInsideFourNewAttempts() async throws {
  let (w,_,root)=try await DeltaChecks().setup()
  let bytes=Data("more synthetic audio".utf8)
  for i in 1...15 {
   let url=root.appendingPathComponent("extra-\(i).m4a");try bytes.write(to:url)
   let m=WatchSegment(recordingId:UUID().uuidString,index:0,deviceId:"test",deviceName:"synthetic",binding:"phone-A",recordingStartedAt:ReviewClock.now,startOffsetUs:0,endOffsetUs:1000000,bytes:bytes.count,sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
   try w.outbox.add(segmentFile:url,segment:m)
  }
  w.pump();w.pump();#expect(WCSession.default.outstandingFileTransfers.count==4)
  ReviewClock.now=ReviewClock.now.addingTimeInterval(181);w.pump();#expect(WCSession.default.outstandingFileTransfers.count==8)
  ReviewClock.now=ReviewClock.now.addingTimeInterval(1801);w.pump()
  #expect(WCSession.default.outstandingFileTransfers.count==8 && WCSession.default.allFiles.allSatisfy{$0.cancelCount==0},"never cancelled, never past twice the window")
  let before=WCSession.default.allFiles.count
  let fresh=WatchSync(outbox:w.outbox,perf:WatchPerfQueue(root:root.appendingPathComponent("perf")))
  fresh.session(WCSession.default,activationDidCompleteWith:.activated,error:nil);await settle()
  #expect(WCSession.default.allFiles.count==before && fresh.outbox.segments().count==16)
 }
}
