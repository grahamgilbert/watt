import XCTest
@testable import Watt

final class MemoryGrowthHistoryTests:XCTestCase {
    private let origin=Date(timeIntervalSince1970:1_800_000_000)
    private var range:DateInterval {DateInterval(start:origin,duration:10)}

    func testKnownEndpointsPreserveRealNegativeGrowth() throws {
        let summary=try XCTUnwrap(HistoryAnalysis.summarize([frame(1,memory:100),frame(3,memory:70)],range:range,gaps:[]).first)
        XCTAssertEqual(summary.memoryChange,-30)
        XCTAssertEqual(summary.firstMemory,100)
        XCTAssertEqual(summary.lastMemory,70)
    }

    func testGrowthAcrossRecordingGapIsUnavailableEvenWhenBothEndpointsExist() throws {
        let gap=RecordingGap(id:"gap",start:origin.addingTimeInterval(2),end:origin.addingTimeInterval(2.5),reason:"sampling gap")
        let summary=try XCTUnwrap(HistoryAnalysis.summarize([frame(1,memory:100),frame(3,memory:140)],range:range,gaps:[gap]).first)
        XCTAssertNil(summary.memoryChange)
        XCTAssertEqual(summary.peakMemory,140)
    }

    func testSourceOrSegmentChangesInvalidateGrowthInsteadOfJoiningBaselines() throws {
        var sourceChanged=frame(3,memory:140)
        sourceChanged.processes[0].metricSource="privileged"
        var segmentChanged=frame(3,memory:140)
        segmentChanged.segment="next"
        for last in [sourceChanged,segmentChanged] {
            let summary=try XCTUnwrap(HistoryAnalysis.summarize([frame(1,memory:100),last],range:range,gaps:[]).first)
            XCTAssertNil(summary.memoryChange)
        }
    }

    func testAnUnavailableIntermediateFootprintDoesNotBecomeKnownGrowth() throws {
        let summary=try XCTUnwrap(HistoryAnalysis.summarize([frame(1,memory:100),frame(2,memory:nil),frame(3,memory:140)],range:range,gaps:[]).first)
        XCTAssertNil(summary.memoryChange)
        XCTAssertEqual(summary.lastMemory,140)
    }

    func testDistinctLifetimesAndOutOfRangeEndpointsCannotProvideGrowth() throws {
        var reused=frame(3,memory:140)
        reused.processes[0].start=200
        let separate=HistoryAnalysis.summarize([frame(1,memory:100),reused],range:range,gaps:[])
        XCTAssertEqual(separate.count,2)
        XCTAssertTrue(separate.allSatisfy {$0.memoryChange == nil})
        let inside=try XCTUnwrap(HistoryAnalysis.summarize([frame(-1,memory:100),frame(1,memory:150),frame(3,memory:140)],range:range,gaps:[]).first)
        XCTAssertEqual(inside.memoryChange,-10)
    }

    private func frame(_ time:Double,memory:UInt64?)->Frame {
        let process=ProcessRow(pid:42,parent:1,start:100,name:"worker",cpu:0,memory:memory,growth:nil,read:nil,written:nil,metricSource:"local")
        return Frame(time:origin.addingTimeInterval(time),cpu:0,memory:0,compressed:0,swap:0,download:0,upload:0,processes:[process],denied:0,segment:"segment",elapsed:1)
    }
}
