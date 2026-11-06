import CTelemetry
import Foundation
import WattEnergyProtocol
import XCTest
@testable import Watt

final class ProcessMeasurementsTests:XCTestCase {
    private func raw(pid:Int32=1834,start:UInt64=1_700_000_000_000_000,uid:UInt32=0,
                     available:Bool=true,cpu:UInt64=1_000_000_000,memory:UInt64=300,
                     read:UInt64=100,written:UInt64=10,energy:UInt64=5_000_000_000,
                     idle:UInt64=3,interrupt:UInt64=4,wakeupsAvailable:Bool=true)->WattProcess {
        var process=WattProcess()
        process.pid=pid;process.parent=1;process.start=start;process.uid=uid
        process.metrics_available=available ? 1 : 0
        process.cpu=cpu;process.footprint=memory;process.read=read;process.written=written
        process.energy_available=1;process.energy_nj=energy
        process.idle_wakeups=idle;process.interrupt_wakeups=interrupt
        process.wakeups_available=available && wakeupsAvailable ? 1 : 0
        let name=Array("security-agent".utf8CString)
        withUnsafeMutablePointer(to:&process.name) {pointer in
            pointer.withMemoryRebound(to:CChar.self,capacity:256) {buffer in
                for (index,byte) in name.enumerated() {buffer[index]=byte}
            }
        }
        return process
    }

    private func assertNoIntervalCounters(_ row:ProcessRow,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertNil(row.cpu,file:file,line:line)
        XCTAssertNil(row.read,file:file,line:line)
        XCTAssertNil(row.written,file:file,line:line)
        XCTAssertNil(row.energyNanojoules,file:file,line:line)
        XCTAssertNil(row.idleWakeups,file:file,line:line)
        XCTAssertNil(row.interruptWakeups,file:file,line:line)
    }

    func testDeniedProcessKeepsIdentityWithoutLeakingUnusableRawCounters() {
        let current=raw(available:false,cpu:9_000_000_000,memory:900,read:900,written:900,
                        energy:9_000_000_000,idle:900,interrupt:900)
        let row=ProcessMeasurements.row(current:current,previous:raw(),elapsed:5,source:"local")
        XCTAssertEqual(row.pid,1834);XCTAssertEqual(row.parent,1)
        XCTAssertEqual(row.start,current.start);XCTAssertEqual(row.name,"security-agent")
        XCTAssertEqual(row.userID,0);XCTAssertEqual(row.metricSource,"restricted")
        XCTAssertNil(row.memory);XCTAssertNil(row.growth)
        assertNoIntervalCounters(row)
    }

    func testFirstObservationHasCurrentFootprintButNoInventedDeltas() {
        let row=ProcessMeasurements.row(current:raw(),previous:nil,elapsed:5,source:"privileged")
        XCTAssertEqual(row.memory,300)
        XCTAssertEqual(row.metricSource,"privileged")
        XCTAssertNil(row.growth)
        assertNoIntervalCounters(row)
    }

    func testMeasuredZeroIsPreservedAfterAValidBaseline() {
        let process=raw(memory:0)
        let row=ProcessMeasurements.row(current:process,previous:process,elapsed:5,source:"privileged")
        XCTAssertEqual(row.memory,0);XCTAssertEqual(row.growth,0)
        XCTAssertEqual(row.cpu,0);XCTAssertEqual(row.read,0);XCTAssertEqual(row.written,0)
        XCTAssertEqual(row.energyNanojoules,0)
        XCTAssertEqual(row.cpuPowerWatts(elapsed:5),0)
        XCTAssertEqual(row.idleWakeups,0);XCTAssertEqual(row.interruptWakeups,0)
    }

    func testCountersUseMeasuredElapsedTimeAndMemoryCanShrink() {
        let old=raw()
        let current=raw(cpu:3_000_000_000,memory:200,read:356,written:42,
                        energy:9_000_000_000,idle:8,interrupt:11)
        let row=ProcessMeasurements.row(current:current,previous:old,elapsed:4,source:"privileged")
        XCTAssertEqual(row.cpu,50)
        XCTAssertEqual(row.memory,200);XCTAssertEqual(row.growth,-100)
        XCTAssertEqual(row.read,256);XCTAssertEqual(row.written,32)
        XCTAssertEqual(row.energyNanojoules,4_000_000_000)
        XCTAssertEqual(row.cpuPowerWatts(elapsed:4),1)
        XCTAssertEqual(row.idleWakeups,5);XCTAssertEqual(row.interruptWakeups,7)
    }

    func testRegainingAccessRequiresANewBaseline() {
        let denied=raw(available:false,cpu:0,memory:0,read:0,written:0,energy:0,idle:0,interrupt:0)
        let current=raw()
        let first=ProcessMeasurements.row(current:current,previous:denied,elapsed:5,source:"privileged")
        XCTAssertEqual(first.memory,300);XCTAssertNil(first.growth)
        assertNoIntervalCounters(first)
        let next=raw(cpu:2_000_000_000,memory:350,read:120,written:30,
                     energy:6_000_000_000,idle:4,interrupt:5)
        let resumed=ProcessMeasurements.row(current:next,previous:current,elapsed:5,source:"privileged")
        XCTAssertEqual(resumed.cpu,20);XCTAssertEqual(resumed.growth,50)
        XCTAssertEqual(resumed.read,20);XCTAssertEqual(resumed.written,20)
    }

    func testDifferentPIDOrReusedPIDCannotBorrowAnEarlierLifetime() {
        let current=raw(start:1_700_000_000_000_002)
        for old in [raw(start:1_700_000_000_000_001),raw(pid:42,start:current.start)] {
            let row=ProcessMeasurements.row(current:current,previous:old,elapsed:5,source:"privileged")
            XCTAssertEqual(row.memory,300)
            XCTAssertNil(row.growth)
            assertNoIntervalCounters(row)
        }
    }

    func testCounterResetsAreUnavailableRatherThanUnsignedSpikes() {
        let old=raw(cpu:100,memory:200,read:100,written:100,energy:100,idle:100,interrupt:100)
        let current=raw(cpu:99,memory:250,read:99,written:99,energy:99,idle:99,interrupt:99)
        let row=ProcessMeasurements.row(current:current,previous:old,elapsed:5,source:"privileged")
        XCTAssertEqual(row.memory,250);XCTAssertEqual(row.growth,50)
        assertNoIntervalCounters(row)
    }

    func testInvalidElapsedTimeCannotProduceIntervalMeasurements() {
        let old=raw()
        let current=raw(cpu:2_000_000_000,memory:350,read:150,written:50,
                        energy:6_000_000_000,idle:8,interrupt:9)
        let durations:[TimeInterval?]=[nil,0,-1,Double.nan,Double.infinity,-Double.infinity]
        for duration in durations {
            let row=ProcessMeasurements.row(current:current,previous:old,elapsed:duration,source:"local")
            XCTAssertEqual(row.memory,350)
            assertNoIntervalCounters(row)
        }
    }

    func testFootprintGrowthOutsideSignedRangeIsUnavailable() {
        for (old,current) in [(UInt64(0),UInt64.max),(UInt64.max,UInt64(0))] {
            let row=ProcessMeasurements.row(current:raw(memory:current),previous:raw(memory:old),elapsed:5,source:"privileged")
            XCTAssertEqual(row.memory,current)
            XCTAssertNil(row.growth)
        }
    }

    func testDTOConversionPreservesRootIdentityCountersAndSource() {
        let name="io.tailscale.ipn.macsys.network-extension"
        let task=ProcessTelemetryTask(pid:1834,parent:1,start:1_700_000_000_000_000,name:name,uid:0,metricsAvailable:true,
            cpuNanoseconds:3_000_000_000,memory:2048,readBytes:4096,writtenBytes:8192,
            energyNanojoules:9_000_000_000,idleWakeups:12,interruptWakeups:14)
        let counters=ProcessMeasurements.counters(task)
        XCTAssertEqual(counters.metrics_available,1)
        XCTAssertEqual(counters.pid,1834);XCTAssertEqual(counters.parent,1)
        XCTAssertEqual(counters.start,task.start);XCTAssertEqual(counters.uid,0)
        XCTAssertEqual(counters.cpu,task.cpuNanoseconds);XCTAssertEqual(counters.footprint,task.memory)
        XCTAssertEqual(counters.read,task.readBytes);XCTAssertEqual(counters.written,task.writtenBytes)
        XCTAssertEqual(counters.energy_available,1);XCTAssertEqual(counters.energy_nj,9_000_000_000)
        XCTAssertEqual(counters.wakeups_available,1)
        XCTAssertEqual(counters.idle_wakeups,12);XCTAssertEqual(counters.interrupt_wakeups,14)
        let row=ProcessMeasurements.row(current:counters,previous:nil,elapsed:5,source:"privileged")
        XCTAssertEqual(row.name,name);XCTAssertEqual(row.userID,0)
        XCTAssertEqual(row.metricSource,"privileged")
        XCTAssertEqual(row.memory,2048)
    }

    func testDTOWithoutMetricsCannotBecomeAZeroMeasurement() {
        let task=ProcessTelemetryTask(pid:1834,parent:1,start:1_700_000_000_000_000,name:"protected",uid:0,metricsAvailable:false,
            cpuNanoseconds:0,memory:0,readBytes:0,writtenBytes:0)
        let counters=ProcessMeasurements.counters(task)
        XCTAssertEqual(counters.metrics_available,0);XCTAssertEqual(counters.energy_available,0)
        XCTAssertEqual(counters.wakeups_available,0)
        let row=ProcessMeasurements.row(current:counters,previous:raw(),elapsed:5,source:"privileged")
        XCTAssertEqual(row.name,"protected");XCTAssertEqual(row.userID,0)
        XCTAssertEqual(row.metricSource,"restricted")
        XCTAssertNil(row.memory);XCTAssertNil(row.growth)
        assertNoIntervalCounters(row)
    }

    func testMissingOptionalDTOCountersStayUnavailableWhileMeasuredCountersRemainZero() {
        for idle in [nil,UInt64(12)] {
            let task=ProcessTelemetryTask(pid:1834,parent:1,start:1_700_000_000_000_000,name:"security-agent",uid:0,metricsAvailable:true,
                cpuNanoseconds:100,memory:0,readBytes:200,writtenBytes:300,idleWakeups:idle,interruptWakeups:nil)
            let counters=ProcessMeasurements.counters(task)
            XCTAssertEqual(counters.metrics_available,1);XCTAssertEqual(counters.wakeups_available,0)
            let row=ProcessMeasurements.row(current:counters,previous:counters,elapsed:5,source:"privileged")
            XCTAssertEqual(row.memory,0);XCTAssertEqual(row.cpu,0)
            XCTAssertEqual(row.read,0);XCTAssertEqual(row.written,0)
            XCTAssertNil(row.energyNanojoules)
            XCTAssertNil(row.idleWakeups);XCTAssertNil(row.interruptWakeups)
        }
    }

    func testWakeupCounterAvailabilityChangesRequireTheirOwnBaseline() {
        let available=raw()
        let missing=raw(idle:900,interrupt:900,wakeupsAvailable:false)
        for (old,current) in [(available,missing),(missing,available)] {
            let row=ProcessMeasurements.row(current:current,previous:old,elapsed:5,source:"privileged")
            XCTAssertEqual(row.cpu,0);XCTAssertEqual(row.memory,300)
            XCTAssertNil(row.idleWakeups);XCTAssertNil(row.interruptWakeups)
        }
    }

    private let request=Date(timeIntervalSince1970:1_800_000_000)
    private func capture(wallOffset:TimeInterval=0.1,uptime:TimeInterval=1000.1)->ProcessTelemetrySample {
        ProcessTelemetrySample(sampledAt:request.addingTimeInterval(wallOffset),uptime:uptime,tasks:[],denied:0)
    }
    private func accepts(_ sample:ProcessTelemetrySample)->Bool {
        ProcessTelemetryFreshness.accepts(sample,requestedAt:request,receivedAt:request.addingTimeInterval(0.2),
            requestedUptime:1000,receivedUptime:1000.2)
    }

    func testFreshnessAcceptsCapturesTakenDuringThisRequest() {
        XCTAssertTrue(accepts(capture()))
        XCTAssertTrue(accepts(capture(wallOffset:0,uptime:1000)))
        XCTAssertTrue(accepts(capture(wallOffset:0.2,uptime:1000.2)))
    }

    func testFreshnessRejectsOldOrFutureWallTimeEvenWithCurrentUptime() {
        XCTAssertFalse(accepts(capture(wallOffset:-1)))
        XCTAssertFalse(accepts(capture(wallOffset:1)))
    }

    func testFreshnessRejectsOldOrFutureUptimeEvenWithCurrentWallTime() {
        XCTAssertFalse(accepts(capture(uptime:999)))
        XCTAssertFalse(accepts(capture(uptime:1001)))
        XCTAssertFalse(accepts(capture(uptime:.nan)))
        XCTAssertFalse(accepts(capture(uptime:.infinity)))
    }

    func testFreshnessAllowsOnlySmallClockReadSkew() {
        XCTAssertTrue(accepts(capture(wallOffset:-0.02,uptime:999.98)))
        XCTAssertTrue(accepts(capture(wallOffset:0.22,uptime:1000.22)))
        XCTAssertFalse(accepts(capture(wallOffset:-0.1,uptime:999.9)))
        XCTAssertFalse(accepts(capture(wallOffset:0.3,uptime:1000.3)))
    }
}
