import Foundation
import XCTest
@testable import WattAnalysis
@testable import WattModels

/// Replays a captured stress-test session through `EpisodeDetector` with
/// production defaults. Used to diagnose why a real workload that "should"
/// trigger an episode didn't. The fixture comes from a real
/// `~/Library/Application Support/Watt/store.sqlite` dump — see comments at
/// the bottom of this file for how to refresh it.
final class StressReplayTests: XCTestCase {
    struct LiveSample: Decodable {
        let timestamp: Double            // CFAbsoluteTime (seconds since 2001-01-01)
        let batteryPercent: Double
        let isCharging: Int
        let instantaneousWatts: Double
        let systemEnergyWatts: Double
        let systemCPUUsage: Double
        let memoryPressurePct: Double
        let memoryUsedBytes: UInt64
        let thermalState: Int
        let fsEventsRate: Double
    }

    func testReplayCapturedStressSession() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "live-2026-05-12-stress", withExtension: "json"),
            "Fixture missing"
        )
        let data = try Data(contentsOf: url)
        let samples = try JSONDecoder().decode([LiveSample].self, from: data)
        XCTAssertGreaterThan(samples.count, 100, "Need a substantial sample to replay")

        var detector = EpisodeDetector()  // production defaults
        var startedAt: Date?
        var startedTrigger: DrainEpisodeTrigger?
        var firstSaturatedAt: Date?
        var saturatedReadings: [(Date, drop: Double, mean: Double, charging: Bool)] = []

        for s in samples {
            let point = SamplePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: s.timestamp),
                batteryPercent: s.batteryPercent,
                isCharging: s.isCharging != 0,
                instantaneousWatts: s.instantaneousWatts,
                systemEnergyWatts: s.systemEnergyWatts,
                systemCPUUsage: s.systemCPUUsage,
                memoryPressurePct: s.memoryPressurePct,
                memoryUsedBytes: s.memoryUsedBytes,
                thermalState: s.thermalState,
                fanRPM: [],
                temperatures: [:],
                fsEventsRate: s.fsEventsRate
            )

            let event = detector.feed(point)

            if detector.windowIsSaturated(), firstSaturatedAt == nil {
                firstSaturatedAt = point.timestamp
            }
            if detector.windowIsSaturated() {
                saturatedReadings.append((
                    point.timestamp,
                    drop: detector.windowDrainPctTotal(),
                    mean: detector.windowMeanWatts(),
                    charging: point.isCharging
                ))
            }
            if case .started(let at, _, let trigger) = event {
                startedAt = at
                startedTrigger = trigger
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current

        print("=== StressReplay summary ===")
        print("Total samples:           \(samples.count)")
        if let f = samples.first, let l = samples.last {
            let span = l.timestamp - f.timestamp
            print("Time span:               \(Int(span)) s")
            print("Battery:                 \(f.batteryPercent)% -> \(l.batteryPercent)% (drop = \(f.batteryPercent - l.batteryPercent)%)")
            print("Charging samples:        \(samples.filter { $0.isCharging != 0 }.count) / \(samples.count)")
        }
        print("Window saturated at:     \(firstSaturatedAt.map { formatter.string(from: $0) } ?? "NEVER")")
        print("Saturated reading count: \(saturatedReadings.count)")

        if !saturatedReadings.isEmpty {
            // Print every 20th saturated reading so we can see the trajectory.
            print("\n--- Saturated readings (every 20th) ---")
            print("time       drop%   mean_watts  charging")
            for (i, r) in saturatedReadings.enumerated() where i % 20 == 0 || i == saturatedReadings.count - 1 {
                print(String(format: "%@   %5.2f   %6.2f      %@",
                             formatter.string(from: r.0),
                             r.drop,
                             r.mean,
                             r.charging ? "yes" : "no"))
            }

            let maxDrop = saturatedReadings.map(\.drop).max() ?? 0
            let maxMean = saturatedReadings.map(\.mean).max() ?? 0
            print("\nPeak windowed drop:      \(maxDrop)%")
            print("Peak windowed mean watts: \(maxMean) W")
        }

        print("\n--- Detector outcome ---")
        if let at = startedAt {
            print("EPISODE STARTED at \(formatter.string(from: at)) — trigger=\(startedTrigger ?? .batteryDrain)")
        } else {
            print("NO EPISODE FIRED")
        }

        // Sanity check we won't silently regress: if production thresholds
        // (5% drop, 18W mean) didn't fire on a session with this much
        // battery drop and this much wattage, something is wrong.
        if let first = samples.first, let last = samples.last,
           first.batteryPercent - last.batteryPercent >= 5,
           samples.contains(where: { $0.systemEnergyWatts >= 18 }) {
            XCTAssertNotNil(
                startedAt,
                "Replay shows >5% battery drop AND >18W samples but the detector didn't trigger. See printed window readings above."
            )
        }
    }
}

/* Refresh the fixture by running:
 *
 *   sqlite3 ~/Library/Application\ Support/Watt/store.sqlite <<'SQL' \
 *     > WattCore/Tests/WattCoreTests/Fixtures/live-2026-05-12-stress.json
 *   .mode json
 *   SELECT
 *     ZTIMESTAMP AS timestamp,
 *     ZBATTERYPERCENT AS batteryPercent,
 *     CASE WHEN ZISCHARGING = 1 THEN 1 ELSE 0 END AS isCharging,
 *     ZINSTANTANEOUSWATTS AS instantaneousWatts,
 *     ZSYSTEMENERGYWATTS AS systemEnergyWatts,
 *     ZSYSTEMCPUUSAGE AS systemCPUUsage,
 *     ZMEMORYPRESSUREPCT AS memoryPressurePct,
 *     ZMEMORYUSEDBYTES AS memoryUsedBytes,
 *     ZTHERMALSTATE AS thermalState,
 *     ZFSEVENTSRATE AS fsEventsRate
 *   FROM ZSAMPLE
 *   ORDER BY ZTIMESTAMP;
 *   SQL
 */
