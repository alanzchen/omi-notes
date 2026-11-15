import Foundation
public enum WKApplicationState {case active,inactive,background}
@MainActor public final class WKApplication {
 private static let singleton=WKApplication()
 public static func shared()->WKApplication{singleton}
 public var applicationState=WKApplicationState.active
}
