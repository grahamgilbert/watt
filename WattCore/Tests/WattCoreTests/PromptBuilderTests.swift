import XCTest
@testable import WattAI
@testable import WattAnalysis
@testable import WattModels

final class PromptBuilderTests: XCTestCase {
    func testPromptIncludesAllRequiredSections() {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 20, thermalState: 2)
        let withProcesses = drain.enumerated().map { i, sample -> SamplePoint in
            var s = sample
            s.fanRPM = [Double(2000 + 200 * i)]
            s.temperatures = ["pACC MTR Temp Sensor0": Double(70 + i)]
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 250 * 1024 * 1024
            )
            return s
        }
        let stats = StatsBuilder.build(samples: withProcesses)
        let analysis = ProcessCorrelator().correlate(samples: withProcesses)
        let timeline = TimelineBuilder.build(samples: withProcesses, events: [], suspects: analysis.suspects)
        let prompt = PromptBuilder.serialize(
            stats: stats,
            timeline: timeline,
            suspects: analysis.suspects,
            patterns: analysis.patterns
        )
        for needle in ["# Episode", "# Timeline", "# Suspects", "# Patterns", "# Output"] {
            XCTAssertTrue(prompt.contains(needle), "Missing section: \(needle)")
        }
        XCTAssertTrue(prompt.contains("claude"), "Top suspect should be present")
        XCTAssertTrue(prompt.contains("correlated_writer_reader"), "Pattern flag should be present")
    }

    func testPromptIsBoundedInSize() {
        // Even with a very long timeline we should stay under ~6 KB.
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 200)
        let withProcesses = drain.map { sample -> SamplePoint in
            var s = sample
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 250 * 1024 * 1024
            )
            return s
        }
        let stats = StatsBuilder.build(samples: withProcesses)
        let analysis = ProcessCorrelator().correlate(samples: withProcesses)
        let timeline = TimelineBuilder.build(samples: withProcesses, events: [], suspects: analysis.suspects)
        let prompt = PromptBuilder.serialize(
            stats: stats,
            timeline: timeline,
            suspects: analysis.suspects,
            patterns: analysis.patterns
        )
        XCTAssertLessThan(prompt.count, 6000, "Prompt too long: \(prompt.count) chars")
    }
}
