import XCTest
@testable import WattAI
@testable import WattAnalysis
@testable import WattModels

final class TemplaterTests: XCTestCase {
    func testFallbackVerdictIsDeterministic() {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 20, thermalState: 2)
        let withProcesses = drain.map { sample -> SamplePoint in
            var s = sample
            s.fanRPM = [5800]
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 250 * 1024 * 1024
            )
            return s
        }
        let analysis = ProcessCorrelator().correlate(samples: withProcesses)
        let stats = StatsBuilder.build(samples: withProcesses)
        let v1 = Templater.fallbackVerdict(stats: stats, suspects: analysis.suspects, patterns: analysis.patterns)
        let v2 = Templater.fallbackVerdict(stats: stats, suspects: analysis.suspects, patterns: analysis.patterns)
        XCTAssertEqual(v1, v2, "Templater must be deterministic for identical input")
    }

    func testFallbackHeadlineMentionsTopSuspectAndDrain() {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 20)
        let withProcesses = drain.map { sample -> SamplePoint in
            var s = sample
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 250 * 1024 * 1024
            )
            return s
        }
        let analysis = ProcessCorrelator().correlate(samples: withProcesses)
        let stats = StatsBuilder.build(samples: withProcesses)
        let v = Templater.fallbackVerdict(stats: stats, suspects: analysis.suspects, patterns: analysis.patterns)
        XCTAssertTrue(v.headline.contains("claude"), "headline should name the top suspect")
        XCTAssertTrue(v.headline.contains("%"), "headline should include drain percentage")
    }

    func testFallbackVerdictParagraphCitesNumbersAndPattern() {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 20, thermalState: 2)
        let withProcesses = drain.map { sample -> SamplePoint in
            var s = sample
            s.fanRPM = [5800]
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 250 * 1024 * 1024
            )
            return s
        }
        let analysis = ProcessCorrelator().correlate(samples: withProcesses)
        let stats = StatsBuilder.build(samples: withProcesses)
        let v = Templater.fallbackVerdict(stats: stats, suspects: analysis.suspects, patterns: analysis.patterns)
        XCTAssertTrue(v.verdictParagraph.contains("claude"))
        XCTAssertTrue(v.verdictParagraph.contains("falconctl"))
        XCTAssertTrue(v.verdictParagraph.contains("%/h"))
    }

    func testRecommendedActionsIncludeExclusionForCorrelatedPair() {
        let drain = Fixtures.steadyDrain(startPercent: 96, ratePctPerHour: 50, count: 20)
        let withProcesses = drain.map { sample -> SamplePoint in
            var s = sample
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 200 * 1024 * 1024,
                readBytes: 250 * 1024 * 1024
            )
            return s
        }
        let analysis = ProcessCorrelator().correlate(samples: withProcesses)
        let stats = StatsBuilder.build(samples: withProcesses)
        let v = Templater.fallbackVerdict(stats: stats, suspects: analysis.suspects, patterns: analysis.patterns)
        XCTAssertTrue(v.recommendedActions.contains { $0.contains("exclusion") })
    }
}
