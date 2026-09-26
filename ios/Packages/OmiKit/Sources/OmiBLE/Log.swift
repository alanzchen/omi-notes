import Foundation
import OmiCapture

@inline(__always)
func log(_ level: LogLine.Level, _ category: String, _ message: @autoclosure () -> String) {
    OmiLog.shared.log(level, category, message())
}
