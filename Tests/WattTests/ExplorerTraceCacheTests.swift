import XCTest
@testable import Watt

final class ExplorerTraceCacheTests:XCTestCase {
    private let origin=Date(timeIntervalSince1970:1_800_000_000)
    private func frame(_ offset:Double,corrected:Bool=true,hasProcess:Bool=true)->Frame {
        let process=ProcessRow(pid:42,parent:1,start:1,name:"build",cpu:125,memory:2*1048576,growth:nil,read:4*1048576,written:2*1048576,energyNanojoules:1_000_000_000)
        return Frame(time:origin.addingTimeInterval(offset),cpu:25,memory:10*1048576,compressed:0,swap:0,download:0,upload:0,processes:hasProcess ? [process] : [],denied:0,elapsed:2,processCPUAccounting:corrected ? "mach-timebase-to-nanoseconds" : nil)
    }
    func testCursorAndMetricQueriesReuseOneProjectionUntilNewSnapshotsArrive() {
        let cache=ExplorerTraceCache(),frames=[frame(2),frame(4)]
        for _ in 0..<30 {
            for metric in ["CPU","Memory","Disk"] {_=cache.data(frames:frames,gaps:[],processID:nil,metric:metric)}
            for metric in ["CPU","Memory","Energy","Disk"] {_=cache.data(frames:frames,gaps:[],processID:"42:1",metric:metric)}
        }
        XCTAssertEqual(cache.preparationCount,2,"System and selected process prepare once, independently of the cursor and metric")
        let appended=frames+[frame(6)]
        XCTAssertEqual(cache.data(frames:appended,gaps:[],processID:nil,metric:"CPU").points.count,3)
        XCTAssertEqual(cache.preparationCount,3)
        _=cache.data(frames:appended,gaps:[],processID:"43:1",metric:"CPU")
        XCTAssertEqual(cache.preparationCount,4)
    }
    func testSharedProjectionPreservesUnitsMissingValuesAndCorrectedCPU() throws {
        let cache=ExplorerTraceCache(),frames=[frame(2,corrected:false),frame(4),frame(6,hasProcess:false)]
        let cpu=cache.data(frames:frames,gaps:[],processID:"42:1",metric:"CPU")
        XCTAssertEqual(cpu.points.map(\.value),[125])
        XCTAssertEqual(cpu.points.first?.time,origin.addingTimeInterval(4))
        XCTAssertEqual(cache.data(frames:frames,gaps:[],processID:"42:1",metric:"Memory").points.map(\.value),[2,2])
        XCTAssertEqual(cache.data(frames:frames,gaps:[],processID:"42:1",metric:"Energy").points.map(\.value),[0.5,0.5])
        XCTAssertEqual(cache.data(frames:frames,gaps:[],processID:nil,metric:"Disk").points.filter {$0.channel=="read"}.map(\.value),[2,2])
        XCTAssertEqual(cache.data(frames:frames,gaps:[],processID:nil,metric:"CPU").domain,0...100)
    }
    func testGapChangesInvalidateAndBreakSeriesWithoutFillingMissingSamples() {
        let cache=ExplorerTraceCache(),frames=[frame(2),frame(4),frame(6)]
        let original=cache.data(frames:frames,gaps:[],processID:nil,metric:"CPU")
        XCTAssertEqual(Set(original.points.map(\.series)).count,1)
        let gap=RecordingGap(id:"sleep",start:origin.addingTimeInterval(2.5),end:origin.addingTimeInterval(3),reason:"Sleep")
        let changed=cache.data(frames:frames,gaps:[gap],processID:nil,metric:"CPU")
        XCTAssertEqual(changed.points.map(\.time),[origin.addingTimeInterval(2),origin.addingTimeInterval(6)])
        XCTAssertEqual(Set(changed.points.map(\.series)).count,2)
        XCTAssertEqual(cache.preparationCount,2)
    }
    func testSnapshotParentIndexBoundsCyclesAndDoesNotBuildDepthsWhenDisabled() {
        var snapshot=frame(2)
        snapshot.processes=[ProcessRow(pid:1,parent:2,start:1,name:"one",cpu:nil,memory:0,growth:nil,read:nil,written:nil),ProcessRow(pid:2,parent:1,start:2,name:"two",cpu:nil,memory:0,growth:nil,read:nil,written:nil)]
        let cache=ExplorerSnapshotCache()
        XCTAssertTrue(cache.data(frame:snapshot).depths.isEmpty)
        XCTAssertEqual(cache.data(frame:snapshot,includeDepths:true).depths,["1:1":2,"2:2":2])
    }
    func testCanvasPointerPositionMapsToTheSharedTimeRangeAndClampsEdges() {
        let range=DateInterval(start:origin,duration:120)
        XCTAssertEqual(ExplorerTimelinePosition.time(atX:100,width:400,range:range),origin.addingTimeInterval(30))
        XCTAssertEqual(ExplorerTimelinePosition.time(atX:-20,width:400,range:range),range.start)
        XCTAssertEqual(ExplorerTimelinePosition.time(atX:450,width:400,range:range),range.end)
        XCTAssertNil(ExplorerTimelinePosition.time(atX:20,width:0,range:range))
        XCTAssertNil(ExplorerTimelinePosition.time(atX:.nan,width:400,range:range))
    }
}
