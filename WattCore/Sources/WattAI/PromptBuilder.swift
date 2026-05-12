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
        patterns: PatternFlags
    ) -> String {
        var lines: [String] = []
        lines.append("# Episode")
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

        lines.append("")
        lines.append("# Timeline")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        for entry in timeline.prefix(40) {
            lines.append("- [\(formatter.string(from: entry.timestamp))] \(entry.kind.rawValue): \(entry.oneLine)")
        }

        lines.append("")
        lines.append("# Suspects (ranked)")
        for (i, suspect) in suspects.enumerated() {
            lines.append("\(i + 1). \(suspect.name) pid=\(suspect.pid) cpu_s=\(Int(suspect.totalCPUTime.rounded())) energy_nj=\(suspect.totalEnergyNanojoules) read_bytes=\(suspect.totalDiskReadBytes) write_bytes=\(suspect.totalDiskWriteBytes) pageins=\(suspect.totalPageins) score=\(String(format: "%.2f", suspect.score))")
        }

        lines.append("")
        lines.append("# Patterns")
        if let pair = patterns.correlatedWriterReader {
            lines.append("- correlated_writer_reader: writer=\(pair.writer.name)(pid \(pair.writer.pid)) wrote ~\(pair.writerBytes) bytes; reader=\(pair.reader.name)(pid \(pair.reader.pid)) read ~\(pair.readerBytes) bytes — security agent scanning shape.")
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

        lines.append("")
        lines.append("# Output")
        lines.append("Return: headline, verdictParagraph, suspectRationales (one per suspect, in the same order as listed above), recommendedActions.")

        return lines.joined(separator: "\n")
    }
}
