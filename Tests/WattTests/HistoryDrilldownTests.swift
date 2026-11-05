import XCTest
@testable import Watt

final class HistoryDrilldownTests:XCTestCase {
    private let start=Date(timeIntervalSince1970:1_800_000_000)
    private func row(start:UInt64=1,cpu:Double?=50,memory:UInt64=100,read:UInt64?=10) -> ProcessRow {
        ProcessRow(pid:42,parent:1,start:start,name:"compiler",cpu:cpu,memory:memory,growth:nil,read:read,written:20)
    }
    private func frame(_ second:Double,elapsed:Double?=5,rows:[ProcessRow]) -> Frame {
        Frame(time:start.addingTimeInterval(second),cpu:50,memory:1000,compressed:0,swap:0,download:0,upload:0,processes:rows,denied:0,elapsed:elapsed,cadence:5)
    }
    func testHistoricalQueryReachesBeyondRecentCacheAndBoundsEndpoints() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer {for suffix in ["","-wal","-shm"] {try? FileManager.default.removeItem(atPath:path+suffix)}}
        let store=try HistoryStore(path:path)
        for i in 0..<730 {try store.append(frame(Double(i*5),rows:[row()]),now:start)}
        XCTAssertEqual(try store.recent().count,720)
        let older=try store.frames(in:DateInterval(start:start,duration:10))
        XCTAssertEqual(older.count,3);XCTAssertEqual(older.first?.time,start)
        XCTAssertEqual(try store.bounds()?.end,start.addingTimeInterval(729*5))
        XCTAssertThrowsError(try store.frames(in:DateInterval(start:start,duration:100),maximumFrames:2))
        XCTAssertThrowsError(try store.frames(in:DateInterval(start:start,duration:100),maximumBytes:1))
    }
    func testCPUIsTimeWeightedAndIOUsesOnlyCoveredIntervals() throws {
        let frames=[frame(5,rows:[row(cpu:100,memory:100,read:10)]),frame(15,elapsed:10,rows:[row(cpu:200,memory:300,read:40)])]
        let result=try XCTUnwrap(HistoryAnalysis.summarize(frames,range:DateInterval(start:start,duration:15),gaps:[]).first)
        XCTAssertEqual(result.averageCPU!,166.666666,accuracy:0.001)
        XCTAssertEqual(result.cpuSeconds,25);XCTAssertEqual(result.cpuCoveredSeconds,15)
        XCTAssertEqual(result.peakCPU,200);XCTAssertEqual(result.peakMemory,300)
        XCTAssertEqual(result.memoryChange,200);XCTAssertEqual(result.readBytes,50)
    }
    func testPIDReuseRemainsSeparateAndLegacyCountersDoNotBecomeTime() {
        let frames=[frame(5,elapsed:nil,rows:[row()]),frame(10,rows:[row(start:2,cpu:nil,read:nil)])]
        let result=HistoryAnalysis.summarize(frames,range:DateInterval(start:start,duration:10),gaps:[])
        XCTAssertEqual(result.count,2)
        XCTAssertTrue(result.allSatisfy {$0.averageCPU==nil && $0.cpuSeconds==0 && $0.ioSamples==0})
    }
    func testCursorDoesNotInventStateInsideGapsOrOutsideCoverage() {
        let frames=[frame(5,rows:[row()]),frame(30,rows:[row()])]
        let gap=RecordingGap(id:"gap",start:start.addingTimeInterval(5),end:start.addingTimeInterval(25),reason:"Sleep")
        XCTAssertNil(HistoryAnalysis.snapshot(at:start.addingTimeInterval(15),frames:frames,gaps:[gap]))
        XCTAssertNil(HistoryAnalysis.snapshot(at:start.addingTimeInterval(60),frames:frames,gaps:[]))
        XCTAssertEqual(HistoryAnalysis.snapshot(at:start.addingTimeInterval(6),frames:frames,gaps:[])?.time,frames[0].time)
    }
    func testPartialBoundaryAndGapIntervalsAreExcludedFromTotals() throws {
        let frames=[frame(5,rows:[row()]),frame(10,rows:[row()]),frame(15,rows:[row()])]
        let range=DateInterval(start:start.addingTimeInterval(2),end:start.addingTimeInterval(15))
        let gap=RecordingGap(id:"gap",start:start.addingTimeInterval(6),end:start.addingTimeInterval(9),reason:"Pause")
        let result=try XCTUnwrap(HistoryAnalysis.summarize(frames,range:range,gaps:[gap]).first)
        XCTAssertEqual(result.cpuCoveredSeconds,5);XCTAssertEqual(result.readBytes,10)
        XCTAssertEqual(result.samples,3)
    }
}
