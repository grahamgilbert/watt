import XCTest
@testable import Watt

final class PopupDetailTests:XCTestCase {
    private let time=Date(timeIntervalSince1970:1_800_000_000)
    private func process(_ pid:Int32=42,cpu:Double?=25,memory:UInt64?=1_000,growth:Int64?=10,read:UInt64?=200,written:UInt64?=100)->ProcessRow {
        ProcessRow(pid:pid,parent:1,start:1_799_999_000_000_000,name:"worker-\(pid)",cpu:cpu,memory:memory,growth:growth,read:read,written:written,userID:501,metricSource:"local")
    }
    private func frame(at offset:Double=0,cpu:Double=37,processes:[ProcessRow]?=nil)->Frame {
        Frame(time:time.addingTimeInterval(offset),cpu:cpu,memory:2_000,compressed:200,swap:0,download:999,upload:100,processes:processes ?? [process()],denied:0,segment:"one",elapsed:5,cadence:5)
    }
    private func sample(id:String="capture",at offset:Double=0,received:UInt64?=2_000,sent:UInt64?=200,elapsed:Double=2)->ProcessNetworkSample {
        ProcessNetworkSample(id:id,startedAt:time.addingTimeInterval(offset-elapsed),endedAt:time.addingTimeInterval(offset),elapsed:elapsed,
                             tasks:[ProcessNetworkTask(pid:42,parent:1,start:1_799_999_000_000_000,name:"worker-42",applicationID:nil,applicationName:nil,userID:501,receivedBytes:received,sentBytes:sent)],
                             status:.available,source:"nettop-external-tcp-udp",unmatchedProcesses:0,error:nil)
    }
    private func data(_ frames:[Frame],item:PopupItemID = .cpu,time:Date?=nil,mode:String="CPU",scope:String="Processes",selection:String?=nil,gaps:[RecordingGap]=[])->PopupDetailData {
        PopupDetailData.make(frame:frames.last,frames:frames,gaps:gaps,item:item,selectedTime:time,duration:60,mode:mode,scope:scope,selectedRowID:selection,physicalMemory:4_000)
    }
    func testEveryOptionalTileUsesItsSharedDetailDestination() throws {
        let expected:[PopupDetailDestination:[PopupItemID]]=[.cpu:[.cpu,.cpuProcesses],.memory:[.memory,.memoryDetail],.network:[.download,.upload],.disk:[.diskRead,.diskWrite],.energy:[.processCPUPower,.applicationCPUPower,.energyImpact],.battery:[.batteryFlow]]
        for (destination,items) in expected {for item in items {XCTAssertEqual(PopupDetailDestination(item:item),destination)}}
        for (raw,destination) in [("network",PopupDetailDestination.network),("diskActivity",.disk),("energy",.energy)] {
            XCTAssertEqual(PopupDetailDestination(item:try XCTUnwrap(PopupItemID(rawValue:raw))),destination)
        }
    }
    func testPinnedReadoutAndRowsUseHistoricalSampleInsteadOfLatest() {
        let old=frame(at:-5,cpu:12,processes:[process(42,cpu:8)]),latest=frame(cpu:90,processes:[process(43,cpu:200)])
        let value=data([old,latest],time:old.time)
        XCTAssertEqual(value.sampleTime,old.time)
        XCTAssertEqual(value.readouts.first?.value,"12")
        XCTAssertEqual(value.rows.first?.process?.pid,42)
    }
    func testCursorInGapKeepsGraphButNeverUsesLatestProcessRows() {
        let old=frame(at:-10),latest=frame()
        let gap=RecordingGap(id:"gap",start:time.addingTimeInterval(-8),end:time.addingTimeInterval(-3),reason:"Device asleep")
        let value=data([old,latest],time:time.addingTimeInterval(-5),gaps:[gap])
        XCTAssertNil(value.sampleTime)
        XCTAssertTrue(value.rows.isEmpty)
        XCTAssertTrue(value.readouts.isEmpty)
        XCTAssertEqual(value.emptyDetail,"Device asleep")
        XCTAssertFalse(value.points.isEmpty)
    }
    func testMissingDiskCounterIsDifferentFromMeasuredZero() {
        let current=frame(processes:[process(42,read:nil,written:0)])
        let reads=data([current],item:.diskRead,mode:"Reads"),writes=data([current],item:.diskWrite,mode:"Writes")
        XCTAssertNil(reads.rows.first?.primary)
        XCTAssertEqual(reads.rows.first?.primaryText,"—")
        XCTAssertEqual(reads.rows.first?.secondaryText,"0 B/s")
        XCTAssertEqual(writes.rows.first?.primary,0)
    }
    func testDetailRatesUseSameDecimalUnitsAsTiles() {
        for value in [0.0,999,1_000,48_600_000,1_000_000_000] {
            let tile=popupRateValue(value),detail=PopupDetailData.rateComponents(value)
            XCTAssertEqual(detail.0,tile.value)
            XCTAssertEqual(detail.1,tile.unit)
        }
        XCTAssertEqual(PopupDetailData.fullRate(1_000),"1.0 KB/s")
        XCTAssertEqual(PopupDetailData.fullRate(48_600_000),"48.6 MB/s")
    }
    func testBatteryHistoryKeepsSignedFlowAndSeparatesPowerSourceChanges() {
        var charging=frame(at:-5),discharging=frame()
        charging.power=PowerReading(volts:12,amps:1,externalPower:true,sampledAt:charging.time)
        discharging.power=PowerReading(volts:12,amps:-1,externalPower:false,sampledAt:discharging.time)
        let value=data([charging,discharging],item:.batteryFlow)
        XCTAssertEqual(value.points.map(\.value),[12,-12])
        XCTAssertNotEqual(value.points[0].segment,value.points[1].segment)
        XCTAssertTrue(value.signedChart)
    }
    func testKnownNegativeGrowthSortsBeforeUnavailableGrowth() {
        let old=frame(at:-5,processes:[process(42,memory:1_000),process(43,memory:nil),process(44,memory:1_000)])
        let current=frame(processes:[process(42,memory:900,growth:555),process(43,memory:nil),process(44,memory:1_000,growth:999)])
        let value=data([old,current],item:.memory,mode:"Growth")
        XCTAssertEqual(value.rows.map(\.process?.pid),[44,42,43])
        XCTAssertEqual(value.rows.map(\.primary),[0,-100,nil])
    }
    func testMemoryRangeGrowthDoesNotBridgeGapSourceChangeOrUnavailableEndpoint() {
        let old=frame(at:-10,processes:[process(memory:1_000)]),current=frame(processes:[process(memory:2_000)])
        let gap=RecordingGap(id:"gap",start:time.addingTimeInterval(-8),end:time.addingTimeInterval(-2),reason:"Device asleep")
        XCTAssertNil(data([old,current],item:.memory,mode:"Growth",gaps:[gap]).rows.first?.primary)
        var switched=current;switched.processes[0].metricSource="privileged"
        XCTAssertNil(data([old,switched],item:.memory,mode:"Growth").rows.first?.primary)
        var unavailable=old;unavailable.processes[0].memory=nil
        XCTAssertNil(data([unavailable,current],item:.memory,mode:"Growth").rows.first?.primary)
        var middle=frame(at:-5);middle.processes[0].memory=nil
        XCTAssertNil(data([old,middle,current],item:.memory,mode:"Growth").rows.first?.primary)
    }
    func testMemoryRangeGrowthStopsAtPinnedCursorAndMatchesLifetime() {
        let first=frame(at:-10,processes:[process(memory:1_000)]),middle=frame(at:-5,processes:[process(memory:1_400)]),latest=frame(processes:[process(memory:9_000)])
        let value=data([first,middle,latest],item:.memory,time:middle.time,mode:"Growth")
        XCTAssertEqual(value.rows.first?.primary,400)
        var reused=latest;reused.processes[0].start+=1
        XCTAssertNil(data([first,reused],item:.memory,mode:"Growth").rows.first?.primary)
    }
    func testProcessCPUChartUsesSeparateOneCoreScale() {
        let p=process(cpu:218),current=frame(processes:[p])
        let value=data([current],selection:p.id)
        XCTAssertEqual(value.readouts.first?.value,"37")
        XCTAssertEqual(value.points.first?.value,218)
        XCTAssertNil(value.chartCeiling)
        XCTAssertTrue(value.chartTitle.contains("one logical CPU"))
    }
    func testSelectedProcessOutsideTopSixRemainsVisibleByLifetime() {
        let processes=(1...9).map {process(Int32($0),cpu:Double($0))}
        let chosen=processes[0]
        let value=data([frame(processes:processes)],selection:chosen.id)
        XCTAssertEqual(value.rows.count,6)
        XCTAssertTrue(value.rows.contains {$0.id==chosen.id})
        XCTAssertEqual(value.selection?.row.id,chosen.id)
    }
    func testLegacyNetworkHistoryShowsNotRecordedInsteadOfZeroProcessRates() {
        let value=data([frame()],item:.download,mode:"Download")
        XCTAssertEqual(value.emptyTitle,"Process traffic not recorded")
        XCTAssertTrue(value.rows.isEmpty)
        XCTAssertEqual(value.readouts.first?.value,"999")
        XCTAssertEqual(value.points.filter {$0.series=="Download"}.first?.value,999)
    }
    func testNetworkRatesUseCaptureIntervalAndKeepExitedIdentity() {
        var current=frame(processes:[])
        current.elapsed=20
        current.processNetwork=sample()
        let value=data([current],item:.download,mode:"Download")
        XCTAssertEqual(value.rows.first?.primary,1_000)
        XCTAssertEqual(value.rows.first?.process?.pid,42)
        XCTAssertNil(value.rows.first?.process?.cpu)
        XCTAssertEqual(value.readouts.first?.value,"999")
        XCTAssertTrue(value.coverage.contains("2.00s interval"))
    }
    func testNetworkRangeTotalsDeduplicateCachedCaptures() throws {
        var first=frame(at:-5),duplicate=frame(at:-4),last=frame()
        first.processNetwork=sample(id:"first",at:-5,received:2_000,elapsed:5)
        duplicate.processNetwork=first.processNetwork
        last.processNetwork=sample(id:"last",received:3_000,elapsed:5)
        let selected=process().id
        let value=data([first,duplicate,last],item:.download,mode:"Download",selection:selected)
        let facts=try XCTUnwrap(value.selection).facts
        XCTAssertEqual(facts.first {$0.title=="Received in range"}?.value,bytes(5_000))
        XCTAssertEqual(facts.first {$0.title=="Average receive / send"}?.value,"500 B/s / 40 B/s")
        XCTAssertEqual(facts.first {$0.title=="Peak receive / send"}?.value,"600 B/s / 40 B/s")
        XCTAssertEqual(value.points.filter {$0.series=="Download"}.count,2)
        XCTAssertEqual(Set(value.points.filter {$0.series=="Download"}.map(\.time)),[first.processNetwork!.endedAt,last.processNetwork!.endedAt])
    }
    func testFutureAndStaleNetworkSamplesAreUnavailable() {
        for offset in [-20.0,1.0] {
            var current=frame();current.processNetwork=sample(at:offset)
            let value=data([current],item:.download,mode:"Download")
            XCTAssertTrue(value.rows.isEmpty)
            XCTAssertEqual(value.emptyTitle,offset<0 ? "Process traffic sample is stale" : "Process traffic unavailable")
        }
    }
    func testNetworkApplicationGroupingUsesRecordedOwnership() {
        var current=frame(),capture=sample()
        capture.tasks[0].applicationID="org.example.app";capture.tasks[0].applicationName="Example"
        current.processes[0].applicationID="org.example.app";current.processes[0].applicationName="Example"
        var child=capture.tasks[0];child.pid=43;child.parent=42;child.applicationID=nil;child.applicationName=nil;child.receivedBytes=1_000;child.sentBytes=nil
        capture.tasks.append(child);current.processNetwork=capture
        let value=data([current],item:.download,mode:"Download",scope:"Applications")
        XCTAssertEqual(value.rows.count,1)
        XCTAssertEqual(value.rows.first?.id,"app:org.example.app")
        XCTAssertEqual(value.rows.first?.name,"Example")
        XCTAssertEqual(value.rows.first?.primary,1_500)
        XCTAssertEqual(value.rows.first?.children.count,2)
        XCTAssertEqual(value.rows.first?.partial,true)
    }
    func testNetworkRangeFactsMatchExplorerWhenUniqueCaptureIntervalsOverlap() throws {
        var first=frame(at:-6),overlap=frame(at:-4),last=frame(at:-2)
        first.processNetwork=sample(id:"first",at:-6,received:400,sent:nil,elapsed:4)
        overlap.processNetwork=sample(id:"overlap",at:-4,received:800,sent:200,elapsed:4)
        last.processNetwork=sample(id:"last",at:-2,received:200,sent:nil,elapsed:2)
        let frames=[first,overlap,last]
        let value=data(frames,item:.download,mode:"Download",selection:process().id)
        let facts=try XCTUnwrap(value.selection).facts
        let range=DateInterval(start:last.time.addingTimeInterval(-60),end:last.time)
        let totals=try XCTUnwrap(HistoryAnalysis.summarize(frames,range:range,gaps:[]).first {$0.id==process().id}).network
        XCTAssertEqual(totals.receivedBytes,600)
        XCTAssertEqual(totals.sentBytes,200)
        XCTAssertEqual(facts.first {$0.title=="Received in range"}?.value,totals.receivedBytes.map(bytes))
        XCTAssertEqual(facts.first {$0.title=="Sent in range"}?.value,totals.sentBytes.map(bytes))
        XCTAssertEqual(facts.first {$0.title=="Average receive / send"}?.value,"100 B/s / 50 B/s")
        XCTAssertEqual(facts.first {$0.title=="Peak receive / send"}?.value,"100 B/s / 50 B/s")
    }
    func testOverflowedNetworkRangeTotalIsUnavailableRatherThanSaturated() throws {
        var first=frame(at:-5),last=frame()
        first.processNetwork=sample(id:"first",at:-5,received:UInt64.max,elapsed:5)
        last.processNetwork=sample(id:"last",received:1,elapsed:5)
        let value=data([first,last],item:.download,mode:"Download",selection:process().id)
        let facts=try XCTUnwrap(value.selection).facts
        XCTAssertEqual(facts.first {$0.title=="Received in range"}?.value,"—")
        XCTAssertTrue(try XCTUnwrap(facts.first {$0.title=="Average receive / send"}?.value).hasPrefix("— / "))
    }
    func testPopupAndExplorerUseNonNetworkingParentForApplicationOwnership() throws {
        for reusedParent in [false,true] {
            var current=frame(),capture=sample()
            capture.tasks[0].parent=10
            var parent=process(10)
            parent.applicationID="org.example.xcode";parent.applicationName="Example Xcode"
            parent.start=capture.tasks[0].start+(reusedParent ? 1 : 0)
            current.processes=[parent];current.processNetwork=capture
            let value=data([current],item:.download,mode:"Download",scope:"Applications")
            let row=try XCTUnwrap(value.rows.first)
            let range=DateInterval(start:capture.startedAt,end:capture.endedAt)
            let explorer=try XCTUnwrap(HistoryAnalysis.networkGroups([current],range:range,gaps:[]).first)
            XCTAssertEqual(row.id,explorer.id)
            XCTAssertEqual(row.name,explorer.name)
            XCTAssertEqual(row.primary,explorer.totals.averageDownloadRate)
            XCTAssertEqual(row.id,reusedParent ? "process:"+capture.tasks[0].id : "app:org.example.xcode")
            XCTAssertEqual(row.children.first?.process?.pid,42)
        }
    }
    func testMemoryGrowthHandoffClipsSummaryToDisplayedCursor() throws {
        let first=frame(at:-60,processes:[process(memory:1_000)]),middle=frame(at:-20,processes:[process(memory:1_400)]),latest=frame(processes:[process(memory:9_000)])
        let frames=[first,middle,latest]
        let value=data(frames,item:.memory,time:middle.time,mode:"Growth",selection:process().id)
        let graphRange=DateInterval(start:first.time,end:latest.time)
        let context=PopupExplorerContext.detail(item:.memory,duration:60,selectedTime:middle.time.addingTimeInterval(0.2),sampleTime:value.sampleTime,
                                               graphRange:graphRange,selection:value.selection?.row,scope:"Processes",mode:"Growth")
        XCTAssertEqual(context.range?.start,first.time)
        XCTAssertEqual(context.range?.end,middle.time)
        XCTAssertEqual(context.duration,40)
        XCTAssertEqual(context.selectedTime,middle.time)
        XCTAssertTrue(context.intervalSummary)
        XCTAssertEqual(context.sort,"Memory growth")
        let summary=try XCTUnwrap(HistoryAnalysis.summarize(frames,range:try XCTUnwrap(context.range),gaps:[]).first {$0.id==process().id})
        XCTAssertEqual(summary.memoryChange,400)
        XCTAssertEqual(value.rows.first?.primary,400)
    }
    func testInspectingApplicationChildKeepsDisplayedLifetimeAndProcessScope() {
        let p=process(),row=PopupDetailRow(id:p.id,name:p.name,process:p,primary:25,primaryText:"25",secondaryText:"1 KB")
        let context=PopupExplorerContext.detail(item:.cpu,duration:60,selectedTime:nil,sampleTime:time,graphRange:nil,selection:row,scope:"Applications",mode:"CPU")
        XCTAssertEqual(context.selectedTime,time)
        XCTAssertEqual(context.processID,p.id)
        XCTAssertEqual(context.scope,"Processes")
        XCTAssertFalse(context.intervalSummary)
    }
    @MainActor func testPinningKeepsPendingLoadForTheSameAnchoredWindow() throws {
        let history=PopupLayoutPreview.frames
        let latest=try XCTUnwrap(history.last)
        let session=PopupDetailSession()
        var completions:[(Result<PopupHistorySnapshot,Error>)->Void]=[]
        session.open(.memory,liveFrames:[latest],gaps:[]) {_,_,done in completions.append(done)}
        session.changeDuration(300,liveFrames:[latest],gaps:[])
        XCTAssertEqual(completions.count,2)
        session.select(latest.time,liveFrames:[latest],gaps:[])
        completions[1](.success(PopupHistorySnapshot(frames:history,gaps:[])))
        XCTAssertEqual(session.selectedTime,latest.time)
        XCTAssertEqual(session.duration,300)
        XCTAssertEqual(session.frames.last?.time,latest.time)
        XCTAssertGreaterThan(session.frames.count,1,"Pinning must not permanently discard the requested earlier history")
        XCTAssertFalse(session.isLoading)
    }
}
