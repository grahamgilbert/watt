import Foundation
import WattAnalysis
import WattModels

/// Renders the canonical Markdown body of a `Report` from deterministic
/// inputs plus a `DrainVerdict`. Everything outside of the verdict and the
/// per-suspect rationale comes from `EpisodeStats`, the timeline, and the
/// suspect/pattern data — so two reports for the same episode differ only in
/// those AI-authored strings.
public enum MarkdownReportBuilder {
    public struct RenderInput: Sendable {
        public var stats: EpisodeStats
        public var timeline: [TimelineEntry]
        public var suspects: [Suspect]
        public var patterns: PatternFlags
        public var verdict: DrainVerdict
        public var generatedByLLM: Bool
        public var samples: [SamplePoint]
        public var watteVersion: String
        public var helperInstalled: Bool

        public init(
            stats: EpisodeStats,
            timeline: [TimelineEntry],
            suspects: [Suspect],
            patterns: PatternFlags,
            verdict: DrainVerdict,
            generatedByLLM: Bool,
            samples: [SamplePoint],
            watteVersion: String = "0.1.0",
            helperInstalled: Bool = false
        ) {
            self.stats = stats
            self.timeline = timeline
            self.suspects = suspects
            self.patterns = patterns
            self.verdict = verdict
            self.generatedByLLM = generatedByLLM
            self.samples = samples
            self.watteVersion = watteVersion
            self.helperInstalled = helperInstalled
        }
    }

    public static func render(_ input: RenderInput, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("# \(input.verdict.headline)")
        lines.append("")
        lines.append(verdictBlock(input))
        lines.append("")
        lines.append(atAGlance(input.stats))
        lines.append("")
        lines.append(timelineSection(input.timeline))
        lines.append("")
        lines.append(suspectsSection(input))
        lines.append("")
        lines.append(actionsSection(input.verdict.recommendedActions))
        lines.append("")
        lines.append(rawDataSection(stats: input.stats, samples: input.samples, suspects: input.suspects))
        lines.append("")
        lines.append(footer(input: input, now: now))
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Verdict

    private static func verdictBlock(_ input: RenderInput) -> String {
        let label = input.generatedByLLM ? "Verdict (AI)" : "Verdict (Templated — Apple Intelligence is off)"
        return "**\(label):** \(input.verdict.verdictParagraph)"
    }

    // MARK: - At a glance

    private static func atAGlance(_ stats: EpisodeStats) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        let started = formatter.string(from: stats.startedAt)
        let ended = formatter.string(from: stats.endedAt)

        let hottest: String
        if let name = stats.hottestSensorName, let temp = stats.hottestSensorCelsius {
            hottest = "`\(name)` \(String(format: "%.1f", temp)) °C"
        } else {
            hottest = "n/a"
        }

        return """
        ## At a glance
        | | |
        |---|---|
        | Window | \(started)–\(ended) |
        | Drain | \(intPct(stats.drainPercent))% (\(intPct(stats.startPercent))% → \(intPct(stats.endPercent))%) |
        | Duration | \(Int(stats.durationMinutes.rounded())) min |
        | Peak rate | \(Int(stats.peakDrainRatePctPerHour.rounded())) %/h |
        | Mean / peak CPU | \(percentage(stats.meanCPUUsage)) / \(percentage(stats.peakCPUUsage)) |
        | Mean / peak memory pressure | \(intPct(stats.meanMemoryPressurePct))% / \(intPct(stats.peakMemoryPressurePct))% |
        | Thermal | \(stats.thermalSummary) |
        | Hottest sensor | \(hottest) |
        | Max fan | \(Int(stats.maxFanRPM.rounded())) RPM |
        | FS events peak | \(Int(stats.fsEventsRatePeak.rounded()))/s |
        | Samples | \(stats.sampleCount) |
        """
    }

    // MARK: - Timeline

    private static func timelineSection(_ entries: [TimelineEntry]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        var lines = ["## Timeline"]
        if entries.isEmpty {
            lines.append("_No timeline entries — episode was too short to summarize._")
            return lines.joined(separator: "\n")
        }
        for entry in entries {
            lines.append("- **\(formatter.string(from: entry.timestamp))** — \(entry.oneLine)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Suspects

    private static func suspectsSection(_ input: RenderInput) -> String {
        var lines = ["## Prime suspects"]
        if input.suspects.isEmpty {
            lines.append("_No suspect processes ranked above threshold for this episode._")
            return lines.joined(separator: "\n")
        }
        for (i, suspect) in input.suspects.enumerated() {
            let rationale = input.verdict.suspectRationales.indices.contains(i)
                ? input.verdict.suspectRationales[i]
                : Templater.templateRationale(for: suspect)
            lines.append(
                "\(i + 1). **\(suspect.name)** — pid \(suspect.pid)\(suspect.bundleID.map { ", bundle `\($0)`" } ?? ""), score \(String(format: "%.2f", suspect.score))."
            )
            lines.append("   \(rationale)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    private static func actionsSection(_ actions: [String]) -> String {
        var lines = ["## Recommended actions"]
        if actions.isEmpty {
            lines.append("_No automated suggestions — review the timeline and suspects above._")
        } else {
            for a in actions {
                lines.append("- \(a)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Raw data

    private static func rawDataSection(
        stats: EpisodeStats,
        samples: [SamplePoint],
        suspects: [Suspect]
    ) -> String {
        var lines = ["## Raw data"]
        lines.append("<details><summary>Per-sample CSV (\(samples.count) rows)</summary>")
        lines.append("")
        lines.append("```csv")
        lines.append("timestamp,battery,is_charging,cpu_pct,mem_pct,fan_max_rpm,hot_temp_c,thermal,fs_events_per_s")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for sample in samples {
            let temp = sample.hottestSensor?.value ?? 0
            let row = [
                formatter.string(from: sample.timestamp),
                String(format: "%.1f", sample.batteryPercent),
                sample.isCharging ? "true" : "false",
                String(format: "%.1f", sample.systemCPUUsage * 100),
                String(format: "%.1f", sample.memoryPressurePct),
                String(Int(sample.maxFanRPM.rounded())),
                String(format: "%.1f", temp),
                String(sample.thermalState),
                String(format: "%.0f", sample.fsEventsRate)
            ].joined(separator: ",")
            lines.append(row)
        }
        lines.append("```")
        lines.append("</details>")
        lines.append("")
        lines.append("<details><summary>Suspect process deltas</summary>")
        lines.append("")
        lines.append("```csv")
        lines.append("rank,pid,name,bundle_id,cpu_s,energy_nj,read_bytes,write_bytes,pageins,resident_bytes,score")
        for (i, suspect) in suspects.enumerated() {
            let row = [
                String(i + 1),
                String(suspect.pid),
                suspect.name,
                suspect.bundleID ?? "",
                String(format: "%.1f", suspect.totalCPUTime),
                String(suspect.totalEnergyNanojoules),
                String(suspect.totalDiskReadBytes),
                String(suspect.totalDiskWriteBytes),
                String(suspect.totalPageins),
                String(suspect.peakResidentBytes),
                String(format: "%.3f", suspect.score)
            ].joined(separator: ",")
            lines.append(row)
        }
        lines.append("```")
        lines.append("</details>")
        _ = stats
        return lines.joined(separator: "\n")
    }

    // MARK: - Footer

    private static func footer(input: RenderInput, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        let mode = input.generatedByLLM ? "Apple Intelligence" : "Templated"
        return "> Generated by Watt \(input.watteVersion) on \(formatter.string(from: now)). Mode: \(mode). Helper installed: \(input.helperInstalled ? "yes" : "no")."
    }

    // MARK: - Helpers

    private static func intPct(_ x: Double) -> Int { Int(x.rounded()) }
    private static func percentage(_ unit: Double) -> String {
        "\(Int((unit * 100).rounded()))%"
    }
}
