// ASTRA-20261116-IT3 review checks (reused unchanged).
import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol
@testable import OmiWatchKit

@Suite(.serialized) struct AstraBuildRepairChecks {
    func fixture() -> (OmiEngine,URL,SettingsStore) { AstraWatchBuildChecks().fixture() }
    func report(_ e:OmiEngine,_ id:String?,_ build:Int?,_ at:Date) {
        e.acceptWatchReport(WatchWire.encode(WatchReport(state:.idle,since:nil,waitingParts:3,at:at,deviceId:id,stats:["orphan_parts":0],appBuild:build)))
    }
    @Test func futureSkewBoundaryAndClockCorrectedDowngrade() throws {
        let (e,_,_)=fixture();let n=Date(timeIntervalSince1970:1_800_000_000)
        func put(_ id:String,_ offset:TimeInterval,_ b:Int=49){e.watchInbox.saveAppBuild(WatchAppBuild(build:b,at:n.addingTimeInterval(offset),deviceId:id,source:.report,receivedAt:n))}
        put("under",599.9);put("at",600);put("over",600.1);put("day",86400)
        #expect(e.watchInbox.appBuild(for:"under")?.build==49)
        #expect(e.watchInbox.appBuild(for:"at")?.build==49)
        #expect(e.watchInbox.appBuild(for:"over")==nil && e.watchInbox.appBuild(for:"day")==nil)
        put("day",0,57);#expect(e.watchInbox.appBuild(for:"day")?.build==57)
        put("day",1,49);#expect(e.watchInbox.appBuild(for:"day")?.build==49)
    }
    @Test func upgradeFromOldUnscopedFileOrGarbageDoesNotTrap() throws {
        let (e,root,s)=fixture();let dir=root.appendingPathComponent("watch")
        let n=Date();report(e,"A",nil,n)
        let old=Data(#"{"build":49,"at":1791000000000}"#.utf8)
        try old.write(to:dir.appendingPathComponent("app-build.json"))
        #expect(e.watchInbox.appBuild==nil,"unscoped old evidence cannot be assigned to A")
        for bad in [Data("broken".utf8),old,Data("{}".utf8)] {
            try bad.write(to:dir.appendingPathComponent("app-builds.json"))
            let fresh=PhoneWatchInbox(root:dir,currentBinding:{s.phoneInstallId})
            #expect(fresh.appBuild==nil)
            fresh.saveAppBuild(WatchAppBuild(build:57,at:n,deviceId:"A",source:.report,receivedAt:n))
            #expect(fresh.appBuild?.build==57)
        }
        #expect(try Data(contentsOf:dir.appendingPathComponent("app-build.json"))==old)
    }
    @Test func missingDeviceIdRemainsUnknownEvenWithBuildAndTelemetry() throws {
        let (e,root,s)=fixture();let n=Date()
        try AstraWatchBuildChecks().perf(e,root,s,device:"A",build:49,at:n.addingTimeInterval(-5))
        report(e,nil,49,n)
        #expect(e.watchInbox.latestReport?.deviceId==nil)
        #expect(e.snapshotNow().watchAppBuild==nil)
        #expect(WatchAppBuild.outdatedLine(watch:e.snapshotNow().watchAppBuild?.build,phone:57)==nil)
        report(e,"A",nil,n.addingTimeInterval(1))
        #expect(e.snapshotNow().watchAppBuild?.build==49)
    }
    @Test func perWatchMapIsBoundedAndReloadable() throws {
        let (e,root,s)=fixture();let n=Date()
        for i in 0..<12 {
            e.watchInbox.saveAppBuild(WatchAppBuild(build:40+i,at:n.addingTimeInterval(Double(i)),deviceId:"watch-\(i)",source:.telemetry,receivedAt:n.addingTimeInterval(Double(i))))
        }
        let data=try Data(contentsOf:root.appendingPathComponent("watch/app-builds.json"))
        let all=try #require(WatchWire.decode([String:WatchAppBuild].self,data))
        #expect(all.count==8 && all["watch-0"]==nil && all["watch-11"]?.build==51)
        let reloaded=PhoneWatchInbox(root:root.appendingPathComponent("watch"),currentBinding:{s.phoneInstallId})
        #expect(reloaded.appBuild(for:"watch-11")?.build==51)
    }
    @Test func aFutureReportCannotPinThePreviousWatchAsCurrent() throws {
        let (e,_,_)=fixture();let n=Date()
        report(e,"A",49,n.addingTimeInterval(-60))
        report(e,"A",49,n.addingTimeInterval(86400))
        report(e,"B",57,n)
        #expect(e.watchInbox.appBuild(for:"B")?.build==57,"B's evidence was correctly learned")
        #expect(e.snapshotNow().watchAppBuild?.deviceId=="B","report selector must not keep selecting A after the new Watch reports")
        #expect(e.snapshotNow().watchAppBuild?.build==57)
    }
    @Test func anOlderUnidentifiedReportDoesNotEraseNewerEvidence() throws {
        let (e,_,_)=fixture();let n=Date()
        report(e,"A",49,n.addingTimeInterval(60))
        report(e,nil,nil,n)
        #expect(e.snapshotNow().watchAppBuild?.deviceId=="A","without a switch event, an older unidentified message is not proof of a different Watch")
    }
}
