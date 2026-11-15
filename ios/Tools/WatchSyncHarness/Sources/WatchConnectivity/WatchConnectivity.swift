import Foundation
public enum WCSessionActivationState: Int, Sendable { case notActivated, inactive, activated }
public protocol WCSessionDelegate: AnyObject {}
public final class WCSessionFile: @unchecked Sendable {
 public var metadata: [String:Any]?
 public let fileURL: URL
 public init(_ url: URL, _ m: [String:Any]?) { fileURL=url; metadata=m }
}
public final class WCSessionFileTransfer: @unchecked Sendable {
 public var isTransferring = true
 public let progress = Progress(totalUnitCount:1000)
 public var cancelCount = 0
 public func cancel() { cancelCount += 1; WCSession.default.outstandingFileTransfers.removeAll { $0 === self } }
 public let file: WCSessionFile
 public init(_ f: WCSessionFile) { file=f }
}
public final class WCSessionUserInfoTransfer: @unchecked Sendable {
 public let userInfo: [String:Any]
 public init(_ u: [String:Any]) { userInfo=u }
 public func cancel() { WCSession.default.outstandingUserInfoTransfers.removeAll { $0 === self } }
}
public final class WCSession: @unchecked Sendable {
 public static let `default` = WCSession()
 public static func isSupported() -> Bool { true }
 public weak var delegate: WCSessionDelegate?
 public var activationState = WCSessionActivationState.activated
 public var hasContentPending = false
 public var isReachable = false
 public var isPaired = true
 public var isWatchAppInstalled = true
 public var receivedApplicationContext: [String:Any] = [:]
 public var outstandingFileTransfers: [WCSessionFileTransfer] = []
 public var outstandingUserInfoTransfers: [WCSessionUserInfoTransfer] = []
 public var allFiles: [WCSessionFileTransfer] = []
 public func activate() {}
 public func updateApplicationContext(_ m: [String:Any]) throws {}
 @discardableResult public func transferFile(_ u: URL, metadata: [String:Any]?) -> WCSessionFileTransfer {
  let t=WCSessionFileTransfer(WCSessionFile(u,metadata)); outstandingFileTransfers.append(t); allFiles.append(t); return t
 }
 @discardableResult public func transferUserInfo(_ m: [String:Any]) -> WCSessionUserInfoTransfer {
  let t=WCSessionUserInfoTransfer(m); outstandingUserInfoTransfers.append(t); return t
 }
 public func sendMessage(_ m: [String:Any], replyHandler: (([String:Any])->Void)?, errorHandler: ((Error)->Void)?) {}
 public func reset() { outstandingFileTransfers=[]; outstandingUserInfoTransfers=[]; allFiles=[]; receivedApplicationContext=[:] }
}
