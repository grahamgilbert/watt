import Foundation
import SwiftData
import XCTest
@testable import WattAnalysis
@testable import WattModels

/// Replays live samples from a real `~/Library/Application Support/Watt/store.sqlite`
/// through `EpisodeDetector` so we can debug why an automatic episode didn't
/// fire. Skipped unless `WATT_REPLAY_LIVE=1` is set.
final class ReplayLiveDataTests: XCTestCase {
    func testReplayLiveStore() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WATT_REPLAY_LIVE"] == "1",
            "Set WATT_REPLAY_LIVE=1 to replay the live SQLite store."
        )

        let storeURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Watt/store.sqlite")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: storeURL.path),
                          "No live store at \(storeURL.path)")

        let container = try ModelContainer(
            for: WattStore.schema,
            configurations: [ModelConfiguration(url: storeURL, allowsSave: false)]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Sample>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let samples = try context.fetch(descriptor)
        print("Loaded \(samples.count) samples")
        guard !samples.isEmpty else { return }

        var detector = EpisodeDetector()  // production defaults
        var startedAt: Date?
        var lastWindowSummary: (mean: Double, drop: Double, saturated: Bool, ts: Date)?

        for s in samples {
            let point = SamplePoint.from(s)
            let event = detector.feed(point)
            if case .started(let at, _, let trigger) = event {
                print("EPISODE STARTED at \(at) trigger=\(trigger)")
                startedAt = at
            }
            // Snapshot once per ~30 samples
            if Int.random(in: 0..<30) == 0 || s == samples.last {
                lastWindowSummary = (
                    detector.windowMeanWatts(),
                    detector.windowDrainPctTotal(),
                    detector.windowIsSaturated(),
                    s.timestamp
                )
            }
        }

        print("Final detector state:")
        print("  inEpisode: \(detector.inEpisode)")
        print("  windowIsSaturated: \(detector.windowIsSaturated())")
        print("  windowMeanWatts: \(detector.windowMeanWatts())")
        print("  windowDrainPctTotal: \(detector.windowDrainPctTotal())")
        if let lws = lastWindowSummary {
            print("  last sampled snapshot — saturated=\(lws.saturated) mean=\(lws.mean) drop=\(lws.drop)")
        }
        print("  startedAt: \(startedAt as Any)")

        XCTAssertTrue(samples.count > 0)
    }
}
