import XCTest
import SwiftData
@testable import WattAnalysis
@testable import WattModels
@testable import WattSampling

final class SamplingWriterTests: XCTestCase {
    func testWriteAndReloadSamples() async throws {
        let container = try WattStore.makeContainer(inMemory: true)
        let writer = SamplingWriter(modelContainer: container)
        let baseDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 5, start: baseDate)
        for sample in drain {
            var s = sample
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 100 * 1024 * 1024,
                readBytes: 100 * 1024 * 1024
            )
            try await writer.writeSample(point: s)
        }
        let reloaded = try await writer.loadSamplePoints(in: baseDate ... baseDate.addingTimeInterval(60 * 5))
        XCTAssertEqual(reloaded.count, 5)
        XCTAssertEqual(reloaded.first?.processes.count, 3)
    }

    func testEpisodeLifecycleRoundTrip() async throws {
        let container = try WattStore.makeContainer(inMemory: true)
        let writer = SamplingWriter(modelContainer: container)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let id = try await writer.writeEpisode(start: start, startPercent: 96)
        try await writer.updateEpisode(
            id: id,
            endedAt: start.addingTimeInterval(600),
            endPercent: 49,
            peakDrainRate: 64,
            avgThermalState: 2
        )
        let report = Report(
            generatedAt: Date(),
            headline: "Test headline",
            markdown: "# Test\n",
            generatedByLLM: false
        )
        try await writer.writeReport(report, attachingTo: id)
    }

    func testUserEventPersistsAndReloads() async throws {
        let container = try WattStore.makeContainer(inMemory: true)
        let writer = SamplingWriter(modelContainer: container)
        let now = Date()
        try await writer.writeUserEvent(UserEventPoint(
            timestamp: now,
            kind: .userNote,
            detail: "test note"
        ))
        let events = try await writer.loadUserEventPoints(in: now.addingTimeInterval(-1) ... now.addingTimeInterval(1))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.detail, "test note")
        XCTAssertEqual(events.first?.kind, .userNote)
    }
}
