import XCTest
@testable import WattAI
@testable import WattAnalysis
@testable import WattModels

final class ReportGeneratorTests: XCTestCase {
    func testFoundationModelsBuildsAgainstFramework() {
        XCTAssertTrue(
            ReportGenerator.foundationModelsCompiledIn,
            "macOS 26 build must compile FoundationModels in. If this fails, the package is targeting an older macOS version."
        )
    }

    func testGenerateProducesNonEmptyMarkdownEvenWhenAIIsDisabled() async {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 20, thermalState: 2)
        let withProcesses = drain.enumerated().map { i, sample -> SamplePoint in
            var s = sample
            s.fanRPM = [Double(2000 + 200 * i)]
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 250 * 1024 * 1024
            )
            return s
        }
        let analysis = ProcessCorrelator().correlate(samples: withProcesses)
        let episode = DrainEpisode(
            startedAt: drain.first!.timestamp,
            endedAt: drain.last!.timestamp,
            startPercent: drain.first!.batteryPercent,
            endPercent: drain.last!.batteryPercent,
            peakDrainRatePctPerHour: 50,
            avgThermalState: 2
        )
        let generator = ReportGenerator()
        let output = await generator.generate(
            episode: episode,
            samples: withProcesses,
            events: [],
            analysis: analysis,
            now: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        XCTAssertFalse(output.markdown.isEmpty)
        XCTAssertTrue(output.markdown.contains("# "))
        XCTAssertTrue(output.markdown.contains("## At a glance"))
        XCTAssertTrue(output.markdown.contains("## Timeline"))
        XCTAssertTrue(output.markdown.contains("## Prime suspects"))
    }
}
