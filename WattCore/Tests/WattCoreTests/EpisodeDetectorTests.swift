import XCTest
@testable import WattAnalysis
@testable import WattModels

final class EpisodeDetectorTests: XCTestCase {
    func testNoEpisodeWhilePluggedInEvenAtHighDrain() {
        var detector = EpisodeDetector()
        let pluggedDrain = Fixtures.samples(count: 20) { i, t in
            SamplePoint(
                timestamp: t,
                batteryPercent: 100 - Double(i),
                isCharging: true,
                instantaneousWatts: -40,
                systemCPUUsage: 0.5,
                memoryPressurePct: 50,
                memoryUsedBytes: 16_000_000_000,
                thermalState: 1
            )
        }
        let events = pluggedDrain.map { detector.feed($0) }
        XCTAssertFalse(detector.inEpisode)
        XCTAssertTrue(events.allSatisfy { $0 == .noChange })
    }

    func testStartsEpisodeWhenSustainedDrainExceedsThreshold() {
        var detector = EpisodeDetector()
        let drain = Fixtures.steadyDrain(startPercent: 95, ratePctPerHour: 30, count: 30)
        var startedAt: Date?
        for sample in drain {
            if case .started(let at, _) = detector.feed(sample) {
                startedAt = at
                break
            }
        }
        XCTAssertNotNil(startedAt, "Detector should have flagged a 30 %/h drain as an episode")
        XCTAssertTrue(detector.inEpisode)
    }

    func testDoesNotStartBelowThreshold() {
        var detector = EpisodeDetector()
        let drain = Fixtures.steadyDrain(startPercent: 95, ratePctPerHour: 6, count: 30)
        for sample in drain { _ = detector.feed(sample) }
        XCTAssertFalse(detector.inEpisode,
                       "6 %/h is below the default 12 %/h threshold and should not trigger")
    }

    func testStickyCountAvoidsTriggerOnSingleHighSample() {
        var detector = EpisodeDetector(configuration: .init(stickyCount: 3))
        // Exactly two high-drain samples, then drop back to a calm rate.
        // We need to feed at least `windowSize` total samples for the slope to
        // be meaningful, and verify the detector doesn't trip.
        let baseline = Fixtures.steadyDrain(startPercent: 95, ratePctPerHour: 4, count: 4)
        let bumpStart = baseline.last!.timestamp.addingTimeInterval(30)
        let bump = (0..<2).map { i in
            SamplePoint(
                timestamp: bumpStart.addingTimeInterval(TimeInterval(i) * 30),
                batteryPercent: baseline.last!.batteryPercent - Double(i + 1) * 0.05,
                isCharging: false,
                instantaneousWatts: 30,
                systemCPUUsage: 0.7,
                memoryPressurePct: 65,
                memoryUsedBytes: 16_000_000_000,
                thermalState: 1
            )
        }
        for sample in baseline + bump { _ = detector.feed(sample) }
        XCTAssertFalse(detector.inEpisode,
                       "2 samples is below stickyCount=3 — should not start an episode")
    }

    func testEndsEpisodeOnPlugIn() {
        var detector = EpisodeDetector()
        let drain = Fixtures.steadyDrain(startPercent: 90, ratePctPerHour: 30, count: 20)
        for sample in drain { _ = detector.feed(sample) }
        XCTAssertTrue(detector.inEpisode)
        let plug = SamplePoint(
            timestamp: drain.last!.timestamp.addingTimeInterval(30),
            batteryPercent: drain.last!.batteryPercent,
            isCharging: true,
            instantaneousWatts: -40,
            systemCPUUsage: 0.2,
            memoryPressurePct: 40,
            memoryUsedBytes: 16_000_000_000,
            thermalState: 1
        )
        let event = detector.feed(plug)
        if case .ended = event {
            XCTAssertFalse(detector.inEpisode)
        } else {
            XCTFail("Plug-in should have ended episode, got \(event)")
        }
    }

    func testEndsEpisodeOnLargeSampleGap() {
        var detector = EpisodeDetector()
        let drain = Fixtures.steadyDrain(startPercent: 90, ratePctPerHour: 30, count: 20)
        for sample in drain { _ = detector.feed(sample) }
        XCTAssertTrue(detector.inEpisode)
        // Five-minute gap (sleep/wake)
        let afterSleep = SamplePoint(
            timestamp: drain.last!.timestamp.addingTimeInterval(300),
            batteryPercent: drain.last!.batteryPercent,
            isCharging: false,
            instantaneousWatts: 18,
            systemCPUUsage: 0.1,
            memoryPressurePct: 35,
            memoryUsedBytes: 16_000_000_000,
            thermalState: 0
        )
        let event = detector.feed(afterSleep)
        if case .ended = event {
            XCTAssertFalse(detector.inEpisode)
        } else {
            XCTFail("Sleep/wake gap should have ended episode")
        }
    }

    func testDrainRateMagnitudeRoughlyMatchesGenerator() {
        var detector = EpisodeDetector()
        let drain = Fixtures.steadyDrain(startPercent: 90, ratePctPerHour: 25, count: 20)
        for sample in drain { _ = detector.feed(sample) }
        let measured = detector.currentDrainRatePctPerHour()
        XCTAssertEqual(measured, 25, accuracy: 0.5)
    }
}
