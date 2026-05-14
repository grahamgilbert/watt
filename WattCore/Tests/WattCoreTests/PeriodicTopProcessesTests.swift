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

    func testTopNRankingExcludesLowScoreProcess() {
        let drain = Fixtures.steadyDrain(startPercent: 95, ratePctPerHour: 30, count: 30, step: 10)
        // Three loud processes plus one very quiet process. With topN=2 the
        // quiet process must NOT appear unless it's a system-managed daemon.
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
                    pid: 102, name: "quiet-xyz-process", bundleID: nil,
                    cpuTimeDelta: 0.01, energyNanojoulesDelta: 10_000,
                    billedEnergyDelta: 0,
                    diskReadBytesDelta: 0, diskWriteBytesDelta: 0,
                    pageinsDelta: 0, residentBytes: 0
                )
            ]
            return s
        }
        let buckets = PeriodicTopProcesses.compute(samples: processed, configuration: .init(bucketCount: 1, topN: 2))
        XCTAssertEqual(buckets.count, 1)
        // loud-a and loud-b should be in the top-2; quiet-xyz should not be
        // (it's not system-managed and scored too low).
        XCTAssertTrue(buckets[0].entries.contains { $0.pid == 100 }, "loud-a must be in top-2")
        XCTAssertTrue(buckets[0].entries.contains { $0.pid == 101 }, "loud-b must be in top-2")
        XCTAssertFalse(buckets[0].entries.contains { $0.pid == 102 }, "quiet-xyz must not appear in top-2")
    }

    func testSystemManagedDaemonAlwaysIncludedEvenIfBelowTopN() throws {
        // Find a real system-managed path that exists on this host.
        // If none are present, skip rather than fail — CI machines may vary.
        let services = SystemServiceRegistry.services()
        guard let realService = services.first(where: { !$0.executablePaths.isEmpty }) else {
            throw XCTSkip("No system-managed services with executable paths found on this host")
        }
        let realPath = realService.executablePaths[0]

        let drain = Fixtures.steadyDrain(startPercent: 95, ratePctPerHour: 30, count: 30, step: 10)
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
                    pid: 999, name: "quiet-daemon", bundleID: nil,
                    executablePath: realPath,
                    cpuTimeDelta: 0.01, energyNanojoulesDelta: 10_000,
                    billedEnergyDelta: 0,
                    diskReadBytesDelta: 0, diskWriteBytesDelta: 0,
                    pageinsDelta: 0, residentBytes: 0
                )
            ]
            return s
        }
        let buckets = PeriodicTopProcesses.compute(samples: processed, configuration: .init(bucketCount: 1, topN: 2))
        XCTAssertEqual(buckets.count, 1)
        XCTAssertTrue(
            buckets[0].entries.contains { $0.pid == 999 && $0.isSystemManaged },
            "System-managed daemon must be included even when below top-N"
        )
    }
}
