import XCTest
import WattEnergyProtocol
@testable import Watt

final class EnergyTileSummaryTests:XCTestCase {
    func testSummaryChoicePersistsAndCanonicalTileRoutesToMatchingDetail() async {
        await MainActor.run {
            let suite="watt-energy-tile-"+UUID().uuidString
            let defaults=UserDefaults(suiteName:suite)!
            defer {defaults.removePersistentDomain(forName:suite)}
            let layout=PopupLayoutSettings(defaults:defaults)
            XCTAssertEqual(layout.energySummary,"CPU power")
            XCTAssertEqual(layout.detailItem(for:.energy),.energy)
            layout.energySummary="Energy Impact"
            let restored=PopupLayoutSettings(defaults:defaults)
            XCTAssertEqual(restored.energySummary,"Energy Impact")
            XCTAssertEqual(restored.detailItem(for:.energy),.energyImpact)
            XCTAssertEqual(restored.detailItem(for:.processCPUPower),.processCPUPower)
            XCTAssertEqual(restored.detailItem(for:.applicationCPUPower),.applicationCPUPower)
            restored.reset()
            XCTAssertEqual(PopupLayoutSettings(defaults:defaults).energySummary,"Energy Impact")
        }
    }
    func testInvalidStoredAndAssignedChoicesFallBackToCPUWithoutKeepingInvalidState() async {
        await MainActor.run {
            let suite="watt-energy-tile-invalid-"+UUID().uuidString
            let defaults=UserDefaults(suiteName:suite)!
            defer {defaults.removePersistentDomain(forName:suite)}
            defaults.set("Unrecognized future choice",forKey:PopupLayoutSettings.energySummaryKey)
            let layout=PopupLayoutSettings(defaults:defaults)
            XCTAssertEqual(layout.energySummary,"CPU power")
            layout.energySummary="Energy Impact"
            layout.energySummary="invalid"
            XCTAssertEqual(layout.energySummary,"CPU power")
            XCTAssertEqual(defaults.string(forKey:PopupLayoutSettings.energySummaryKey),"CPU power")
            XCTAssertEqual(PopupLayoutSettings(defaults:defaults).detailItem(for:.energy),.energy)
        }
    }
    func testZeroImpactIsMeasuredWhileMissingStaleFutureAndReusedLifetimeStayUnavailable() {
        let zero=frame(time:1,capture:"zero",score:0)
        let id=zero.processes[0].id
        XCTAssertEqual(popupEnergyImpactRows(zero).first?.impact,0)
        XCTAssertEqual(popupProcessImpactHistory([zero],processID:id).first?.value,0)
        var missing=zero;missing.energyImpact=nil
        var stale=zero;stale.time=zero.time.addingTimeInterval(16)
        var future=zero;future.time=zero.time.addingTimeInterval(-1)
        var reused=zero;reused.processes[0].start+=1_000_000
        for unavailable in [missing,stale,future,reused] {
            XCTAssertTrue(popupEnergyImpactRows(unavailable).isEmpty)
            XCTAssertTrue(popupProcessImpactHistory([unavailable],processID:unavailable.processes[0].id).isEmpty)
        }
        XCTAssertTrue(popupProcessImpactHistory([zero],processID:nil).isEmpty)
    }
    func testHistoryUsesOnlySelectedProcessCaptureTimesAndPreservesMissingCaptureGap() {
        let first=frame(time:1,capture:"first",score:7)
        var cached=first;cached.time=cached.time.addingTimeInterval(1)
        var missing=first;missing.time=missing.time.addingTimeInterval(2);missing.energyImpact=nil
        let last=frame(time:6,capture:"last",score:0)
        let points=popupProcessImpactHistory([first,cached,missing,last],processID:first.processes[0].id)
        XCTAssertEqual(points.map(\.id),["first","last"])
        XCTAssertEqual(points.map(\.value),[7,0])
        XCTAssertEqual(points.map(\.time),[first.energyImpact!.endedAt,last.energyImpact!.endedAt])
        XCTAssertNotEqual(points[0].segment,points[1].segment)
        XCTAssertTrue(popupProcessImpactHistory([first],processID:"99:123").isEmpty)
    }
    func testLeadingProcessAndItsHistoryNeverSumPeerScores() throws {
        var f=frame(time:1,capture:"peers",score:7)
        let first=f.processes[0]
        var other=first;other.pid=43;other.name="other"
        f.processes.append(other)
        let sample=try XCTUnwrap(f.energyImpact)
        f.energyImpact=EnergyImpactSample(id:sample.id,startedAt:sample.startedAt,endedAt:sample.endedAt,tasks:sample.tasks+[
            EnergyImpactTask(pid:43,name:"other",energyImpact:nil,energyImpactPerSecond:100,processStartMicroseconds:other.start)
        ])
        let leading=try XCTUnwrap(popupLeadingEnergyImpact(f))
        XCTAssertEqual(leading.process.id,other.id)
        XCTAssertEqual(leading.impact,100)
        XCTAssertEqual(popupProcessImpactHistory([f],processID:other.id).map(\.value),[100])
        XCTAssertEqual(popupProcessImpactHistory([f],processID:first.id).map(\.value),[7])
    }
    private func frame(time:Double,capture:String,score:Double)->Frame {
        let origin=Date(timeIntervalSince1970:1_800_000_000)
        let start:UInt64=1_799_999_900_000_000
        let process=ProcessRow(pid:42,parent:1,start:start,name:"worker",cpu:0,memory:0,growth:nil,read:nil,written:nil)
        let end=origin.addingTimeInterval(time)
        let sample=EnergyImpactSample(id:capture,startedAt:end.addingTimeInterval(-1),endedAt:end,tasks:[EnergyImpactTask(pid:42,name:"worker",energyImpact:nil,energyImpactPerSecond:score,processStartMicroseconds:start)])
        return Frame(time:end,cpu:0,memory:0,compressed:0,swap:0,download:0,upload:0,processes:[process],denied:0,segment:"segment",elapsed:2,cadence:2,energyImpact:sample)
    }
}
