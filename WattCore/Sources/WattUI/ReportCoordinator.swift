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
    public let version: String

    public init(
        writer: SamplingWriter,
        version: String = "0.1.0"
    ) {
        self.writer = writer
        self.version = version
    }

    /// Operator-driven equivalent of an automatic episode: synthesise a
    /// `DrainEpisode` row spanning the last `lookback` seconds, run the same
    /// analysis + report pipeline, and persist both. Returns the new
    /// episode's identifier so the caller can navigate to it.
    @discardableResult
    public func generateAdHocReport(
        lookback: TimeInterval = 30 * 60,
        now: Date = Date()
    ) async -> PersistentIdentifier? {
        let interval = now.addingTimeInterval(-lookback) ... now
        guard let samples = try? await writer.loadSamplePoints(in: interval),
              let events = try? await writer.loadUserEventPoints(in: interval),
              !samples.isEmpty
        else { return nil }

        let startPercent = samples.first?.batteryPercent ?? .nan
        let endPercent = samples.last?.batteryPercent ?? .nan
        let avgThermal = samples.isEmpty
            ? 0
            : Int((Double(samples.map(\.thermalState).reduce(0, +)) / Double(samples.count)).rounded())
        let peakWatts = samples.map(\.systemEnergyWatts).max() ?? 0

        // Approximate peak drain rate from the captured window.
        let peakDrain: Double = {
            guard let first = samples.first, let last = samples.last,
                  !first.batteryPercent.isNaN, !last.batteryPercent.isNaN
            else { return 0 }
            let dt = last.timestamp.timeIntervalSince(first.timestamp)
            guard dt > 0 else { return 0 }
            return max(first.batteryPercent - last.batteryPercent, 0) / dt * 3600
        }()

        let episodeID: PersistentIdentifier
        do {
            episodeID = try await writer.writeAdHocEpisode(
                startedAt: interval.lowerBound,
                endedAt: interval.upperBound,
                startPercent: startPercent,
                endPercent: endPercent,
                peakDrainRatePctPerHour: peakDrain,
                peakSystemEnergyWatts: peakWatts,
                avgThermalState: avgThermal
            )
        } catch {
            return nil
        }

        let analysis = ProcessCorrelator().correlate(samples: samples)
        let episodeStub = DrainEpisode(
            startedAt: interval.lowerBound,
            endedAt: interval.upperBound,
            startPercent: startPercent,
            endPercent: endPercent,
            peakDrainRatePctPerHour: peakDrain,
            avgThermalState: avgThermal,
            trigger: .userTriggered,
            peakSystemEnergyWatts: peakWatts
        )
        let output = await generator.generate(
            episode: episodeStub,
            samples: samples,
            events: events,
            analysis: analysis,
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
        mirrorToDisk(
            markdown: output.markdown,
            generatedByLLM: output.generatedByLLM,
            episodeStart: interval.lowerBound
        )
        return episodeID
    }

    /// Deletes one episode plus every Report attached to it, and removes the
    /// on-disk Markdown mirrors for those reports.
    public func delete(episodeID: PersistentIdentifier) async {
        let started: Date?
        do {
            started = try await writer.deleteEpisode(id: episodeID)
        } catch {
            return
        }
        guard let started else { return }
        deleteMarkdownMirrors(forEpisodeStartedAt: started)
    }

    /// Deletes every episode + report from the SwiftData store and clears
    /// the on-disk Markdown mirror directory.
    public func deleteAll() async {
        let starts: [Date]
        do {
            starts = try await writer.deleteAllEpisodes()
        } catch {
            return
        }
        for s in starts {
            deleteMarkdownMirrors(forEpisodeStartedAt: s)
        }
    }

    private nonisolated func deleteMarkdownMirrors(forEpisodeStartedAt episodeStart: Date) {
        guard let dir = try? WattStore.reportsDirectory() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.timeZone = .current
        let stamp = formatter.string(from: episodeStart)
        let prefix = "episode-\(stamp)"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for entry in entries where entry.hasPrefix(prefix) {
            let url = dir.appending(path: entry, directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: url)
        }
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
        mirrorToDisk(
            markdown: output.markdown,
            generatedByLLM: output.generatedByLLM,
            episodeStart: bounds.startedAt
        )
    }

    /// Writes a copy of the Markdown to
    /// `~/Library/Application Support/Watt/Reports/episode-<timestamp>.md` so
    /// users can grep, share, or open the file directly. The SwiftData store
    /// stays authoritative; this is just a mirror.
    private func mirrorToDisk(markdown: String, generatedByLLM: Bool, episodeStart: Date) {
        do {
            let dir = try WattStore.reportsDirectory()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            formatter.timeZone = .current
            let stamp = formatter.string(from: episodeStart)
            let suffix = generatedByLLM ? "ai" : "templated"
            let filename = "episode-\(stamp)-\(suffix).md"
            let url = dir.appending(path: filename, directoryHint: .notDirectory)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Non-fatal: SwiftData copy is the source of truth.
        }
    }
}
