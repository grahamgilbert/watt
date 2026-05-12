import XCTest
@testable import WattAI
@testable import WattAnalysis
@testable import WattModels

final class AdHocReportTests: XCTestCase {
    func testRenderInputCarriesUserTriggeredAnnotation() {
        let drain = Fixtures.steadyDrain(startPercent: 90, ratePctPerHour: 8, count: 10, step: 60)
        let processed = drain.map { sample -> SamplePoint in
            var s = sample
            s.processes = Fixtures.writerReaderProcesses(
                writeBytes: 50 * 1024 * 1024,
                readBytes: 60 * 1024 * 1024
            )
            return s
        }
        let stats = StatsBuilder.build(samples: processed)
        let analysis = ProcessCorrelator().correlate(samples: processed)
        let timeline = TimelineBuilder.build(samples: processed, events: [], suspects: analysis.suspects)
        let verdict = Templater.fallbackVerdict(
            stats: stats,
            suspects: analysis.suspects,
            patterns: analysis.patterns
        )
        let render = MarkdownReportBuilder.RenderInput(
            stats: stats,
            timeline: timeline,
            suspects: analysis.suspects,
            patterns: analysis.patterns,
            verdict: verdict,
            generatedByLLM: false,
            trigger: .userTriggered,
            samples: processed
        )
        let md = MarkdownReportBuilder.render(render)
        XCTAssertTrue(md.contains("Operator-requested look-back"),
                      "User-triggered reports must surface the manual annotation")
    }

    func testAutomaticReportOmitsUserTriggeredBanner() {
        let drain = Fixtures.steadyDrain(startPercent: 90, ratePctPerHour: 30, count: 10, step: 60)
        let stats = StatsBuilder.build(samples: drain)
        let analysis = ProcessCorrelator().correlate(samples: drain)
        let timeline = TimelineBuilder.build(samples: drain, events: [], suspects: analysis.suspects)
        let verdict = Templater.fallbackVerdict(
            stats: stats,
            suspects: analysis.suspects,
            patterns: analysis.patterns
        )
        let render = MarkdownReportBuilder.RenderInput(
            stats: stats,
            timeline: timeline,
            suspects: analysis.suspects,
            patterns: analysis.patterns,
            verdict: verdict,
            generatedByLLM: false,
            trigger: .batteryDrain,
            samples: drain
        )
        let md = MarkdownReportBuilder.render(render)
        XCTAssertFalse(md.contains("Operator-requested look-back"))
    }
}
