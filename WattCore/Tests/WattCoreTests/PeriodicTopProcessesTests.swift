import XCTest
@testable import WattAnalysis
@testable import WattModels

final class PeriodicTopProcessesTests: XCTestCase {
    func testProducesRequestedNumberOfBuckets() {
        let drain = Fixtures.steadyDrain(startPercent: 95, ratePctPerHour: 30, count: 60, step: 10)
        let processed = drain.map { sample -> SamplePoint in
            var s = sample
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 50 * 1024 * 1024,
                readBytes: 60 * 1024 * 1024
            )
            return s
        }
        let buckets = PeriodicTopProcesses.compute(samples: processed, configuration: .init(bucketCount: 4, topN: 3))
        XCTAssertEqual(buckets.count, 4)
        for b in buckets {
            XCTAssertGreaterThan(b.entries.count, 0)
        }
    }

    func testSecurityAgentAlwaysIncludedEvenIfBelowTopN() {
        let drain = Fixtures.steadyDrain(startPercent: 95, ratePctPerHour: 30, count: 30, step: 10)
        // Three loud processes plus one quiet Falcon agent. Top-2 would
        // miss Falcon by score but it should still be included.
        let processed = drain.map { sample -> SamplePoint in
            var s = sample
            s.processes = [
                ProcessPoint(
                    pid: 100, name: "loud-a", bundleID: nil,
                    cpuTimeDelta: 5, energyNanojoulesDelta: 5_000_000_000,
                    billedEnergyDelta: 0,
                    diskReadBytesDelta: 0, diskWriteBytesDelta: 0,
                    pageinsDelta: 0, residentBytes: 0
                ),
                ProcessPoint(
                    pid: 101, name: "loud-b", bundleID: nil,
                    cpuTimeDelta: 4, energyNanojoulesDelta: 4_000_000_000,
                    billedEnergyDelta: 0,
                    diskReadBytesDelta: 0, diskWriteBytesDelta: 0,
                    pageinsDelta: 0, residentBytes: 0
                ),
                ProcessPoint(
                    pid: 102, name: "loud-c", bundleID: nil,
                    cpuTimeDelta: 3, energyNanojoulesDelta: 3_000_000_000,
                    billedEnergyDelta: 0,
                    diskReadBytesDelta: 0, diskWriteBytesDelta: 0,
                    pageinsDelta: 0, residentBytes: 0
                ),
                ProcessPoint(
                    pid: 412, name: "falconctl", bundleID: "com.crowdstrike.falcon.Agent",
                    cpuTimeDelta: 0.1, energyNanojoulesDelta: 50_000_000,
                    billedEnergyDelta: 0,
                    diskReadBytesDelta: 1_000_000, diskWriteBytesDelta: 0,
                    pageinsDelta: 0, residentBytes: 0
                )
            ]
            return s
        }
        let buckets = PeriodicTopProcesses.compute(samples: processed, configuration: .init(bucketCount: 1, topN: 2))
        XCTAssertEqual(buckets.count, 1)
        XCTAssertTrue(
            buckets[0].entries.contains { $0.name == "falconctl" && $0.isSecurityAgent },
            "Security agent must be included even when below top-N"
        )
    }
}
