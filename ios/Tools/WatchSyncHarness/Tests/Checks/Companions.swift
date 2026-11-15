import Foundation
import OmiWatchKit
@MainActor final class ReviewDefaults {
 static let shared=ReviewDefaults();var values:[String:Any]=[:]
 func string(forKey k:String)->String?{values[k] as? String}
 func data(forKey k:String)->Data?{values[k] as? Data}
 func object(forKey k:String)->Any?{values[k]}
 func set(_ value:Any?,forKey k:String){values[k]=value}
}
@MainActor enum ReviewClock{static var now=Date(timeIntervalSince1970:10000)}
@MainActor final class ComplicationPublisher{func update(recorder:ComplicationSnapshot.Recorder,waitingParts:Int,waitingSeconds:Int,bound:Bool){}}
enum WatchRecorder{static let deviceId="synthetic-watch"}
struct Log:Sendable{func info(_ s:String){};func error(_ s:String){}}
let watchLog=Log()
