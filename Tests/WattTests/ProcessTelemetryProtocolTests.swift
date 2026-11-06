import Foundation
import XCTest
import WattEnergyProtocol

final class ProcessTelemetryProtocolTests:XCTestCase {
    private let date=Date(timeIntervalSince1970:1_800_000_000)

    private func task(pid:Int32=42,parent:Int32=1,start:UInt64=1_799_999_999_000_000,name:String="security-agent",available:Bool=true,
                      cpu:UInt64=0,memory:UInt64=0,read:UInt64=0,written:UInt64=0,energy:UInt64?=nil) -> ProcessTelemetryTask {
        ProcessTelemetryTask(pid:pid,parent:parent,start:start,name:name,uid:0,metricsAvailable:available,
            cpuNanoseconds:cpu,memory:memory,readBytes:read,writtenBytes:written,energyNanojoules:energy)
    }
    private func sample(_ tasks:[ProcessTelemetryTask],uptime:TimeInterval=100,denied:Int=0) -> ProcessTelemetrySample {
        ProcessTelemetrySample(sampledAt:date,uptime:uptime,tasks:tasks,denied:denied)
    }

    func testRoundTripPreservesMeasuredZeroAndUnavailableCounters() throws {
        let original=sample([task(),task(pid:43,name:"restricted-agent",available:false)],denied:1)
        let restored=try ProcessTelemetrySample.decode(JSONEncoder().encode(original))
        XCTAssertEqual(restored.id,original.id)
        XCTAssertEqual(restored.sampledAt,date)
        XCTAssertEqual(restored.uptime,100)
        XCTAssertEqual(restored.denied,1)
        XCTAssertTrue(restored.tasks[0].metricsAvailable)
        XCTAssertEqual(restored.tasks[0].memory,0)
        XCTAssertFalse(restored.tasks[1].metricsAvailable)
        XCTAssertNil(restored.tasks[1].energyNanojoules)
        XCTAssertEqual(restored.tasks[1].start,1_799_999_999_000_000)
    }

    func testCumulativeCountersAndRootIdentitySurviveEncoding() throws {
        let original=sample([task(cpu:123_456_789,memory:512*1024,read:91,written:108,energy:100)])
        let process=try XCTUnwrap(ProcessTelemetrySample.decode(JSONEncoder().encode(original)).tasks.first)
        XCTAssertEqual(process.uid,0)
        XCTAssertEqual(process.cpuNanoseconds,123_456_789)
        XCTAssertEqual(process.memory,512*1024)
        XCTAssertEqual(process.readBytes,91)
        XCTAssertEqual(process.writtenBytes,108)
        XCTAssertEqual(process.energyNanojoules,100)
    }

    func testInvalidLifetimeOrNamesAreRejected() {
        for process in [task(pid:0),task(parent:-1),task(parent:42),task(start:0),task(start:1_800_000_001_000_000),
                        task(name:""),task(name:"line\nbreak"),task(name:String(repeating:"x",count:513))] {
            XCTAssertThrowsError(try sample([process]).validate())
        }
        XCTAssertThrowsError(try sample([task(),task(start:1_799_999_998_000_000)]).validate(),"One inventory cannot contain two lifetimes for the same PID")
    }

    func testMissingMetricsCannotCarryFabricatedValues() {
        for process in [task(available:false,cpu:1),task(available:false,memory:1),task(available:false,read:1),
                        task(available:false,written:1),task(available:false,energy:0)] {
            XCTAssertThrowsError(try sample([process]).validate())
        }
    }

    func testInvalidCaptureMetadataAndOversizedPayloadsAreRejected() {
        XCTAssertThrowsError(try sample([]).validate(),"A full native inventory must include at least the helper itself")
        for uptime in [Double.nan,.infinity,-1,0] {
            XCTAssertThrowsError(try sample([],uptime:uptime).validate())
        }
        XCTAssertThrowsError(try sample([],denied:-1).validate())
        XCTAssertThrowsError(try sample([],denied:ProcessTelemetryConfiguration.maximumTasks+1).validate())
        XCTAssertThrowsError(try sample(Array(repeating:task(),count:ProcessTelemetryConfiguration.maximumTasks+1)).validate())
        XCTAssertThrowsError(try ProcessTelemetrySample(id:"not-a-capture-id",sampledAt:date,uptime:100,tasks:[],denied:0).validate())
        XCTAssertThrowsError(try ProcessTelemetrySample.decode(Data(repeating:0,count:ProcessTelemetryConfiguration.maximumOutputBytes+1)))
    }
}
