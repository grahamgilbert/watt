import XCTest
import CTelemetry
@testable import Watt

final class EnergyTelemetryTests:XCTestCase {
    private let start=Date(timeIntervalSince1970:1_800_000_000)
    private func row(energy:UInt64?=nil,lifetime:UInt64=1) -> ProcessRow {
        ProcessRow(pid:42,parent:1,start:lifetime,name:"compiler",cpu:50,memory:100,growth:nil,read:10,written:20,energyNanojoules:energy)
    }
    private func frame(_ second:Double,elapsed:Double?=5,energy:UInt64?=nil,lifetime:UInt64=1) -> Frame {
        Frame(time:start.addingTimeInterval(second),cpu:50,memory:1000,compressed:0,swap:0,download:0,upload:0,processes:[row(energy:energy,lifetime:lifetime)],denied:0,elapsed:elapsed,cadence:5)
    }
    private func raw(_ energy:UInt64,available:Bool=true,lifetime:UInt64=1) -> WattProcess {
        var value=WattProcess();value.pid=42;value.start=lifetime
        value.energy_nj=energy;value.energy_available=available ? 1 : 0
        return value
    }
    func testNanojouleDeltasConvertToIntervalWattsAndZeroIsAValidReading() {
        XCTAssertEqual(row(energy:10_000_000_000).cpuPowerWatts(elapsed:5),2)
        XCTAssertEqual(row(energy:0).cpuPowerWatts(elapsed:5),0)
        XCTAssertNil(row().cpuPowerWatts(elapsed:5))
        for duration in [0.0,-1,.infinity,.nan] {XCTAssertNil(row(energy:100).cpuPowerWatts(elapsed:duration))}
        XCTAssertNil(row(energy:100).cpuPowerWatts(elapsed:nil))
    }
    func testFirstSampleUnavailableCounterAndPIDReuseCannotCreateEnergy() {
        XCTAssertNil(processEnergyDelta(current:raw(500),previous:nil))
        XCTAssertNil(processEnergyDelta(current:raw(500,available:false),previous:raw(400)))
        XCTAssertNil(processEnergyDelta(current:raw(500),previous:raw(0,available:false)))
        XCTAssertNil(processEnergyDelta(current:raw(500,lifetime:2),previous:raw(400,lifetime:1)))
    }
    func testResetCounterIsUnavailableButUnchangedSupportedCounterMeansZero() {
        XCTAssertNil(processEnergyDelta(current:raw(100),previous:raw(400)))
        XCTAssertEqual(processEnergyDelta(current:raw(400),previous:raw(400)),0)
        XCTAssertEqual(processEnergyDelta(current:raw(500),previous:raw(400)),100)
    }
    func testSummaryWeightsPowerByCoveredTimeInsteadOfAveragingSamples() throws {
        let frames=[frame(5,energy:10_000_000_000),frame(15,elapsed:10,energy:50_000_000_000)]
        let result=try XCTUnwrap(HistoryAnalysis.summarize(frames,range:DateInterval(start:start,duration:15),gaps:[]).first)
        XCTAssertEqual(result.energyJoules,60)
        XCTAssertEqual(result.energyCoveredSeconds,15)
        XCTAssertEqual(result.averagePower,4)
        XCTAssertEqual(result.peakPower,5)
    }
    func testGapsAndPartialBoundaryIntervalsDoNotInflateEnergyTotals() throws {
        let frames=[frame(5,energy:1_000_000_000),frame(10,energy:2_000_000_000),frame(15,energy:3_000_000_000)]
        let gap=RecordingGap(id:"gap",start:start.addingTimeInterval(6),end:start.addingTimeInterval(9),reason:"Paused")
        let range=DateInterval(start:start.addingTimeInterval(2),end:start.addingTimeInterval(15))
        let result=try XCTUnwrap(HistoryAnalysis.summarize(frames,range:range,gaps:[gap]).first)
        XCTAssertEqual(result.energyJoules,3)
        XCTAssertEqual(result.energyCoveredSeconds,5)
        XCTAssertEqual(result.averagePower,0.6)
    }
    func testOldRecordsRemainUnavailableAndDifferentLifetimesRemainSeparate() {
        let frames=[frame(5,elapsed:nil,energy:2_000_000_000),frame(10,lifetime:2)]
        let results=HistoryAnalysis.summarize(frames,range:DateInterval(start:start,duration:10),gaps:[])
        XCTAssertEqual(results.count,2)
        XCTAssertTrue(results.allSatisfy {$0.averagePower==nil && $0.energyCoveredSeconds==0 && $0.energyJoules==0})
    }
    func testEnergyAndWakeupSamplesPersistAndLegacyJSONStillDecodes() throws {
        var process=row(energy:2_000_000_000);process.idleWakeups=2;process.interruptWakeups=9
        let encoded=try JSONEncoder().encode(process)
        let restored=try JSONDecoder().decode(ProcessRow.self,from:encoded)
        XCTAssertEqual(restored.energyNanojoules,2_000_000_000)
        XCTAssertEqual(restored.idleWakeups,2);XCTAssertEqual(restored.interruptWakeups,9)
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        for key in ["energyNanojoules","idleWakeups","interruptWakeups"] {legacy.removeValue(forKey:key)}
        let old=try JSONDecoder().decode(ProcessRow.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(old.energyNanojoules);XCTAssertNil(old.idleWakeups);XCTAssertNil(old.interruptWakeups)
    }
}
