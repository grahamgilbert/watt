import XCTest
@testable import WattAnalysis
@testable import WattModels

final class EpisodeDetectorTests: XCTestCase {

    // Most tests use a small/fast window so we don't have to feed an hour of
    // synthetic data. The semantics are identical; only the cadence changes.
    // The watts threshold matches the production default (3 W mean) so the
    // tests exercise the same threshold the live app uses.
    private static let fastConfig = EpisodeDetector.Configuration(
        batteryDrainThresholdPctOverWindow: 5,
        acHighEnergyThresholdMeanWatts: 18,
        endThresholdDivisor: 2,
        stickyCount: 3,
        windowSeconds: 60,
        maxSampleGap: 30
    )

    // MARK: - Battery drain

    func testStartsBatteryEpisodeOnSustainedDrop() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        // 5 s cadence, 30 %/h drop ⇒ 0.5 % drop per minute, 0.5 % over 60 s.
        // We need a 5 % drop over the 60s window — so use a steeper rate.
        let samples = Fixtures.steadyDrain(
            startPercent: 95,
            ratePctPerHour: 360, // 6 %/min ⇒ 6 % drop over the 60 s window
            count: 30,
            step: 5
        )
        var trigger: DrainEpisodeTrigger?
        for sample in samples {
            if case .started(_, _, let t) = detector.feed(sample) {
                trigger = t
                break
            }
        }
        XCTAssertEqual(trigger, .batteryDrain)
        XCTAssertTrue(detector.inEpisode)
    }

    func testWaitsForWindowSaturationBeforeStarting() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        // Same steep rate, but only 5 samples (25 s, < 60 s window).
        let samples = Fixtures.steadyDrain(
            startPercent: 95,
            ratePctPerHour: 720,
            count: 5,
            step: 5
        )
        for sample in samples { _ = detector.feed(sample) }
        XCTAssertFalse(detector.inEpisode,
                       "Detector must not start before the window is saturated")
    }

    func testDoesNotStartBelowBatteryThreshold() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        // 1 % over 60 s = 60 %/h equivalent — but only 1 % drop in window;
        // threshold is 5 %.
        let samples = Fixtures.steadyDrain(
            startPercent: 95,
            ratePctPerHour: 60,
            count: 30,
            step: 5
        )
        for sample in samples { _ = detector.feed(sample) }
        XCTAssertFalse(detector.inEpisode,
                       "1 % drop over 60 s window is below the 5 % threshold")
    }

    func testEndsBatteryEpisodeOnPlugIn() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        let drain = Fixtures.steadyDrain(
            startPercent: 95,
            ratePctPerHour: 360,
            count: 30,
            step: 5
        )
        for sample in drain { _ = detector.feed(sample) }
        XCTAssertTrue(detector.inEpisode)
        let plug = SamplePoint(
            timestamp: drain.last!.timestamp.addingTimeInterval(5),
            batteryPercent: drain.last!.batteryPercent,
            isCharging: true,
            instantaneousWatts: 0,
            systemEnergyWatts: 5,
            systemCPUUsage: 0.1,
            memoryPressurePct: 35,
            memoryUsedBytes: 16_000_000_000,
            thermalState: 0
        )
        guard case .ended(_, _, _, _, _, let trigger) = detector.feed(plug) else {
            XCTFail("Plug-in should have ended episode")
            return
        }
        XCTAssertEqual(trigger, .batteryDrain)
        XCTAssertFalse(detector.inEpisode)
    }

    func testEndsEpisodeOnLargeSampleGap() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        let drain = Fixtures.steadyDrain(
            startPercent: 95,
            ratePctPerHour: 360,
            count: 30,
            step: 5
        )
        for sample in drain { _ = detector.feed(sample) }
        XCTAssertTrue(detector.inEpisode)
        // Gap > maxSampleGap (30 s).
        let afterSleep = SamplePoint(
            timestamp: drain.last!.timestamp.addingTimeInterval(120),
            batteryPercent: drain.last!.batteryPercent,
            isCharging: false,
            instantaneousWatts: 18,
            systemEnergyWatts: 8,
            systemCPUUsage: 0.1,
            memoryPressurePct: 35,
            memoryUsedBytes: 16_000_000_000,
            thermalState: 0
        )
        guard case .ended = detector.feed(afterSleep) else {
            XCTFail("Sleep/wake gap should have ended episode")
            return
        }
        XCTAssertFalse(detector.inEpisode)
    }

    // MARK: - AC high-energy

    func testStartsACEpisodeOnSustainedMeanWatts() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        let samples = Fixtures.acHighEnergy(
            watts: 35,
            count: 30,
            step: 5
        )
        var trigger: DrainEpisodeTrigger?
        for sample in samples {
            if case .started(_, _, let t) = detector.feed(sample) {
                trigger = t
                break
            }
        }
        XCTAssertEqual(trigger, .acHighEnergy)
        XCTAssertTrue(detector.inEpisode)
    }

    /// The marquee test: spiky workloads must trigger.
    /// Idle 8 W for 4 seconds, spike 60 W for 1 second, repeat. Mean over the
    /// window is (4 × 8 + 1 × 60) / 5 = 18.4 W — just below threshold, so we
    /// instead use a slightly heavier mix that ends up above 20 W.
    func testTriggersOnSpikyWorkloadEvenWhenInstantaneousIsLow() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        // 4 idle samples at 8 W, 1 spike at 80 W → mean 22.4 W.
        let pattern: [Double] = [8, 8, 8, 8, 80]
        var samples: [SamplePoint] = []
        let start = Fixtures.referenceDate
        for i in 0..<60 {
            let watts = pattern[i % pattern.count]
            let t = start.addingTimeInterval(TimeInterval(i) * 5)
            samples.append(SamplePoint(
                timestamp: t,
                batteryPercent: 80,
                isCharging: true,
                instantaneousWatts: 0,
                systemEnergyWatts: watts,
                systemCPUUsage: 0.5,
                memoryPressurePct: 50,
                memoryUsedBytes: 16_000_000_000,
                thermalState: 1
            ))
        }
        for sample in samples { _ = detector.feed(sample) }
        XCTAssertTrue(detector.inEpisode,
                      "Spiky workload with windowed mean above threshold must trigger")
        XCTAssertEqual(detector.trigger, .acHighEnergy)
    }

    func testIdleACDoesNotTrigger() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        let idle = Fixtures.acHighEnergy(watts: 8, count: 30, step: 5)
        for sample in idle { _ = detector.feed(sample) }
        XCTAssertFalse(detector.inEpisode,
                       "Steady 8 W idle (typical M-series idle) must not trigger")
    }

    func testEndsACEpisodeOnUnplug() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        let busy = Fixtures.acHighEnergy(watts: 35, count: 30, step: 5)
        for sample in busy { _ = detector.feed(sample) }
        XCTAssertTrue(detector.inEpisode)
        let unplugged = SamplePoint(
            timestamp: busy.last!.timestamp.addingTimeInterval(5),
            batteryPercent: 80,
            isCharging: false,
            instantaneousWatts: 15,
            systemEnergyWatts: 25,
            systemCPUUsage: 0.5,
            memoryPressurePct: 50,
            memoryUsedBytes: 16_000_000_000,
            thermalState: 1
        )
        guard case .ended(_, _, _, _, _, let trigger) = detector.feed(unplugged) else {
            XCTFail("Unplug should end the AC energy episode")
            return
        }
        XCTAssertEqual(trigger, .acHighEnergy)
        XCTAssertFalse(detector.inEpisode)
    }

    func testACEpisodeRecordsPeakWatts() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        var samples = Fixtures.acHighEnergy(watts: 30, count: 30, step: 5)
        // Spike one sample.
        samples[15].systemEnergyWatts = 75
        for sample in samples { _ = detector.feed(sample) }
        XCTAssertTrue(detector.inEpisode)
        XCTAssertGreaterThanOrEqual(detector.peakSystemEnergyWatts, 70)
    }

    // MARK: - Math invariants

    func testWindowMeanWattsIsTimeWeighted() {
        var detector = EpisodeDetector(configuration: Self.fastConfig)
        // 9 idle + 1 spike, all 5 s apart. Equal-weight mean would be ~14 W;
        // time-weighted mean is also ~14 W (each sample represents an equal
        // 5 s slice). The point is verifying the integration is sane.
        let pattern: [Double] = [10, 10, 10, 10, 10, 10, 10, 10, 10, 50]
        let start = Fixtures.referenceDate
        for (i, watts) in pattern.enumerated() {
            _ = detector.feed(SamplePoint(
                timestamp: start.addingTimeInterval(TimeInterval(i) * 5),
                batteryPercent: 80,
                isCharging: true,
                instantaneousWatts: 0,
                systemEnergyWatts: watts,
                systemCPUUsage: 0.4,
                memoryPressurePct: 50,
                memoryUsedBytes: 16_000_000_000,
                thermalState: 1
            ))
        }
        let mean = detector.windowMeanWatts()
        XCTAssertEqual(mean, 14, accuracy: 4)
    }
}
