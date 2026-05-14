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
        patterns: PatternFlags,
        trigger: DrainEpisodeTrigger = .batteryDrain
    ) -> String {
        var lines: [String] = []
        lines.append(contentsOf: episodeSection(stats: stats, trigger: trigger))
        lines.append("")
        lines.append(contentsOf: timelineSection(timeline))
        lines.append("")
        lines.append(contentsOf: suspectsSection(suspects))
        let agentLines = agentsSection(securityAgents)
        if !agentLines.isEmpty {
            lines.append("")
            lines.append(contentsOf: agentLines)
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
            "Return: headline, verdictParagraph, suspectRationales, recommendedActions."
            + " suspectRationales must have EXACTLY one entry per suspect, in the SAME ORDER as the Suspects section."
            + " suspectRationales[0] describes suspect #1, etc."
            + " Each rationale must: (1) state what the process actually DID (\"wrote X GB to /tmp\","
            + " \"scanned writes from process Y\", \"compiled N files\") based on the numbers;"
            + " (2) explain WHY it drove energy or drain (e.g. sustained CPU, large I/O amplification, memory pressure);"
            + " (3) be 1–2 sentences. Never write percentages of totals — cite absolute numbers from the data."
        )
        return lines.joined(separator: "\n")
    }

    // MARK: - Sections

    private static func episodeSection(stats: EpisodeStats, trigger: DrainEpisodeTrigger) -> [String] {
        var lines = ["# Episode"]
        switch trigger {
        case .acHighEnergy:
            lines.append("- type: AC_HIGH_ENERGY (machine is plugged in; drain_pct is meaningless here — focus on energy load)")
        case .batteryDrain:
            lines.append("- type: BATTERY_DRAIN")
        case .userTriggered:
            lines.append("- type: USER_REQUESTED_LOOKBACK")
        }
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
        let active = agents.filter {
            $0.totalEnergyNanojoules > 0 || $0.totalCPUTime > 0
                || $0.totalDiskReadBytes > 0 || $0.totalDiskWriteBytes > 0
        }
        guard !active.isEmpty else { return [] }
        var lines = ["# System daemons / LaunchDaemons with measurable activity"]
        lines.append(
            "These LaunchDaemons or system extensions had non-zero CPU, energy, or I/O during this episode."
            + " Only agents listed here were active — do NOT mention agents that do not appear in this list."
        )
        for agent in active {
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
                let mark = entry.isSystemManaged ? "*daemon" : ""
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
                + " read ~\(pair.readerBytes) bytes — sustained writer/reader overlap."
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
        let svc = SystemServiceRegistry.match(executablePath: agent.executablePath, bundleID: agent.bundleID)
        let label = svc.map { "\($0.kind.rawValue) `\($0.label)`" } ?? "system-managed"
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
