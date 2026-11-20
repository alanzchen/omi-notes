// Astra's IT2 checks (omi-notes-reviews/nightly-2026-11-20-it2/swift/AstraNovember20R2Checks.swift), adopted as
// regressions. Two of them documented ASTRA-20261120-IT2-01 by asserting that NO pending connect exists while the
// queue is suspended; they keep their names but now assert the required outcome: an OS-owned pending connect exists
// during the backoff, before any in-process timer could run. Two controls are adapted where they encoded the old
// timer: the success check's "eventual recovery" second kick, and suppression/forget/replacement (the old pending connect
// withdrawn, rather than never issued).
import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol
import OmiWatchKit
extension RetryFlowTests {
@Suite(.serialized) struct AstraNovember20R2Checks {
 @Test func successWithoutManualResetMustClearCentralDeadline() async throws {
  let r=try DiscoveryBackoffTests.Rig()
  defer {r.engine.disconnect();r.engine.queue.sync{};try? FileManager.default.removeItem(at:r.root)}
  for _ in 0..<2 { _=try await r.connectOnce(window:0.3) }
  _=try await r.connectOnce(window:0.02) // third discovery sets 0.6s delay
  r.failing=false
  _=try await r.connectOnce(window:0.02) // a late/restored connection succeeds during that delay
  #expect(r.engine.snapshotNow().connection == .streaming)
  r.engine.queue.sync {r.p.connectionState = .disconnected;r.events.backendDidDisconnect(r.p,error:nil)}
  let n=try await r.connects(within:0.3)
  #expect(n==1,"successful setup should lift the old deadline; observed \(n) reconnects before 0.6s")
  // (adapted: her control expected the old deadline's timer to kick again later; now one pending connect stands)
  #expect(try await r.connects(within:0.5)==0 && r.p.connectionState == .connecting,"one pending connect, no stale kick")
 }
 @Test func disconnectAndConnectFailureKicksShouldCoalesce() {
  let h=CentralHarness(),p=FakePeripheral(UUID(),state:.connected)
  h.on {h.controller.rememberedId=p.identifier;h.backend.state = .poweredOn;h.controller.backendDidConnect(p)
   h.controller.restartLink(backoff:0.3);h.controller.backendDidDisconnect(p,error:nil);h.controller.backendDidFailToConnect(p,error:nil)
   for _ in 0..<10 {h.controller.ensureConnected()}
  }
  h.drain(after:0.4)
  print("COALESCING: \(h.backend.connects.count) pending-connect kicks")
  #expect(h.backend.connects.count==1)
 }
 @Test func backoffHasNoPendingConnectionWhileExecutionIsSuspended() {
  let h=CentralHarness(),p=FakePeripheral(UUID(),state:.connected)
  h.on {h.controller.rememberedId=p.identifier;h.backend.state = .poweredOn;h.controller.backendDidConnect(p);h.controller.restartLink(backoff:0.3)}
  h.queue.suspend()
  Thread.sleep(forTimeInterval:0.65)
  // No work on this queue can change the fake backend while it is suspended: the pending connect must already be
  // the system's (IT2-01), issued when the link was restarted.
  #expect(h.backend.connects.count==1 && p.connectionState == .connecting)
  h.queue.resume();h.drain()
  #expect(h.backend.connects.count==1,"no second kick once execution resumes")
 }
 @Test func realEngineBackoffHasNoPendingConnectDuringBackgroundSuspension() async throws {
  let r=try DiscoveryBackoffTests.Rig()
  defer {r.engine.disconnect();r.engine.queue.sync{};try? FileManager.default.removeItem(at:r.root)}
  r.engine.appDidEnterBackground();r.engine.queue.sync{}
  for _ in 0..<2 {_=try await r.connectOnce(window:0.3)}
  let before=r.engine.queue.sync {r.backend.connects.count}
  _=try await r.connectOnce(window:0.02)
  #expect(r.engine.session==nil)
  r.engine.queue.suspend()
  try await Task.sleep(for:.milliseconds(900))
  // while the process can't run, the pendant already has a pending connect (the system's, delayed by the backoff)
  #expect(r.backend.connects.count==before+1 && r.p.connectionState == .connecting)
  r.engine.queue.resume();r.engine.queue.sync{}
  #expect(r.engine.queue.sync{r.backend.connects.count}==before+1,"no second kick once execution resumes")
 }
 @Test(arguments:[ReconnectSuppression.userDisconnected,.pairingLost,.storageLow,.unsupportedDevice,.simulatedMode,.codecUnreadable])
 func suppressionWinsDuringBackoff(reason:ReconnectSuppression) {
  let h=CentralHarness(),p=FakePeripheral(UUID(),state:.connected)
  h.on {h.controller.rememberedId=p.identifier;h.backend.state = .poweredOn;h.controller.backendDidConnect(p);h.controller.restartLink(backoff:0.15);h.controller.suppress(reason)}
  // (adapted: the backoff's pending connect is the system's and exists before the suppression; suppression withdraws it
  // and nothing connects again)
  h.drain(after:0.25);#expect(h.backend.connects.count<=1 && p.connectionState == .disconnected && !h.backend.cancels.isEmpty)
 }
 @Test func newIdentityOrForgetWinsDuringBackoff() {
  for forget in [true,false] {
   let h=CentralHarness(),p=FakePeripheral(UUID(),state:.connected),new=FakePeripheral(UUID())
   h.on {h.controller.rememberedId=p.identifier;h.backend.state = .poweredOn;h.backend.known[new.identifier]=new;h.controller.backendDidConnect(p);h.controller.restartLink(backoff:0.15)
    if forget {h.controller.forget()} else {h.controller.rememberedId=new.identifier;h.controller.clearBackoff();h.controller.connect(to:new.identifier)}
   }
   // (adapted: the old pendant's backoff connect is the system's, issued before forget/replacement, which withdraw it)
   h.drain(after:0.25);#expect(h.backend.connects == (forget ? [p.identifier]:[p.identifier,new.identifier]) && p.connectionState == .disconnected)
  }
 }
 @Test func foregroundImmediatelyLiftsBackoff() async throws {
  let r=try DiscoveryBackoffTests.Rig()
  defer {r.engine.disconnect();r.engine.queue.sync{};try? FileManager.default.removeItem(at:r.root)}
  for _ in 0..<2 {_=try await r.connectOnce(window:0.3)}
  _=try await r.connectOnce(window:0.02)
  r.engine.appDidEnterBackground();r.engine.queue.sync{}
  let n=r.engine.queue.sync{r.backend.connects.count}
  r.engine.appDidBecomeActive();r.engine.queue.sync{}
  #expect(r.engine.queue.sync{r.backend.connects.count} == n+1)
 }
 @Test func discoveryTimeoutIsMarkedAsDiscoveryFailure() {
  let h=SessionHarness();defer{try? FileManager.default.removeItem(at:h.dirs.root)}
  h.session.start()
  for _ in 0..<3 {h.clock.advance(16);h.session.tick()}
  #expect(h.session.discoveryFailed);#expect(h.delegate.reconnectRequests==["service discovery timed out"])
 }
 @Test func transfersStalledOnlyForCurrentPositiveMeasuredCounts() {
  let now=Date(timeIntervalSince1970:1_795_000_000)
  for age in [-1.0,0,600,601] {for stalled:Int? in [nil,0,2,3] {
   var s=EngineSnapshot();s.serverConfigured=true;s.watchLastReceivedAt=now.addingTimeInterval(-3600)
   s.watchReport=WatchReport(state:.idle,since:nil,waitingParts:3,waitingSeconds:140,at:now.addingTimeInterval(-age),stats:stalled.map{["outstanding_stalled":$0]})
   let t=TransferSummary.evaluate(snapshot:s,server:.reachable(version:"t",detail:""),status:nil,statusAt:nil,watchInstalled:true,nowMono:0,now:now)
   let expected=age>=0 && age<=600 && stalled==3
   #expect(t.watch.stalled==expected)
   #expect(t.watchLine(now:now).contains("未在发送")==expected)
   #expect((t.problemLine(now:now)?.contains("手表传输已停止") ?? false)==expected)
  }}
  let t=TransferSummary.evaluate(snapshot:EngineSnapshot(),server:.unknown,status:nil,statusAt:nil,watchInstalled:nil,nowMono:0,now:now)
  #expect(!t.watch.stalled && !t.everythingSent)
 }
 @Test func connectedPendantNeverGetsDisconnectedCardEvenWithItsIssue() {
  let now=Date();var s=EngineSnapshot();s.ready=true;s.rememberedDeviceId=UUID().uuidString;s.connection = .streaming;s.recordingPaused=true
  let v=PendantSummary.evaluate(snapshot:s,server:.unknown,status:nil,statusAt:nil,now:now)
  #expect(v.connected && v.cardState != "Not connected")
 }
 @Test func settingUpPausedPendantMustNotClaimDisconnected() {
  let now=Date();var s=EngineSnapshot();s.ready=true;s.rememberedDeviceId=UUID().uuidString;s.connection = .settingUp;s.recordingPaused=true
  let v=PendantSummary.evaluate(snapshot:s,server:.unknown,status:nil,statusAt:nil,now:now)
  #expect(v.cardState != "Not connected","settingUp is emitted only for an existing DeviceSession on a connected link")
 }
}
}
