import XCTest
import WattEnergyProtocol
@testable import Watt

final class ExplorerEnergyImpactTests:XCTestCase {
    private let origin=Date(timeIntervalSince1970:1_800_000_000)
    private var process:ProcessRow {ProcessRow(pid:42,parent:1,start:UInt64(origin.addingTimeInterval(-10).timeIntervalSince1970*1e6),name:"compiler",cpu:10,memory:100,growth:nil,read:nil,written:nil)}
    private func capture(_ id:String,start:Double,end:Double,score:Double?,lifetime:UInt64?=nil)->EnergyImpactSample {
        EnergyImpactSample(id:id,startedAt:origin.addingTimeInterval(start),endedAt:origin.addingTimeInterval(end),tasks:[EnergyImpactTask(pid:42,name:"compiler",energyImpact:999,energyImpactPerSecond:score,processStartMicroseconds:lifetime ?? process.start)])
    }
    private func frame(_ second:Double,_ sample:EnergyImpactSample?)->Frame {
        Frame(time:origin.addingTimeInterval(second),cpu:10,memory:100,compressed:0,swap:0,download:0,upload:0,processes:[process],denied:0,energyImpact:sample)
    }
    func testCachedCaptureCountedOnceAndScoresWeightedByActualCaptureDuration() throws {
        let a=capture("a",start:0,end:1,score:10),b=capture("b",start:8,end:10,score:40)
        let result=try XCTUnwrap(ExplorerImpactSummary.summarize([frame(1,a),frame(5,a),frame(10,b)],range:DateInterval(start:origin,duration:15),gaps:[])[process.id])
        XCTAssertEqual(result.captures,2);XCTAssertEqual(result.coveredSeconds,3)
        XCTAssertEqual(result.average,30);XCTAssertEqual(result.peak,40)
    }
    func testStaleFuturePIDReusedAndAbsentScoresStayUnavailable() {
        let old=capture("old",start:0,end:1,score:10)
        let future=capture("future",start:5,end:6,score:10)
        let reused=capture("reused",start:0,end:1,score:10,lifetime:process.start-1_000_000)
        let missing=capture("missing",start:0,end:1,score:nil)
        let results=ExplorerImpactSummary.summarize([frame(17,old),frame(4,future),frame(1,reused),frame(1,missing)],range:DateInterval(start:origin,duration:20),gaps:[])
        XCTAssertTrue(results.isEmpty)
    }
    func testZeroIsMeasuredAndRangeClipsCaptureCoverage() throws {
        let sample=capture("zero",start:0,end:5,score:0)
        let result=try XCTUnwrap(ExplorerImpactSummary.summarize([frame(5,sample)],range:DateInterval(start:origin.addingTimeInterval(2),duration:3),gaps:[])[process.id])
        XCTAssertEqual(result.average,0);XCTAssertEqual(result.coveredSeconds,3)
    }
    func testGapOverlappingCaptureExcludesItsWholeScore() {
        let gap=RecordingGap(id:"paused",start:origin.addingTimeInterval(2),end:origin.addingTimeInterval(3),reason:"Paused")
        XCTAssertTrue(ExplorerImpactSummary.summarize([frame(5,capture("a",start:0,end:5,score:20))],range:DateInterval(start:origin,duration:5),gaps:[gap]).isEmpty)
    }
}
