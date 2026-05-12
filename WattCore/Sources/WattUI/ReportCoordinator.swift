import Foundation
import SwiftData
import WattAI
import WattAnalysis
import WattModels
import WattSampling

/// Orchestrates report generation for a `DrainEpisode`. Pulls the relevant
/// samples + user events from the writer, runs `ProcessCorrelator`, asks
/// `ReportGenerator` to produce a Markdown body, and writes the new `Report`
/// row attached to the episode.
public actor ReportCoordinator {
    private let writer: SamplingWriter
    private let generator = ReportGenerator()
    private let helperInstalled: () -> Bool
    public let version: String

    public init(
        writer: SamplingWriter,
        helperInstalled: @escaping () -> Bool = { false },
        version: String = "0.1.0"
    ) {
        self.writer = writer
        self.helperInstalled = helperInstalled
        self.version = version
    }

    public func regenerate(for episodeID: PersistentIdentifier) async {
        let resolved: SamplingWriter.EpisodeBounds?
        do {
            resolved = try await writer.episodeBounds(id: episodeID)
        } catch {
            return
        }
        guard let bounds = resolved else { return }
        let interval = bounds.startedAt ... bounds.endedAt
        guard let samples = try? await writer.loadSamplePoints(in: interval),
              let events = try? await writer.loadUserEventPoints(in: interval),
              !samples.isEmpty
        else { return }

        let analysis = ProcessCorrelator().correlate(samples: samples)
        // The generator only uses `episode` for completeness; we pass a
        // detached value object so we never cross actor boundaries with a
        // SwiftData model.
        let episodeStub = DrainEpisode(
            startedAt: bounds.startedAt,
            endedAt: bounds.endedAt,
            startPercent: bounds.startPercent,
            endPercent: bounds.endPercent,
            peakDrainRatePctPerHour: bounds.peakDrainRatePctPerHour,
            avgThermalState: bounds.avgThermalState,
            trigger: bounds.trigger,
            peakSystemEnergyWatts: bounds.peakSystemEnergyWatts
        )
        let output = await generator.generate(
            episode: episodeStub,
            samples: samples,
            events: events,
            analysis: analysis,
            helperInstalled: helperInstalled(),
            version: version
        )
        let report = Report(
            generatedAt: Date(),
            headline: output.verdict.headline,
            markdown: output.markdown,
            generatedByLLM: output.generatedByLLM,
            modelTokenCount: output.modelTokenCount
        )
        try? await writer.writeReport(report, attachingTo: episodeID)
    }
}
