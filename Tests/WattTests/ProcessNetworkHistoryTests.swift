import XCTest
@testable import Watt

final class ProcessNetworkHistoryTests:XCTestCase {
    private let origin=Date(timeIntervalSince1970:1_800_000_000)
    private var range:DateInterval {DateInterval(start:origin,duration:20)}

    func testCaptureTotalsAreDeduplicatedAndUseTheirOwnIntervals() throws {
        let first=capture("session:1",start:0,end:2,tasks:[task(received:1_000,sent:400)])
        let second=capture("session:2",start:2,end:6,tasks:[task(received:3_000,sent:800)])
        let summary=try XCTUnwrap(HistoryAnalysis.summarize([frame(2,sample:first),frame(3,sample:first),frame(7,sample:second)],range:range,gaps:[]).first)
        XCTAssertEqual(summary.network.receivedBytes,4_000)
        XCTAssertEqual(summary.network.sentBytes,1_200)
        XCTAssertEqual(summary.network.receiveCoveredSeconds,6)
        XCTAssertEqual(summary.network.sendCoveredSeconds,6)
        XCTAssertEqual(try XCTUnwrap(summary.network.averageDownloadRate),4_000/6,accuracy:0.001)
        XCTAssertEqual(summary.network.averageUploadRate,200)
        XCTAssertEqual(summary.network.peakDownloadRate,750)
        XCTAssertEqual(summary.network.peakUploadRate,200)
        XCTAssertEqual(summary.network.captures,2)
    }

    func testMeasuredZeroAndUnavailableDirectionsStayDistinct() throws {
        let sample=capture("session:1",start:0,end:2,tasks:[task(received:nil,sent:0)])
        let summary=try XCTUnwrap(HistoryAnalysis.summarize([frame(3,sample:sample)],range:range,gaps:[]).first)
        XCTAssertNil(summary.network.receivedBytes)
        XCTAssertNil(summary.network.averageDownloadRate)
        XCTAssertNil(summary.network.peakDownloadRate)
        XCTAssertEqual(summary.network.receiveCoveredSeconds,0)
        XCTAssertEqual(summary.network.sentBytes,0)
        XCTAssertEqual(summary.network.averageUploadRate,0)
        XCTAssertEqual(summary.network.peakUploadRate,0)
        XCTAssertEqual(summary.network.sendCoveredSeconds,2)
    }

    func testPartialGapFutureAndStaleCapturesDoNotInventRangeTotals() throws {
        let partial=capture("partial",start:-1,end:1,tasks:[task(received:900,sent:900)])
        let valid=capture("valid",start:1,end:3,tasks:[task(received:100,sent:20)])
        let gapSample=capture("gap",start:3,end:5,tasks:[task(received:900,sent:900)])
        let outside=capture("outside",start:7,end:10,tasks:[task(received:900,sent:900)])
        let future=capture("future",start:5,end:7,tasks:[task(received:900,sent:900)])
        let stale=capture("stale",start:5,end:6,tasks:[task(received:900,sent:900)])
        let shortRange=DateInterval(start:origin,duration:8)
        let gap=RecordingGap(id:"gap",start:origin.addingTimeInterval(4),end:origin.addingTimeInterval(4.5),reason:"test gap")
        let frames=[frame(2,sample:partial),frame(4,sample:valid),frame(6,sample:gapSample),frame(10,sample:outside),frame(6,sample:future),frame(100,sample:stale)]
        let summary=try XCTUnwrap(HistoryAnalysis.summarize(frames,range:shortRange,gaps:[gap]).first)
        XCTAssertEqual(summary.network.receivedBytes,100)
        XCTAssertEqual(summary.network.sentBytes,20)
        XCTAssertEqual(summary.network.receiveCoveredSeconds,2)
        XCTAssertEqual(summary.network.captures,1)
    }

    func testOverlappingDifferentCapturesDoNotDoubleCountObservedTimeOrBytes() throws {
        let a=capture("a",start:0,end:4,tasks:[task(received:400,sent:nil)])
        let overlap=capture("b",start:2,end:6,tasks:[task(received:800,sent:nil)])
        let c=capture("c",start:4,end:8,tasks:[task(received:1_200,sent:nil)])
        let summary=try XCTUnwrap(HistoryAnalysis.summarize([frame(4,sample:a),frame(6,sample:overlap),frame(8,sample:c)],range:range,gaps:[]).first)
        XCTAssertEqual(summary.network.receivedBytes,1_600)
        XCTAssertEqual(summary.network.receiveCoveredSeconds,8)
        XCTAssertEqual(summary.network.captures,2)
        XCTAssertEqual(summary.network.peakDownloadRate,300)
    }

    func testExitedTasksRemainInspectableAndReusedPIDsKeepSeparateLifetimes() throws {
        let old=task(start:100,received:1_000,sent:100)
        let new=task(start:200,received:2_000,sent:200)
        let first=capture("a",start:0,end:2,tasks:[old])
        let second=capture("b",start:2,end:4,tasks:[new])
        let summaries=HistoryAnalysis.summarize([frame(2,sample:first),frame(4,sample:second)],range:range,gaps:[])
        XCTAssertEqual(Set(summaries.map(\.id)),Set([old.id,new.id]))
        XCTAssertEqual(summaries.first {$0.id==old.id}?.network.receivedBytes,1_000)
        XCTAssertEqual(summaries.first {$0.id==new.id}?.network.receivedBytes,2_000)
        XCTAssertTrue(summaries.allSatisfy {$0.process.memory == nil && $0.process.metricSource=="network"})
        let cache=ExplorerSnapshotCache()
        let snapshot=cache.data(frame:frame(3,sample:first))
        XCTAssertEqual(snapshot.processes.map(\.id),[old.id])
        XCTAssertEqual(snapshot.networkTasks[old.id]?.downloadRate(elapsed:try XCTUnwrap(snapshot.networkElapsed)),500)
        XCTAssertTrue(cache.data(frame:frame(100,sample:first)).networkTasks.isEmpty)
        XCTAssertTrue(cache.data(frame:nil).processes.isEmpty)
    }

    func testApplicationTotalsCountEachCaptureOnceInsteadOfOncePerHelper() throws {
        let a=task(pid:42,received:1_000,sent:200,app:"example.app")
        let b=task(pid:43,received:3_000,sent:600,app:"example.app")
        let first=capture("a",start:0,end:2,tasks:[a,b])
        let second=capture("b",start:2,end:4,tasks:[task(pid:42,received:2_000,sent:nil,app:"example.app"),task(pid:43,received:nil,sent:1_000,app:"example.app")],unmatched:1)
        let group=try XCTUnwrap(HistoryAnalysis.networkGroups([frame(2,sample:first),frame(3,sample:first),frame(4,sample:second)],range:range,gaps:[]).first)
        XCTAssertEqual(group.id,"app:example.app")
        XCTAssertEqual(group.members.count,2)
        XCTAssertEqual(group.totals.receivedBytes,6_000)
        XCTAssertEqual(group.totals.sentBytes,1_800)
        XCTAssertEqual(group.totals.receiveCoveredSeconds,4)
        XCTAssertEqual(group.totals.sendCoveredSeconds,4)
        XCTAssertEqual(group.totals.averageDownloadRate,1_500)
        XCTAssertEqual(group.totals.averageUploadRate,450)
        XCTAssertEqual(group.totals.peakDownloadRate,2_000)
        XCTAssertTrue(group.isPartial)
        XCTAssertTrue(group.hasUnattributedProcesses)
    }

    func testObservedParentAppOwnershipMatchesPopupAndRejectsFutureReusedParent() throws {
        let child=task(start:200,received:1_000,sent:100)
        var parent=ProcessRow(pid:10,parent:1,start:100,name:"Example",cpu:0,memory:0,growth:nil,read:nil,written:nil,applicationID:"example.app",applicationName:"Example")
        let sample=capture("a",start:0,end:2,tasks:[child])
        var f=frame(2,sample:sample);f.processes=[parent]
        let group=try XCTUnwrap(HistoryAnalysis.networkGroups([f],range:range,gaps:[]).first)
        XCTAssertEqual(group.id,"app:example.app")
        XCTAssertEqual(group.members[child.id]?.applicationID,"example.app")
        XCTAssertEqual(ExplorerSnapshotCache().data(frame:f).networkGroupIDs[child.id],group.id)
        parent.start=300;f.processes=[parent]
        XCTAssertEqual(HistoryAnalysis.networkGroups([f],range:range,gaps:[]).first?.id,"process:"+child.id)
    }

    func testByteOverflowBecomesUnavailableWithoutTrappingOrWrapping() throws {
        let a=capture("a",start:0,end:2,tasks:[task(received:.max,sent:nil)])
        let b=capture("b",start:2,end:4,tasks:[task(received:1,sent:nil)])
        let summary=try XCTUnwrap(HistoryAnalysis.summarize([frame(2,sample:a),frame(4,sample:b)],range:range,gaps:[]).first)
        XCTAssertNil(summary.network.receivedBytes)
        XCTAssertNil(summary.network.averageDownloadRate)
        XCTAssertEqual(summary.network.receiveCoveredSeconds,4)
    }

    func testLegacySamplesDoNotClaimMeasuredZeroNetworkTraffic() throws {
        let process=ProcessRow(pid:42,parent:1,start:100,name:"worker",cpu:0,memory:1,growth:0,read:0,written:0)
        var f=frame(2,sample:nil);f.processes=[process]
        let summary=try XCTUnwrap(HistoryAnalysis.summarize([f],range:range,gaps:[]).first)
        XCTAssertNil(summary.network.receivedBytes)
        XCTAssertNil(summary.network.sentBytes)
        XCTAssertEqual(summary.network.captures,0)
    }

    func testProcessTracesUseCaptureTimesAndDoNotRepeatCachedSamples() throws {
        let task=task(received:1_000,sent:400)
        let sample=capture("session:1",start:0,end:2,tasks:[task])
        let frames=[frame(2,sample:sample),frame(3,sample:sample)]
        let trace=ExplorerTraceCache().data(frames:frames,gaps:[],processID:task.id,metric:"Network")
        XCTAssertEqual(trace.points.count,2)
        XCTAssertEqual(Set(trace.points.map(\.time)),[sample.endedAt])
        XCTAssertEqual(try XCTUnwrap(trace.points.first {$0.channel=="read"}).value,0.0005,accuracy:0.0000001)
        XCTAssertEqual(try XCTUnwrap(trace.points.first {$0.channel=="write"}).value,0.0002,accuracy:0.0000001)
    }

    private func task(pid:Int32=42,start:UInt64=100,received:UInt64?,sent:UInt64?,app:String?=nil)->ProcessNetworkTask {
        ProcessNetworkTask(pid:pid,parent:10,start:start,name:"worker-\(pid)",applicationID:app,applicationName:app.map {_ in "Example"},userID:501,receivedBytes:received,sentBytes:sent)
    }
    private func capture(_ id:String,start:Double,end:Double,tasks:[ProcessNetworkTask],unmatched:Int=0)->ProcessNetworkSample {
        ProcessNetworkSample(id:id,startedAt:origin.addingTimeInterval(start),endedAt:origin.addingTimeInterval(end),elapsed:end-start,tasks:tasks,status:.available,source:"test-network",unmatchedProcesses:unmatched,error:nil)
    }
    private func frame(_ time:Double,sample:ProcessNetworkSample?)->Frame {
        Frame(time:origin.addingTimeInterval(time),cpu:0,memory:0,compressed:0,swap:0,download:0,upload:0,processes:[],denied:0,elapsed:99,processNetwork:sample)
    }
}
