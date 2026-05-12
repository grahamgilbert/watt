import Foundation
import WattAnalysis
import WattModels

/// Deterministic, rule-based fallback for when Apple Intelligence is off.
/// Produces a `DrainVerdict` byte-identical for identical inputs so the
/// surrounding Markdown report stays diffable across re-renders.
public enum Templater {
    public static func fallbackVerdict(
        stats: EpisodeStats,
        suspects: [Suspect],
        patterns: PatternFlags
    ) -> DrainVerdict {
        let topName = suspects.first?.name ?? "an unidentified process"
        let drainPct = Int(stats.drainPercent.rounded())
        let durationMin = Int(stats.durationMinutes.rounded())

        let headline = "Battery drained \(drainPct)% in \(durationMin) min — top suspect: \(topName)"

        var sentences: [String] = []
        sentences.append(
            "Battery fell from \(intPct(stats.startPercent))% to \(intPct(stats.endPercent))% over \(durationMin) min, peaking at \(rate(stats.peakDrainRatePctPerHour)) %/h."
        )
        if let pair = patterns.correlatedWriterReader {
            sentences.append(
                "`\(pair.writer.name)` and `\(pair.reader.name)` formed a writer/reader pair — \(gb(pair.writerBytes)) written by `\(pair.writer.name)` was read back \(gb(pair.readerBytes)) by `\(pair.reader.name)`, which is the canonical shape of a security agent scanning every file another tool produces."
            )
        }
        if patterns.thermalThrottle {
            sentences.append(
                "System thermal state held at *serious* or higher for more than half of the episode (\(stats.thermalSummary))."
            )
        }
        if patterns.fanSpike {
            sentences.append(
                "Fans hit \(Int(stats.maxFanRPM.rounded())) RPM."
            )
        }
        if sentences.count == 1 {
            sentences.append(
                "Top suspects ranked by combined energy / CPU / IO score; see the technical sections below."
            )
        }

        let rationales = suspects.map { suspect in
            templateRationale(for: suspect)
        }

        var actions: [String] = []
        if let pair = patterns.correlatedWriterReader {
            actions.append("Ask Security to add `\(pair.writer.name)`'s output paths to `\(pair.reader.name)`'s scanning exclusion list.")
        }
        if patterns.thermalThrottle {
            actions.append("Capture an Activity Monitor sample.txt and a `pmset -g log` slice for the time window so you have a second source of truth.")
        }
        if patterns.fanSpike {
            actions.append("Note fan/thermal numbers in the ticket — they show the load was real, not just bookkeeping.")
        }
        actions.append("Re-run the same workload after applying the suggested change and compare report-to-report.")
        if actions.count < 3 {
            actions.append("Share this Markdown report verbatim in #ask-security; the timeline and suspect tables are reproducible.")
        }

        let paragraph = sentences.joined(separator: " ")
        return DrainVerdict(
            headline: headline,
            verdictParagraph: paragraph,
            suspectRationales: rationales,
            recommendedActions: actions
        )
    }

    static func templateRationale(for suspect: Suspect) -> String {
        let cpu = String(format: "%.0f", suspect.totalCPUTime)
        let read = gb(suspect.totalDiskReadBytes)
        let write = gb(suspect.totalDiskWriteBytes)
        let energy = sci(suspect.totalEnergyNanojoules)
        return "\(cpu) CPU-seconds, \(read) read / \(write) written, energy ≈ \(energy)."
    }

    private static func intPct(_ x: Double) -> Int { Int(x.rounded()) }

    private static func rate(_ x: Double) -> String {
        x < 100 ? String(format: "%.0f", x) : String(format: "%d", Int(x.rounded()))
    }

    private static func gb(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    private static func sci(_ value: UInt64) -> String {
        if value == 0 { return "0" }
        let v = Double(value)
        let exp = Int(log10(v).rounded(.down))
        let mantissa = v / pow(10, Double(exp))
        return String(format: "%.1fe%d", mantissa, exp)
    }
}
