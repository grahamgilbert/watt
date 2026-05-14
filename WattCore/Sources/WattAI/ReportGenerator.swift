import Foundation
import WattAnalysis
import WattModels

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Produces a `Report` for a `DrainEpisode`. Always renders the deterministic
/// Markdown body via `MarkdownReportBuilder`; the only piece that varies based
/// on availability is the `DrainVerdict`, which is either authored by Apple
/// Intelligence or generated deterministically by `Templater.fallbackVerdict`.
public actor ReportGenerator {
    public init() {}

    public struct Output: Sendable {
        public var verdict: DrainVerdict
        public var generatedByLLM: Bool
        public var modelTokenCount: Int?
        public var markdown: String
    }

    public func generate(
        episode: DrainEpisode,
        samples: [SamplePoint],
        events: [UserEventPoint],
        analysis: ProcessCorrelator.Result,
        version: String = "0.1.0",
        now: Date = Date()
    ) async -> Output {
        let stats = StatsBuilder.build(samples: samples)
        let timeline = TimelineBuilder.build(samples: samples, events: events, suspects: analysis.suspects)
        let buckets = PeriodicTopProcesses.compute(samples: samples)

        let verdictResult = await produceVerdict(
            stats: stats,
            timeline: timeline,
            suspects: analysis.suspects,
            securityAgents: analysis.securityAgents,
            buckets: buckets,
            patterns: analysis.patterns,
            trigger: episode.trigger
        )

        let render = MarkdownReportBuilder.RenderInput(
            stats: stats,
            timeline: timeline,
            suspects: analysis.suspects,
            securityAgents: analysis.securityAgents,
            bucketedActivity: buckets,
            patterns: analysis.patterns,
            verdict: verdictResult.verdict,
            generatedByLLM: verdictResult.usedLLM,
            trigger: episode.trigger,
            samples: samples,
            watteVersion: version
        )
        let markdown = MarkdownReportBuilder.render(render, now: now)

        return Output(
            verdict: verdictResult.verdict,
            generatedByLLM: verdictResult.usedLLM,
            modelTokenCount: verdictResult.tokenCount,
            markdown: markdown
        )
    }

    private struct VerdictResult {
        var verdict: DrainVerdict
        var usedLLM: Bool
        var tokenCount: Int?
    }

    private func produceVerdict(
        stats: EpisodeStats,
        timeline: [TimelineEntry],
        suspects: [Suspect],
        securityAgents: [Suspect],
        buckets: [ProcessBucket],
        patterns: PatternFlags,
        trigger: DrainEpisodeTrigger = .batteryDrain
    ) async -> VerdictResult {
        #if canImport(FoundationModels)
        let availability = currentAvailability()
        if availability == .available {
            do {
                let prompt = PromptBuilder.serialize(
                    stats: stats,
                    timeline: timeline,
                    suspects: suspects,
                    securityAgents: securityAgents,
                    buckets: buckets,
                    patterns: patterns,
                    trigger: trigger
                )
                let session = LanguageModelSession(
                    instructions: ReportInstructions.systemPrompt
                )
                let response = try await session.respond(
                    to: prompt,
                    generating: GeneratedDrainVerdict.self,
                    options: GenerationOptions(temperature: 0.2)
                )
                return VerdictResult(
                    verdict: response.content.toDomain(),
                    usedLLM: true,
                    tokenCount: nil
                )
            } catch {
                // Any failure (timeout, content filter, OOM) falls back.
            }
        }
        #endif

        let verdict = Templater.fallbackVerdict(
            stats: stats,
            suspects: suspects,
            securityAgents: securityAgents,
            patterns: patterns,
            trigger: trigger
        )
        _ = buckets // intentionally unused in the templater; available to AI path only.
        return VerdictResult(verdict: verdict, usedLLM: false, tokenCount: nil)
    }

    public func availability() -> ModelAvailability {
        currentAvailability()
    }

    /// Test seam: returns true at compile time when FoundationModels is
    /// available to the build. Used by the test suite to verify the macOS 26
    /// build is actually picking up the framework, not silently falling
    /// through to the templated path.
    public static var foundationModelsCompiledIn: Bool {
        #if canImport(FoundationModels)
        return true
        #else
        return false
        #endif
    }

    private func currentAvailability() -> ModelAvailability {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            case .deviceNotEligible:
                return .deviceNotEligible
            @unknown default:
                return .otherUnavailable(String(describing: reason))
            }
        @unknown default:
            return .otherUnavailable("unknown availability")
        }
        #else
        return .otherUnavailable("FoundationModels framework unavailable on this build")
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
struct GeneratedDrainVerdict {
    @Guide(description: "One-line headline, max 90 chars. Lead with the drain percentage, time window, and the prime cause.")
    var headline: String

    @Guide(description: "2-4 sentence prose explanation of the most likely root cause. Cite specific numbers from the data.")
    var verdictParagraph: String

    @Guide(description: "Per-suspect rationale, in the same order as the suspects in the input. One short rationale per suspect.")
    var suspectRationales: [String]

    @Guide(description: "3-5 concrete imperative actions the user could take. Each one sentence.")
    var recommendedActions: [String]

    func toDomain() -> DrainVerdict {
        DrainVerdict(
            headline: headline,
            verdictParagraph: verdictParagraph,
            suspectRationales: suspectRationales,
            recommendedActions: recommendedActions
        )
    }
}
#endif
