import XCTest
@testable import WattAnalysis
@testable import WattModels
@testable import WattSampling

// MARK: - Merge logic tests (no MainActor required)

final class MergeProcessReadingsTests: XCTestCase {

    private func makePoint(
        pid: Int32,
        name: String,
        bundleID: String? = nil,
        executablePath: String? = nil,
        cpuDelta: Double = 0,
        energyDelta: UInt64 = 0,
        readDelta: UInt64 = 0,
        writeDelta: UInt64 = 0,
        energyImpact: Double = 0
    ) -> ProcessPoint {
        ProcessPoint(
            pid: pid, name: name, bundleID: bundleID, executablePath: executablePath,
            cpuTimeDelta: cpuDelta,
            energyNanojoulesDelta: energyDelta,
            billedEnergyDelta: 0,
            diskReadBytesDelta: readDelta,
            diskWriteBytesDelta: writeDelta,
            pageinsDelta: 0,
            residentBytes: 0,
            energyImpact: energyImpact
        )
    }

    func testHelperDataWinsWhenUnprivilegedIsAllZero() {
        // Simulates CrowdStrike Falcon: unprivileged sampler sees the pid but
        // gets EPERM from proc_pid_rusage → emits all-zero deltas.
        // Helper runs as root and has real deltas.
        let helperPoint = makePoint(
            pid: 579,
            name: "com.crowdstrike.falcon.Agent",
            executablePath: "/Library/SystemExtensions/UUID/com.crowdstrike.falcon.Agent.systemextension/Contents/MacOS/com.crowdstrike.falcon.Agent",
            cpuDelta: 2.5,
            energyDelta: 1_000_000_000,
            readDelta: 500_000_000
        )
        let unprivPoint = makePoint(pid: 579, name: "com.crowdstrike.falcon.Agent")  // all-zero

        let merged = _mergeProcessReadings(unprivileged: [unprivPoint], helper: [helperPoint])

        let result = merged.first { $0.pid == 579 }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.cpuTimeDelta, 2.5, "Helper's real CPU delta must survive merge")
        XCTAssertEqual(result?.energyNanojoulesDelta, 1_000_000_000, "Helper's real energy delta must survive merge")
        XCTAssertEqual(result?.diskReadBytesDelta, 500_000_000, "Helper's real read delta must survive merge")
    }

    func testUnprivilegedWinsWhenItHasRealData() {
        // Unprivileged sampler owns the process (user-owned, not root) and has
        // real deltas plus a bundleID from NSRunningApplication.
        let helperPoint = makePoint(pid: 1234, name: "claude", cpuDelta: 1.0, energyDelta: 500_000_000)
        let unprivPoint = makePoint(
            pid: 1234, name: "claude",
            bundleID: "com.anthropic.claude",
            cpuDelta: 1.2,
            energyDelta: 520_000_000
        )

        let merged = _mergeProcessReadings(unprivileged: [unprivPoint], helper: [helperPoint])

        let result = merged.first { $0.pid == 1234 }
        XCTAssertEqual(result?.bundleID, "com.anthropic.claude", "Unprivileged bundleID must win")
        XCTAssertEqual(result?.cpuTimeDelta, 1.2, "Unprivileged CPU delta must win when it has real data")
    }

    func testHelperOnlyPidSurfaces() {
        // pid visible only to helper (root-owned, not enumerable by unprivileged sampler)
        let helperPoint = makePoint(pid: 999, name: "secret-daemon", cpuDelta: 0.5)
        let merged = _mergeProcessReadings(unprivileged: [], helper: [helperPoint])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].pid, 999)
    }

    func testUnprivilegedOnlyPidSurfaces() {
        // pid visible only to unprivileged sampler (helper didn't return it)
        let unprivPoint = makePoint(pid: 777, name: "my-app", cpuDelta: 0.1)
        let merged = _mergeProcessReadings(unprivileged: [unprivPoint], helper: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].pid, 777)
    }

    func testZeroUnprivilegedWithNoHelperRecordKept() {
        // pid exists but neither sampler has real data — keep the stub so the
        // process appears in the list (it's still running)
        let unprivZero = makePoint(pid: 888, name: "idle-daemon")
        let merged = _mergeProcessReadings(unprivileged: [unprivZero], helper: [])
        XCTAssertEqual(merged.count, 1, "Zero-delta stub must be kept when no helper record exists")
    }

    func testMultiplePidsMergeCorrectly() {
        // Three pids: one user-owned (unprivileged wins), one root-owned (helper
        // wins), one helper-only.
        let helperFalcon = makePoint(pid: 579, name: "falcon", cpuDelta: 3.0, energyDelta: 2_000_000_000)
        let helperOnlyDaemon = makePoint(pid: 400, name: "hidden-daemon", cpuDelta: 0.2)
        let unprivFalconZero = makePoint(pid: 579, name: "falcon")  // EPERM stub
        let unprivUserApp = makePoint(pid: 1000, name: "my-app", bundleID: "com.example.app", cpuDelta: 1.0)

        let merged = _mergeProcessReadings(
            unprivileged: [unprivFalconZero, unprivUserApp],
            helper: [helperFalcon, helperOnlyDaemon]
        )

        XCTAssertEqual(merged.count, 3)
        let falcon = merged.first { $0.pid == 579 }
        XCTAssertEqual(falcon?.cpuTimeDelta, 3.0, "Falcon: helper data must win over zero stub")
        let app = merged.first { $0.pid == 1000 }
        XCTAssertEqual(app?.bundleID, "com.example.app", "User app: unprivileged bundleID must be kept")
        XCTAssertTrue(merged.contains { $0.pid == 400 }, "Helper-only daemon must appear")
    }

    func testEnergyImpactNonZeroCountsAsHavingData() {
        // Even if all rusage fields are zero, a non-zero energyImpact from
        // powermetrics means the unprivileged reading has real data.
        let helperPoint = makePoint(pid: 100, name: "proc", cpuDelta: 1.0)
        let unprivPoint = makePoint(pid: 100, name: "proc", bundleID: "com.example", energyImpact: 42.0)

        let merged = _mergeProcessReadings(unprivileged: [unprivPoint], helper: [helperPoint])
        let result = merged.first { $0.pid == 100 }
        XCTAssertEqual(result?.bundleID, "com.example", "energyImpact > 0 means unprivileged reading wins")
    }
}

// MARK: - SamplingCoordinator integration tests

@MainActor
final class SamplingCoordinatorTests: XCTestCase {
    func testTickOncePopulatesSnapshotAndPersistsSample() async throws {
        let container = try WattStore.makeContainer(inMemory: true)
        let writer = SamplingWriter(modelContainer: container)
        let coordinator = SamplingCoordinator(writer: writer)
        // Don't actually start the periodic Task — drive it manually.
        await coordinator.tickOnce()
        XCTAssertNotNil(coordinator.snapshot.lastTick, "tickOnce should populate lastTick")
        XCTAssertGreaterThanOrEqual(coordinator.snapshot.systemCPUUsage, 0)
        XCTAssertLessThanOrEqual(coordinator.snapshot.systemCPUUsage, 1.0001)
    }

    func testRecordUserNoteWritesEvent() async throws {
        let container = try WattStore.makeContainer(inMemory: true)
        let writer = SamplingWriter(modelContainer: container)
        let coordinator = SamplingCoordinator(writer: writer)
        coordinator.recordUserNote("ran a build")
        // Give the background Task time to settle.
        try? await Task.sleep(for: .milliseconds(150))
        let events = try await writer.loadUserEventPoints(in: Date.distantPast ... Date.distantFuture)
        XCTAssertTrue(events.contains { $0.detail == "ran a build" && $0.kind == .userNote })
    }
}
