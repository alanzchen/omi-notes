// Astra's IT3 checks (omi-notes-reviews/nightly-2026-11-20-it3/swift/AstraNovember20R3Checks.swift), adopted as regressions
// unchanged.
import Foundation
import Testing
@testable import OmiBLE

@Suite(.serialized) struct AstraNovember20R3Checks {
 @Test(arguments:[CentralState.poweredOff,.resetting])
 func poweredOnMustReplaceADelayedConnectLostByRadioReset(off:CentralState) {
  let h=CentralHarness(),p=FakePeripheral(UUID(),state:.connected)
  h.on {h.controller.rememberedId=p.identifier;h.backend.known[p.identifier]=p;h.backend.state = .poweredOn;h.controller.backendDidConnect(p);h.controller.restartLink(backoff:0.4)}
  #expect(h.backend.delays.count==1 && p.connectionState == .connecting)
  h.on {
   // A radio reset/off transition destroys the OS pending connection. Its disconnect callback may arrive while off.
   h.backend.state=off;p.connectionState = .disconnected
   h.controller.backendDidUpdateState(off);h.controller.backendDidDisconnect(p,error:nil)
   h.backend.state = .poweredOn;h.controller.backendDidUpdateState(.poweredOn)
  }
  #expect(h.backend.delays.count==2,"poweredOn must re-submit the remaining delay if no pending connection exists")
  h.drain(after:0.55)
  #expect(p.connectionState == .connecting,"there must still be a pending connection after the deadline, not a stranded disconnected handle")
  print("RADIO RESET: delayed calls=\(h.backend.delays.count), state=\(p.connectionState)")
 }
 @Test(arguments:[ReconnectSuppression.storageLow,.simulatedMode])
 func automaticSuppressionRecoveryMustRestoreThePendingConnection(reason:ReconnectSuppression) {
  let h=CentralHarness(),p=FakePeripheral(UUID(),state:.connected)
  h.on {
   h.controller.rememberedId=p.identifier;h.backend.known[p.identifier]=p;h.backend.state = .poweredOn;h.controller.backendDidConnect(p)
   h.controller.restartLink(backoff:0.4)
   h.controller.suppress(reason);h.controller.backendDidDisconnect(p,error:nil)
   // Actual storage-recovery / simulation-off path: unsuppress and ensure, not explicit Reconnect/clearBackoff.
   h.controller.unsuppress(reason);h.controller.ensureConnected()
  }
  #expect(h.backend.delays.count==2,"automatic recovery must re-submit the delayed connect it withdrew")
  h.drain(after:0.55)
  #expect(p.connectionState == .connecting,"no pending connect remains, even after the deadline, unless another event intervenes")
  print("SUPPRESSION RECOVERY \(reason): delayed calls=\(h.backend.delays.count), state=\(p.connectionState)")
 }
 @Test func restoredPendingConnectIsAdoptedWithoutAnImmediateRekick() {
  let h=CentralHarness(),p=FakePeripheral(UUID(),state:.connecting)
  h.on {
   h.controller.rememberedId=p.identifier;h.backend.known[p.identifier]=p
   h.controller.backendWillRestore([p])
   h.backend.state = .poweredOn;h.controller.backendDidUpdateState(.poweredOn)
   h.controller.ensureConnected() // same startup recovery call as OmiEngine
  }
  #expect(h.backend.connects.isEmpty,"the restored connection already belongs to CoreBluetooth; do not reissue without its saved delay")
  #expect(h.backend.cancels.isEmpty)
  print("RESTORATION: immediate kicks=\(h.backend.connects.count), delayed kicks=\(h.backend.delays.count)")
 }
 @Test func aFailedDelayedAttemptIsReissuedWithRemainingDelay() {
  let h=CentralHarness(),p=FakePeripheral(UUID(),state:.connected)
  h.on {h.controller.rememberedId=p.identifier;h.backend.state = .poweredOn;h.controller.backendDidConnect(p);h.controller.restartLink(backoff:0.4)}
  h.on {p.connectionState = .disconnected;h.controller.backendDidFailToConnect(p,error:nil)}
  #expect(h.backend.delays.count==2 && p.connectionState == .connecting)
  #expect(h.backend.delays.last!>0 && h.backend.delays.last!<=0.4)
 }
 @Test func noStaleShortKickAfterAReadyConnectionClearsBackoff() {
  let h=CentralHarness(),p=FakePeripheral(UUID(),state:.connected)
  h.on {
   h.controller.rememberedId=p.identifier;h.backend.state = .poweredOn;h.controller.backendDidConnect(p)
   h.controller.restartLink();h.controller.restartLink(backoff:0.4)
   p.connectionState = .connected;h.controller.backendDidConnect(p);h.controller.clearBackoff()
  }
  h.drain(after:0.5)
  #expect(h.backend.connects.count==1 && h.delegate.connected.count==2)
 }
 @Test func aLateCancellationCallbackDoesNotStartASecondSession() {
  let h=CentralHarness(),p=FakePeripheral(UUID(),state:.connected)
  h.on {
   h.controller.rememberedId=p.identifier;h.backend.known[p.identifier]=p;h.backend.state = .poweredOn;h.controller.backendDidConnect(p)
   h.controller.restartLink(backoff:0.4);h.controller.clearBackoff();h.controller.ensureConnected()
   // cancellation completion for the withdrawn request arrives after the new immediate pending connect
   h.controller.backendDidDisconnect(p,error:nil)
  }
  h.drain(after:0.2)
  #expect(h.delegate.connected.count==1 && p.connectionState == .connecting)
  print("CANCEL-CLEAR: total connect requests=\(h.backend.connects.count) (including original delayed request)")
 }
}
