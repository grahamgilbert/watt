import XCTest
import CTelemetry
@testable import Watt

final class AppPowerGroupingTests:XCTestCase {
    private let base=Date(timeIntervalSince1970:1_800_000_000)
    private func row(_ pid:Int32,parent:Int32=1,start:UInt64=1,name:String="tool",app:String?=nil,energy:UInt64?=nil,cpu:Double?=nil)->ProcessRow {
        ProcessRow(pid:pid,parent:parent,start:start,name:name,cpu:cpu,memory:100,growth:nil,read:nil,written:nil,energyNanojoules:energy,applicationID:app,applicationName:app==nil ? nil : "Chrome")
    }
    private func frame(_ second:Double=5,rows:[ProcessRow],denied:Int=0)->Frame {
        Frame(time:base.addingTimeInterval(second),cpu:10,memory:1000,compressed:0,swap:0,download:0,upload:0,processes:rows,denied:denied,elapsed:5)
    }
    func testMachTicksUseActualTimebaseAndDoNotOverflow() {
        XCTAssertEqual(watt_cpu_time_nanoseconds(24_000_000,125,3),1_000_000_000)
        XCTAssertEqual(watt_cpu_time_nanoseconds(1_000_000_000,1,1),1_000_000_000)
        XCTAssertEqual(watt_cpu_time_nanoseconds(UInt64.max,125,3),UInt64.max)
        XCTAssertEqual(watt_cpu_time_nanoseconds(100,125,0),0)
    }
    func testMainAppAndNestedHelperResolveToTheOutermostValidBundle() {
        var inspected:[String]=[]
        let result=ProcessApplicationResolver.outermostApplication(in:"/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper") {url in
            inspected.append(url.path)
            return ProcessApplicationIdentity(id:"com.google.Chrome",name:"Google Chrome")
        }
        XCTAssertEqual(result?.id,"com.google.Chrome")
        XCTAssertEqual(inspected,["/Applications/Google Chrome.app"])
        XCTAssertNil(ProcessApplicationResolver.outermostApplication(in:"/usr/bin/make") {_ in XCTFail("No app bundle should be read");return nil})
    }
    func testAppTotalsCombineObservedHelpersAndShowPartialCoverage() throws {
        let rows=[row(10,app:"com.google.Chrome",energy:10_000_000_000,cpu:50),row(11,app:"com.google.Chrome",energy:5_000_000_000,cpu:25),row(12,app:"com.google.Chrome")]
        let group=try XCTUnwrap(AppPowerGrouping.snapshot(frame(rows:rows,denied:3)).first)
        XCTAssertEqual(group.name,"Chrome");XCTAssertEqual(group.observedProcesses,3)
        XCTAssertEqual(group.cpuPowerWatts,3);XCTAssertEqual(group.cpu,75)
        XCTAssertEqual(group.measuredEnergyProcesses,2);XCTAssertTrue(group.isPartial)
        XCTAssertTrue(group.hasUnattributedProcesses)
    }
    func testMissingPowerStaysUnavailableAndSupportedZeroPowerStaysZero() throws {
        let missing=try XCTUnwrap(AppPowerGrouping.snapshot(frame(rows:[row(10,app:"com.google.Chrome")])).first)
        XCTAssertNil(missing.cpuPowerWatts);XCTAssertTrue(missing.isPartial)
        let zero=try XCTUnwrap(AppPowerGrouping.snapshot(frame(rows:[row(10,app:"com.google.Chrome",energy:0)])).first)
        XCTAssertEqual(zero.cpuPowerWatts,0);XCTAssertFalse(zero.isPartial)
    }
    func testOnlyObservedValidParentLinksGroupUnbundledTools() {
        let main=row(10,start:1,app:"com.google.Chrome",energy:1)
        let child=row(11,parent:10,start:2,energy:1)
        XCTAssertEqual(AppPowerGrouping.snapshot(frame(rows:[main,child])).count,1)
        let reusedParent=row(10,start:3,app:"com.google.Chrome",energy:1)
        XCTAssertEqual(AppPowerGrouping.snapshot(frame(rows:[reusedParent,child])).count,2)
        let sameNamed=[row(20,name:"helper",energy:1),row(21,name:"helper",energy:1)]
        XCTAssertEqual(AppPowerGrouping.snapshot(frame(rows:sameNamed)).count,2)
        let cycle=[row(30,parent:31,energy:1),row(31,parent:30,energy:1)]
        XCTAssertEqual(AppPowerGrouping.snapshot(frame(rows:cycle)).count,2)
    }
    func testHistoricalAppPowerUsesWallCoverageOncePerAppInsteadOfPerHelper() throws {
        let first=frame(5,rows:[row(10,app:"com.google.Chrome",energy:10_000_000_000),row(11,app:"com.google.Chrome",energy:5_000_000_000)])
        let second=frame(10,rows:[row(10,app:"com.google.Chrome",energy:5_000_000_000)])
        let summary=try XCTUnwrap(AppPowerGrouping.summarize([first,second],range:DateInterval(start:base,duration:10),gaps:[]).first)
        XCTAssertEqual(summary.energyJoules,20);XCTAssertEqual(summary.energyCoveredSeconds,10)
        XCTAssertEqual(summary.averagePower,2);XCTAssertEqual(summary.peakPower,3)
        XCTAssertEqual(summary.observedProcesses,2)
    }
    func testHistoricalAppTotalsExcludeGapsAndPartialBoundaryIntervals() throws {
        let frames=[frame(5,rows:[row(10,app:"com.google.Chrome",energy:1_000_000_000)]),frame(10,rows:[row(10,app:"com.google.Chrome",energy:2_000_000_000)]),frame(15,rows:[row(10,app:"com.google.Chrome",energy:3_000_000_000)])]
        let gap=RecordingGap(id:"gap",start:base.addingTimeInterval(6),end:base.addingTimeInterval(9),reason:"Pause")
        let summary=try XCTUnwrap(AppPowerGrouping.summarize(frames,range:DateInterval(start:base.addingTimeInterval(2),end:base.addingTimeInterval(15)),gaps:[gap]).first)
        XCTAssertEqual(summary.energyJoules,3);XCTAssertEqual(summary.energyCoveredSeconds,5)
    }
    func testAppIdentityPersistsWithoutSavingExecutablePaths() throws {
        let process=row(10,app:"com.google.Chrome",energy:5)
        let data=try JSONEncoder().encode(process)
        let decoded=try JSONDecoder().decode(ProcessRow.self,from:data)
        XCTAssertEqual(decoded.applicationID,"com.google.Chrome");XCTAssertEqual(decoded.applicationName,"Chrome")
        let json=String(decoding:data,as:UTF8.self)
        XCTAssertFalse(json.contains("/Applications"))
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        legacy.removeValue(forKey:"applicationID");legacy.removeValue(forKey:"applicationName")
        let old=try JSONDecoder().decode(ProcessRow.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(old.applicationID);XCTAssertNil(old.applicationName)
    }
}
