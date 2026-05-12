import XCTest
@testable import WattAnalysis
@testable import WattModels

final class TimelineBuilderTests: XCTestCase {
    func testTimelineInterleavesUserActionsWithDerivedEvents() {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 20)
        let processed = drain.enumerated().map { i, sample -> SamplePoint in
            var s = sample
            s.thermalState = i < 5 ? 0 : 2
            s.fanRPM = [Double(2000 + 200 * i)]
            s.temperatures = ["pACC MTR Temp Sensor0": Double(70 + i)]
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 250 * 1024 * 1024
            )
            return s
        }
        let events = [
            UserEventPoint(
                timestamp: drain[1].timestamp,
                kind: .powerUnplugged,
                detail: nil
            ),
            UserEventPoint(
                timestamp: drain[3].timestamp,
                kind: .appActivated,
                appName: "Claude",
                detail: nil
            ),
            UserEventPoint(
                timestamp: drain[15].timestamp,
                kind: .userNote,
                detail: "Started a Zoom call"
            )
        ]
        let suspects = ProcessCorrelator().correlate(samples: processed).suspects
        let entries = TimelineBuilder.build(samples: processed, events: events, suspects: suspects)
        XCTAssertFalse(entries.isEmpty)
        let kinds = entries.map(\.kind)
        XCTAssertTrue(kinds.contains(.userAction))
        XCTAssertTrue(kinds.contains(.systemTransition))
        XCTAssertTrue(kinds.contains(.processOnset))
        XCTAssertTrue(kinds.contains(.samplePeak))

        // Ensure entries are sorted by timestamp ascending.
        XCTAssertEqual(entries.sorted(by: { $0.timestamp < $1.timestamp }).map(\.timestamp),
                       entries.map(\.timestamp))

        // The unplug user action should appear with battery aside.
        let unplug = entries.first(where: { $0.oneLine.contains("Unplugged") })
        XCTAssertNotNil(unplug)
        XCTAssertTrue(unplug!.oneLine.contains("Battery"))

        // The user note should appear verbatim.
        XCTAssertTrue(entries.contains { $0.oneLine.contains("Started a Zoom call") })
    }

    func testTimelineCapsAtMaxEntriesPreservingHighPriority() {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 200)
        let user = [
            UserEventPoint(timestamp: drain[10].timestamp, kind: .powerUnplugged),
            UserEventPoint(timestamp: drain[100].timestamp, kind: .appActivated, appName: "Cursor")
        ]
        let entries = TimelineBuilder.build(
            samples: drain,
            events: user,
            suspects: [],
            configuration: .init(maxEntries: 8)
        )
        XCTAssertLessThanOrEqual(entries.count, 8)
        // Both user actions must survive the cap.
        XCTAssertTrue(entries.contains { $0.oneLine.contains("Unplugged") })
        XCTAssertTrue(entries.contains { $0.oneLine.contains("Cursor") })
    }
}
