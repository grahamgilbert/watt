import Foundation
import WattAnalysis
import WattModels

/// Serializes an episode + its analysis into a compact text payload that fits
/// comfortably inside the on-device model's context window.
public enum PromptBuilder {
    public static func serialize(
        stats: EpisodeStats,
        timeline: [TimelineEntry],
        suspects: [Suspect],
        securityAgents: [Suspect] = [],
        buckets: [ProcessBucket] = [],
        patterns: PatternFlags
    ) -> String {
        var lines: [String] = []
        lines.append(contentsOf: episodeSection(stats: stats))
        lines.append("")
        lines.append(contentsOf: timelineSection(timeline))
        lines.append("")
        lines.append(contentsOf: suspectsSection(suspects))
        if !securityAgents.isEmpty {
            lines.append("")
            lines.append(contentsOf: agentsSection(securityAgents))
        }
        if !buckets.isEmpty {
            lines.append("")
            lines.append(contentsOf: bucketsSection(buckets))
        }
        lines.append("")
        lines.append(contentsOf: patternsSection(patterns))
        lines.append("")
        lines.append("# Output")
        lines.append(
            "Return: headline, verdictParagraph, suspectRationales"
            + " (one per suspect, in the same order as listed above), recommendedActions."
        )
        return lines.joined(separator: "\n")
    }

    // MARK: - Sections

    private static func episodeSection(stats: EpisodeStats) -> [String] {
        var lines = ["# Episode"]
        lines.append("- duration_min: \(Int(stats.durationMinutes.rounded()))")
        lines.append("- drain_pct: \(Int(stats.drainPercent.rounded()))")
        lines.append("- start_pct: \(Int(stats.startPercent.rounded()))")
        lines.append("- end_pct: \(Int(stats.endPercent.rounded()))")
        lines.append("- peak_drain_rate_pct_per_hour: \(Int(stats.peakDrainRatePctPerHour.rounded()))")
        lines.append("- mean_cpu_pct: \(Int((stats.meanCPUUsage * 100).rounded()))")
        lines.append("- peak_cpu_pct: \(Int((stats.peakCPUUsage * 100).rounded()))")
        lines.append("- mean_mem_pressure_pct: \(Int(stats.meanMemoryPressurePct.rounded()))")
        lines.append("- peak_mem_pressure_pct: \(Int(stats.peakMemoryPressurePct.rounded()))")
        lines.append("- max_fan_rpm: \(Int(stats.maxFanRPM.rounded()))")
        if let name = stats.hottestSensorName, let temp = stats.hottestSensorCelsius {
            lines.append("- hottest_sensor: \(name) \(String(format: "%.1f", temp)) C")
        }
        lines.append("- thermal: \(stats.thermalSummary)")
        return lines
    }

    private static func timelineSection(_ timeline: [TimelineEntry]) -> [String] {
        var lines = ["# Timeline"]
        let formatter = hhmmssFormatter()
        for entry in timeline.prefix(40) {
            lines.append("- [\(formatter.string(from: entry.timestamp))] \(entry.kind.rawValue): \(entry.oneLine)")
        }
        return lines
    }

    private static func suspectsSection(_ suspects: [Suspect]) -> [String] {
        var lines = ["# Suspects (ranked)"]
        lines.append(
            "Units: cpu_s = CPU-seconds, energy_J = joules (NOT bytes),"
            + " read_GB / write_GB = gigabytes of disk IO. Do not confuse these —"
            + " energy and IO are different physical quantities."
        )
        for (i, suspect) in suspects.enumerated() {
            lines.append("\(i + 1). " + suspectLine(suspect))
        }
        return lines
    }

    private static func agentsSection(_ agents: [Suspect]) -> [String] {
        var lines = ["# Security/system agents observed (always present, regardless of score)"]
        lines.append(
            "These are LaunchDaemons, system extensions, or known endpoint security"
            + " tools that ran during this episode. The user wants the report to call"
            + " them out by name and explain how they likely contributed, even when"
            + " their per-process numbers are modest — the point of this tool is to"
            + " make corporate-mandated agents visible."
        )
        for agent in agents {
            lines.append("- " + agentLine(agent))
        }
        return lines
    }

    private static func bucketsSection(_ buckets: [ProcessBucket]) -> [String] {
        let formatter = hhmmssFormatter()
        var lines = ["# Activity over time (top processes per slice)"]
        for (i, bucket) in buckets.enumerated() {
            let s = formatter.string(from: bucket.bucketStart)
            let e = formatter.string(from: bucket.bucketEnd)
            lines.append("[slice \(i + 1) of \(buckets.count): \(s)–\(e)]")
            for entry in bucket.entries.prefix(5) {
                let mark = entry.isSecurityAgent ? "*agent" : ""
                lines.append(
                    "  - \(entry.name) cpu_s=\(String(format: "%.1f", entry.cpuSeconds))"
                    + " energy_J=\(String(format: "%.1f", entry.energyJoules)) \(mark)"
                )
            }
        }
        return lines
    }

    private static func patternsSection(_ patterns: PatternFlags) -> [String] {
        var lines = ["# Patterns"]
        if let pair = patterns.correlatedWriterReader {
            lines.append(
                "- correlated_writer_reader: writer=\(pair.writer.name)(pid \(pair.writer.pid))"
                + " wrote ~\(pair.writerBytes) bytes; reader=\(pair.reader.name)(pid \(pair.reader.pid))"
                + " read ~\(pair.readerBytes) bytes — security agent scanning shape."
            )
        }
        if patterns.thermalThrottle {
            lines.append("- thermal_throttle: thermal state at .serious or higher for >50% of episode")
        }
        if patterns.fanSpike {
            lines.append("- fan_spike: a fan exceeded 4500 RPM during this episode")
        }
        if patterns.memoryPressureSpike {
            lines.append("- memory_pressure_spike: memory pressure exceeded 80%")
        }
        return lines
    }

    // MARK: - Line builders

    private static func suspectLine(_ suspect: Suspect) -> String {
        let energyJ = Double(suspect.totalEnergyNanojoules) / 1_000_000_000.0
        let readGB = Double(suspect.totalDiskReadBytes) / 1_073_741_824.0
        let writeGB = Double(suspect.totalDiskWriteBytes) / 1_073_741_824.0
        return "\(suspect.name) pid=\(suspect.pid)"
            + " cpu_s=\(Int(suspect.totalCPUTime.rounded()))"
            + " energy_J=\(String(format: "%.2f", energyJ))"
            + " read_GB=\(String(format: "%.2f", readGB))"
            + " write_GB=\(String(format: "%.2f", writeGB))"
            + " pageins=\(suspect.totalPageins)"
            + " score=\(String(format: "%.2f", suspect.score))"
    }

    private static func agentLine(_ agent: Suspect) -> String {
        let kind = SecurityAgents.classify(name: agent.name, bundleID: agent.bundleID)
        let label: String
        switch kind {
        case .curated(let def):           label = "\(def.displayName) [\(def.vendor)]"
        case .systemManaged(let svc):     label = "\(svc.kind.rawValue) `\(svc.label)`"
        case .unknown:                    label = "unclassified"
        }
        let readGB = Double(agent.totalDiskReadBytes) / 1_073_741_824.0
        let writeGB = Double(agent.totalDiskWriteBytes) / 1_073_741_824.0
        let energyJ = Double(agent.totalEnergyNanojoules) / 1_000_000_000.0
        return "\(agent.name) (pid \(agent.pid)) \(label)"
            + " cpu_s=\(Int(agent.totalCPUTime.rounded()))"
            + " energy_J=\(String(format: "%.2f", energyJ))"
            + " read_GB=\(String(format: "%.2f", readGB))"
            + " write_GB=\(String(format: "%.2f", writeGB))"
    }

    private static func hhmmssFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }
}
