import XCTest
@testable import WattAnalysis
@testable import WattModels
@testable import WattSampling

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
