import XCTest
@testable import Watt

final class RestrictedProcessHistoryTests:XCTestCase {
    private let start=Date(timeIntervalSince1970:1_800_000_000)
    private func row(memory:UInt64?,cpu:Double?=nil,read:UInt64?=nil,written:UInt64?=nil)->ProcessRow {
        var process=ProcessRow(pid:1834,parent:1,start:1_700_000_000_000_000,name:"io.tailscale.ipn",cpu:cpu,memory:memory,growth:nil,read:read,written:written)
        process.userID=0;process.metricSource=memory == nil ? "restricted" : "privileged"
        return process
    }
    private func frame(_ second:Double,process:ProcessRow)->Frame {
        Frame(time:start.addingTimeInterval(second),cpu:10,memory:1000,compressed:0,swap:0,download:0,upload:0,
              processes:[process],denied:process.memory == nil ? 1 : 0,elapsed:5,cadence:5,
              processCPUAccounting:"mach-timebase-to-nanoseconds")
    }
    private func summarize(_ processes:[ProcessRow],gaps:[RecordingGap]=[]) throws -> ProcessSummary {
        let frames=processes.enumerated().map {frame(Double(($0.offset+1)*5),process:$0.element)}
        return try XCTUnwrap(HistoryAnalysis.summarize(frames,range:DateInterval(start:start,duration:Double(processes.count*5)),gaps:gaps).first)
    }

    func testRestrictedIdentityAndMissingMetricsSurviveHistoryRoundTrip() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer {for suffix in ["","-wal","-shm"] {try? FileManager.default.removeItem(atPath:path+suffix)}}
        let store=try HistoryStore(path:path)
        let recorded=frame(5,process:row(memory:nil))
        try store.append(recorded,now:start)
        let restored=try XCTUnwrap(store.frames(in:DateInterval(start:start,duration:10)).first?.processes.first)
        XCTAssertEqual(restored.id,recorded.processes[0].id)
        XCTAssertEqual(restored.name,"io.tailscale.ipn")
        XCTAssertEqual(restored.userID,0)
        XCTAssertEqual(restored.metricSource,"restricted")
        XCTAssertNil(restored.cpu);XCTAssertNil(restored.memory)
        XCTAssertNil(restored.read);XCTAssertNil(restored.written)
        XCTAssertNil(restored.growth)
    }

    func testLegacyNumericFootprintStillDecodesWithoutNewMetadata() throws {
        let payload=Data(#"{"pid":42,"parent":1,"start":100,"name":"legacy","cpu":20,"memory":512,"read":10,"written":20}"#.utf8)
        let process=try JSONDecoder().decode(ProcessRow.self,from:payload)
        XCTAssertEqual(process.memory,512)
        XCTAssertEqual(process.cpu,20)
        XCTAssertNil(process.userID);XCTAssertNil(process.metricSource)
    }

    func testEntirelyRestrictedIntervalKeepsEveryMetricUnavailable() throws {
        let summary=try summarize([row(memory:nil),row(memory:nil)])
        XCTAssertEqual(summary.samples,2)
        XCTAssertNil(summary.firstMemory);XCTAssertNil(summary.lastMemory)
        XCTAssertNil(summary.peakMemory);XCTAssertNil(summary.memoryChange)
        XCTAssertNil(summary.averageCPU);XCTAssertNil(summary.peakCPU)
        XCTAssertEqual(summary.cpuCoveredSeconds,0)
        XCTAssertEqual(summary.ioSamples,0)
        XCTAssertNil(summary.averagePower)
    }

    func testMeasuredZeroIsRetainedAsARealReading() throws {
        let zero=row(memory:0,cpu:0,read:0,written:0)
        let summary=try summarize([zero,zero])
        XCTAssertEqual(summary.firstMemory,0);XCTAssertEqual(summary.lastMemory,0)
        XCTAssertEqual(summary.peakMemory,0);XCTAssertEqual(summary.memoryChange,0)
        XCTAssertEqual(summary.averageCPU,0)
        XCTAssertEqual(summary.cpuCoveredSeconds,10)
        XCTAssertEqual(summary.ioSamples,2)
        XCTAssertEqual(summary.readBytes,0);XCTAssertEqual(summary.writtenBytes,0)
    }

    func testRestrictedEndpointDoesNotInventGrowthOrEraseMeasuredPeak() throws {
        let measured=row(memory:400,cpu:40,read:10,written:20)
        let missing=row(memory:nil)
        for processes in [[measured,missing],[missing,measured]] {
            let summary=try summarize(processes)
            XCTAssertEqual(summary.firstMemory,processes.first?.memory)
            XCTAssertEqual(summary.lastMemory,processes.last?.memory)
            XCTAssertEqual(summary.peakMemory,400)
            XCTAssertNil(summary.memoryChange)
            XCTAssertEqual(summary.averageCPU,40)
            XCTAssertEqual(summary.cpuCoveredSeconds,5)
            XCTAssertEqual(summary.ioSamples,1)
        }
    }

    func testMissingFootprintBreaksTheSelectedProcessGraph() {
        let frames=[frame(5,process:row(memory:1_048_576)),frame(10,process:row(memory:nil)),frame(15,process:row(memory:2_097_152))]
        let trace=ExplorerTraceCache().data(frames:frames,gaps:[],processID:frames[0].processes[0].id,metric:"Memory")
        XCTAssertEqual(trace.points.map(\.value),[1,2])
        XCTAssertEqual(trace.points.map(\.time),[frames[0].time,frames[2].time])
        XCTAssertEqual(Set(trace.points.map(\.series)).count,2,"Unavailable memory must break the line, rather than draw a zero or join across missing data")
    }

    func testGapsExcludeCounterTotalsAndBreakMemoryGraph() throws {
        let frames=[frame(5,process:row(memory:100,cpu:20,read:10,written:20)),
                    frame(10,process:row(memory:200,cpu:80,read:1000,written:2000)),
                    frame(15,process:row(memory:300,cpu:40,read:30,written:40))]
        let gap=RecordingGap(id:"gap",start:start.addingTimeInterval(6),end:start.addingTimeInterval(9),reason:"Device asleep")
        let summary=try XCTUnwrap(HistoryAnalysis.summarize(frames,range:DateInterval(start:start,duration:15),gaps:[gap]).first)
        XCTAssertEqual(summary.cpuCoveredSeconds,10)
        XCTAssertEqual(summary.averageCPU,30)
        XCTAssertEqual(summary.readBytes,40);XCTAssertEqual(summary.writtenBytes,60)
        XCTAssertEqual(summary.ioSamples,2)
        let trace=ExplorerTraceCache().data(frames:frames,gaps:[gap],processID:frames[0].processes[0].id,metric:"Memory")
        XCTAssertEqual(trace.points.count,2)
        XCTAssertEqual(Set(trace.points.map(\.series)).count,2)
    }
}
