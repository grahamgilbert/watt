import XCTest
@testable import WattAnalysis
@testable import WattModels
@testable import WattSampling

/// "Smoke" tests for the live samplers — they hit real OS APIs, so we only
/// assert the calls succeed and return plausible-looking values. These run on
/// CI on macOS runners.
final class SamplerSmokeTests: XCTestCase {
    func testBatterySamplerReturnsAtMostOneReading() async {
        let reading = await BatterySampler().read()
        // On a desktop / CI runner, batteryPercent will be NaN; that's fine.
        // The contract is just "doesn't crash and the bool defaults are sane".
        if !reading.batteryPercent.isNaN {
            XCTAssertGreaterThanOrEqual(reading.batteryPercent, 0)
            XCTAssertLessThanOrEqual(reading.batteryPercent, 100)
        }
        XCTAssertGreaterThanOrEqual(reading.instantaneousWatts, 0)
    }

    func testHostStatsReturnsPlausibleValues() async {
        let sampler = HostStatsSampler()
        // First call seeds the deltas — second call gives real CPU figures.
        _ = await sampler.read()
        try? await Task.sleep(for: .milliseconds(100))
        let r = await sampler.read()
        XCTAssertGreaterThanOrEqual(r.systemCPUUsage, 0)
        XCTAssertLessThanOrEqual(r.systemCPUUsage, 1.0001)
        XCTAssertGreaterThanOrEqual(r.memoryPressurePct, 0)
        XCTAssertLessThanOrEqual(r.memoryPressurePct, 100.001)
        XCTAssertGreaterThan(r.memoryUsedBytes, 0)
    }

    func testThermalReadingIsInRange() async {
        let r = await ThermalSampler().read()
        XCTAssertGreaterThanOrEqual(r.rawValue, 0)
        XCTAssertLessThanOrEqual(r.rawValue, 3)
    }

    func testProcSamplerProducesProcessesAfterSeeding() async {
        let sampler = ProcSampler()
        _ = await sampler.read()           // seed
        try? await Task.sleep(for: .milliseconds(200))
        let r = await sampler.read()
        // We should observe at least *some* processes alive across two reads
        // on any reasonable Mac (loginwindow, launchd, this test runner).
        XCTAssertFalse(r.processes.isEmpty)
        // No negative deltas should leak (we clamp cpuTimeDelta).
        for proc in r.processes {
            XCTAssertGreaterThanOrEqual(proc.cpuTimeDelta, 0)
        }
    }

    func testAppleSensorsSamplerDoesNotCrash() async {
        // On Apple Silicon we expect at least one fan or temp on a real Mac.
        // On CI VMs (no sensor hardware) the result is empty — both cases must
        // simply not crash.
        let r = await AppleSensorsSampler().read()
        for v in r.fanRPM {
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 20_000)
        }
        for (_, c) in r.temperatures {
            XCTAssertGreaterThan(c, -50)
            XCTAssertLessThan(c, 200)
        }
    }
}
