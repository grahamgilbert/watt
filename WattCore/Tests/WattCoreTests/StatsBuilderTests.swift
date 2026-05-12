import XCTest
@testable import WattAnalysis
@testable import WattModels

final class StatsBuilderTests: XCTestCase {
    func testStatsCaptureBasicShape() {
        let drain = Fixtures.steadyDrain(
            startPercent: 96,
            ratePctPerHour: 48,
            count: 30,
            cpu: 0.6,
            memory: 60
        )
        let stats = StatsBuilder.build(samples: drain)
        XCTAssertEqual(stats.startPercent, 96, accuracy: 0.001)
        XCTAssertEqual(stats.endPercent, drain.last!.batteryPercent, accuracy: 0.001)
        XCTAssertEqual(stats.drainPercent, 96 - drain.last!.batteryPercent, accuracy: 0.001)
        XCTAssertEqual(stats.peakDrainRatePctPerHour, 48, accuracy: 4)
        XCTAssertEqual(stats.meanCPUUsage, 0.6, accuracy: 0.0001)
        XCTAssertEqual(stats.meanMemoryPressurePct, 60, accuracy: 0.0001)
    }

    func testHottestSensorSurfacesCorrectKey() {
        var samples = Fixtures.steadyDrain(startPercent: 90, ratePctPerHour: 20, count: 5)
        samples = samples.enumerated().map { i, sample in
            var s = sample
            s.temperatures = [
                "pACC MTR Temp Sensor0": Double(70 + i),
                "eACC MTR Temp Sensor0": Double(50 + i)
            ]
            s.fanRPM = [Double(2000 + 800 * i)]
            return s
        }
        let stats = StatsBuilder.build(samples: samples)
        XCTAssertEqual(stats.hottestSensorName, "pACC MTR Temp Sensor0")
        XCTAssertEqual(stats.hottestSensorCelsius ?? 0, 74, accuracy: 0.001)
        XCTAssertEqual(stats.maxFanRPM, 2000 + 800 * 4, accuracy: 0.001)
    }

    func testThermalSummaryReportsTransitions() {
        var samples = Fixtures.steadyDrain(startPercent: 90, ratePctPerHour: 20, count: 10)
        samples = samples.enumerated().map { i, sample in
            var s = sample
            s.thermalState = i < 3 ? 0 : (i < 8 ? 2 : 1)
            return s
        }
        let stats = StatsBuilder.build(samples: samples)
        XCTAssertEqual(stats.thermalSummary, "nominal → peak serious → fair")
    }
}
