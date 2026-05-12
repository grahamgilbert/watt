import Foundation

/// A single time-bucket's top-N processes. Used in reports to give an
/// "activity over time" view rather than just the aggregate suspect list.
public struct ProcessBucket: Sendable, Hashable, Codable {
    public let bucketStart: Date
    public let bucketEnd: Date
    public let entries: [Entry]

    public struct Entry: Sendable, Hashable, Codable {
        public let pid: Int32
        public let name: String
        public let bundleID: String?
        public let cpuSeconds: Double
        public let energyJoules: Double
        public let diskReadBytes: UInt64
        public let diskWriteBytes: UInt64
        public let peakResidentBytes: UInt64
        public let isSecurityAgent: Bool
        public let securityAgentVendor: String?
        /// Combined score used to rank the entry inside this bucket.
        public let score: Double

        public init(
            pid: Int32,
            name: String,
            bundleID: String?,
            cpuSeconds: Double,
            energyJoules: Double,
            diskReadBytes: UInt64,
            diskWriteBytes: UInt64,
            peakResidentBytes: UInt64,
            isSecurityAgent: Bool,
            securityAgentVendor: String?,
            score: Double
        ) {
            self.pid = pid
            self.name = name
            self.bundleID = bundleID
            self.cpuSeconds = cpuSeconds
            self.energyJoules = energyJoules
            self.diskReadBytes = diskReadBytes
            self.diskWriteBytes = diskWriteBytes
            self.peakResidentBytes = peakResidentBytes
            self.isSecurityAgent = isSecurityAgent
            self.securityAgentVendor = securityAgentVendor
            self.score = score
        }
    }
}

public enum PeriodicTopProcesses {
    public struct Configuration: Sendable {
        public var bucketCount: Int
        public var topN: Int

        public init(bucketCount: Int = 6, topN: Int = 5) {
            self.bucketCount = max(1, bucketCount)
            self.topN = max(1, topN)
        }
    }

    /// Slice the samples into `configuration.bucketCount` equal time buckets
    /// and emit the top-N processes per bucket. Any security-agent process
    /// that ran in the bucket is **always** included (even if it falls
    /// outside the top-N), tagged as such, so reports always surface them.
    public static func compute(
        samples: [SamplePoint],
        configuration: Configuration = .init()
    ) -> [ProcessBucket] {
        guard let firstSample = samples.min(by: { $0.timestamp < $1.timestamp }),
              let lastSample = samples.max(by: { $0.timestamp < $1.timestamp })
        else { return [] }
        let totalDuration = lastSample.timestamp.timeIntervalSince(firstSample.timestamp)
        guard totalDuration > 0 else { return [] }
        let bucketSeconds = totalDuration / Double(configuration.bucketCount)
        guard bucketSeconds > 0 else { return [] }

        var buckets: [ProcessBucket] = []
        for i in 0..<configuration.bucketCount {
            let start = firstSample.timestamp.addingTimeInterval(Double(i) * bucketSeconds)
            let end = (i == configuration.bucketCount - 1)
                ? lastSample.timestamp
                : firstSample.timestamp.addingTimeInterval(Double(i + 1) * bucketSeconds)
            let inBucket = samples.filter { $0.timestamp >= start && $0.timestamp <= end }
            guard !inBucket.isEmpty else { continue }

            let aggregated = aggregate(samples: inBucket)
            let ranked = aggregated
                .map(makeEntry)
                .sorted { $0.score > $1.score }

            // Take top-N, then ensure every security agent in the bucket is
            // included (deduping by pid).
            var kept = Array(ranked.prefix(configuration.topN))
            for entry in ranked where entry.isSecurityAgent && !kept.contains(where: { $0.pid == entry.pid }) {
                kept.append(entry)
            }

            buckets.append(ProcessBucket(
                bucketStart: start,
                bucketEnd: end,
                entries: kept
            ))
        }
        return buckets
    }

    // MARK: - Aggregation

    private struct Aggregate {
        var pid: Int32
        var name: String
        var bundleID: String?
        var executablePath: String?
        var cpuSeconds: Double = 0
        var energyJoules: Double = 0
        var diskReadBytes: UInt64 = 0
        var diskWriteBytes: UInt64 = 0
        var peakResidentBytes: UInt64 = 0
        var pageins: UInt64 = 0
    }

    private static func aggregate(samples: [SamplePoint]) -> [Aggregate] {
        var byPid: [Int32: Aggregate] = [:]
        for sample in samples {
            for proc in sample.processes {
                var entry = byPid[proc.pid] ?? Aggregate(
                    pid: proc.pid,
                    name: proc.name,
                    bundleID: proc.bundleID,
                    executablePath: proc.executablePath
                )
                if entry.bundleID == nil { entry.bundleID = proc.bundleID }
                if entry.executablePath == nil { entry.executablePath = proc.executablePath }
                entry.cpuSeconds += proc.cpuTimeDelta
                entry.energyJoules += Double(proc.energyNanojoulesDelta) / 1_000_000_000.0
                entry.diskReadBytes &+= proc.diskReadBytesDelta
                entry.diskWriteBytes &+= proc.diskWriteBytesDelta
                entry.peakResidentBytes = max(entry.peakResidentBytes, proc.residentBytes)
                entry.pageins &+= proc.pageinsDelta
                byPid[proc.pid] = entry
            }
        }
        return Array(byPid.values)
    }

    private static func makeEntry(_ a: Aggregate) -> ProcessBucket.Entry {
        let classification = SecurityAgents.classify(
            name: a.name,
            bundleID: a.bundleID,
            executablePath: a.executablePath
        )
        // Score uses CPU as primary because security agents often spike CPU
        // hard but consume relatively little energy attributable to them
        // specifically. CPU + energy + IO combine to surface different
        // problem shapes.
        let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let score =
            a.cpuSeconds * Double(coreCount) +
            a.energyJoules * 2.0 +
            Double(a.diskReadBytes &+ a.diskWriteBytes) / 1_073_741_824.0 +
            Double(a.pageins) / 1_000.0
        return ProcessBucket.Entry(
            pid: a.pid,
            name: a.name,
            bundleID: a.bundleID,
            cpuSeconds: a.cpuSeconds,
            energyJoules: a.energyJoules,
            diskReadBytes: a.diskReadBytes,
            diskWriteBytes: a.diskWriteBytes,
            peakResidentBytes: a.peakResidentBytes,
            isSecurityAgent: classification.isAgent,
            securityAgentVendor: classification.vendor,
            score: score
        )
    }
}
