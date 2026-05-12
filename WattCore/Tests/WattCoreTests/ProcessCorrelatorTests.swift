import XCTest
@testable import WattAnalysis
@testable import WattModels

final class ProcessCorrelatorTests: XCTestCase {
    func testRanksWriterAndReaderAtTopOfClaudeFalconArchetype() {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 20, thermalState: 2)
        let withProcesses = drain.map { sample -> SamplePoint in
            var s = sample
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 250 * 1024 * 1024
            )
            return s
        }
        let result = ProcessCorrelator(configuration: .init(coreCount: 8)).correlate(samples: withProcesses)
        XCTAssertEqual(result.suspects.count, 3)
        XCTAssertEqual(result.suspects[0].name, "claude")
        XCTAssertEqual(result.suspects[1].name, "falconctl")
    }

    func testCorrelatedWriterReaderPatternFires() {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 20)
        let withProcesses = drain.map { sample -> SamplePoint in
            var s = sample
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 250 * 1024 * 1024
            )
            return s
        }
        let result = ProcessCorrelator().correlate(samples: withProcesses)
        let pair = try? XCTUnwrap(result.patterns.correlatedWriterReader)
        XCTAssertEqual(pair?.writer.name, "claude")
        XCTAssertEqual(pair?.reader.name, "falconctl")
    }

    func testThermalThrottleFlagFiresWhenMostSamplesAreSerious() {
        var drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 30, count: 20, thermalState: 2)
        drain = drain.enumerated().map { i, sample in
            var s = sample
            s.thermalState = i < 4 ? 1 : 2
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 200 * 1024 * 1024
            )
            return s
        }
        let result = ProcessCorrelator().correlate(samples: drain)
        XCTAssertTrue(result.patterns.thermalThrottle)
    }

    func testFanSpikeFiresAtHighRPM() {
        var drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 30, count: 10)
        drain = drain.map { sample in
            var s = sample
            s.fanRPM = [5800]
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 200 * 1024 * 1024
            )
            return s
        }
        let result = ProcessCorrelator().correlate(samples: drain)
        XCTAssertTrue(result.patterns.fanSpike)
    }

    func testNoFalsePositivePairWhenOnlyWriterIsBusy() {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 30, count: 20)
        let onlyWriter = drain.map { sample -> SamplePoint in
            var s = sample
            s.processes = [
                ProcessPoint(
                    pid: 81134, name: "claude", bundleID: nil,
                    cpuTimeDelta: 1.0,
                    energyNanojoulesDelta: 600_000_000,
                    billedEnergyDelta: 600_000_000,
                    diskReadBytesDelta: 0,
                    diskWriteBytesDelta: 200 * 1024 * 1024,
                    pageinsDelta: 0,
                    residentBytes: 600_000_000
                ),
                ProcessPoint(
                    pid: 198, name: "WindowServer", bundleID: nil,
                    cpuTimeDelta: 0.05,
                    energyNanojoulesDelta: 1_000_000,
                    billedEnergyDelta: 1_000_000,
                    diskReadBytesDelta: 0,
                    diskWriteBytesDelta: 0,
                    pageinsDelta: 0,
                    residentBytes: 80_000_000
                )
            ]
            return s
        }
        let result = ProcessCorrelator().correlate(samples: onlyWriter)
        XCTAssertNil(result.patterns.correlatedWriterReader)
    }
}
