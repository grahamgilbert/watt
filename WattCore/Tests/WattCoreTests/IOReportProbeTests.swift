import XCTest
@testable import WattSampling
import WattSamplingC

/// Live probe: opens IOReport, seeds it, sleeps, samples, prints what it
/// got. Disabled by default; run with `swift test --filter IOReportProbeTests`
/// to print real numbers from the host machine.
final class IOReportProbeTests: XCTestCase {
    func testProbeIOReport() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WATT_PROBE_IOREPORT"] == "1",
            "Set WATT_PROBE_IOREPORT=1 to run the live IOReport probe."
        )

        let openResult = watt_ioreport_open()
        print("watt_ioreport_open: \(openResult)")
        XCTAssertEqual(openResult, 0, "IOReport failed to open")

        var sample = watt_power_sample_t()
        _ = watt_ioreport_sample(&sample)   // seed
        try await Task.sleep(for: .seconds(2))
        _ = watt_ioreport_sample(&sample)   // measure

        print(String(format: "elapsed: %.2f s", sample.elapsed_seconds))
        print(String(format: "  total: %.2f W", sample.total_watts))
        print(String(format: "  cpu:   %.2f W", sample.cpu_watts))
        print(String(format: "  gpu:   %.2f W", sample.gpu_watts))
        print(String(format: "  ane:   %.2f W", sample.ane_watts))
        print(String(format: "  dram:  %.2f W", sample.dram_watts))

        watt_ioreport_close()

        XCTAssertGreaterThan(sample.elapsed_seconds, 1.0, "elapsed should be ~2s")
    }
}
