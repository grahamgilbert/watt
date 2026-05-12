import Foundation

public struct ProcessCorrelator: Sendable {
    public struct Configuration: Sendable {
        public var weightEnergy: Double
        public var weightCPU: Double
        public var weightDisk: Double
        public var weightPageins: Double
        public var minCoverageFraction: Double
        public var topN: Int
        public var coreCount: Int

        public init(
            weightEnergy: Double = 1.0,
            weightCPU: Double = 0.5,
            weightDisk: Double = 0.3,
            weightPageins: Double = 0.2,
            minCoverageFraction: Double = 0.5,
            topN: Int = 5,
            coreCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)
        ) {
            self.weightEnergy = weightEnergy
            self.weightCPU = weightCPU
            self.weightDisk = weightDisk
            self.weightPageins = weightPageins
            self.minCoverageFraction = minCoverageFraction
            self.topN = topN
            self.coreCount = max(coreCount, 1)
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public struct Result: Sendable {
        public var suspects: [Suspect]
        public var patterns: PatternFlags
        /// Every observed security/MDM agent that ran during the episode,
        /// regardless of whether it scored above the suspect threshold. The
        /// whole point of Watt is to make these tools' impact visible, so we
        /// always surface them — even if they're individually quiet.
        public var securityAgents: [Suspect]
    }

    public func correlate(samples: [SamplePoint]) -> Result {
        guard !samples.isEmpty else { return Result(suspects: [], patterns: .init(), securityAgents: []) }
        let totals = aggregate(samples: samples)
        let qualifying = totals.values.filter {
            Double($0.samplesCovered) / Double(samples.count) >= configuration.minCoverageFraction
        }
        let p95 = percentiles(qualifying: qualifying)
        let scored = qualifying.map { entry -> Suspect in
            let energyTerm = normalize(Double(entry.totalEnergyNanojoules), p95.energy) * configuration.weightEnergy
            let cpuTerm = normalize(entry.totalCPUTime * Double(configuration.coreCount), p95.cpu) * configuration.weightCPU
            let diskTerm = normalize(Double(entry.totalDiskReadBytes &+ entry.totalDiskWriteBytes), p95.disk) * configuration.weightDisk
            let pageTerm = normalize(Double(entry.totalPageins), p95.pageins) * configuration.weightPageins
            let score = energyTerm + cpuTerm + diskTerm + pageTerm
            return Suspect(
                pid: entry.pid,
                name: entry.name,
                bundleID: entry.bundleID,
                executablePath: entry.executablePath,
                totalCPUTime: entry.totalCPUTime,
                totalEnergyNanojoules: entry.totalEnergyNanojoules,
                totalDiskReadBytes: entry.totalDiskReadBytes,
                totalDiskWriteBytes: entry.totalDiskWriteBytes,
                totalPageins: entry.totalPageins,
                peakResidentBytes: entry.peakResidentBytes,
                samplesCovered: entry.samplesCovered,
                score: score
            )
        }
        var top = scored.sorted { $0.score > $1.score }.prefix(configuration.topN).map { $0 }
        // Always include security/system agents in the top list, even if
        // they scored below threshold. De-dupe by pid so we don't double-
        // list an agent that organically made the cut.
        let securityAgentSuspects = scored
            .filter {
                SecurityAgents.classify(
                    name: $0.name,
                    bundleID: $0.bundleID,
                    executablePath: $0.executablePath
                ).isAgent
            }
            .sorted { $0.score > $1.score }
        for agent in securityAgentSuspects where !top.contains(where: { $0.pid == agent.pid }) {
            top.append(agent)
        }
        let patterns = derivePatterns(samples: samples, top: top, all: scored)
        return Result(suspects: top, patterns: patterns, securityAgents: securityAgentSuspects)
    }

    // MARK: - Aggregation

    private struct AggregateEntry {
        var pid: Int32
        var name: String
        var bundleID: String?
        var executablePath: String?
        var totalCPUTime: Double = 0
        var totalEnergyNanojoules: UInt64 = 0
        var totalBilledEnergy: UInt64 = 0
        var totalDiskReadBytes: UInt64 = 0
        var totalDiskWriteBytes: UInt64 = 0
        var totalPageins: UInt64 = 0
        var peakResidentBytes: UInt64 = 0
        var samplesCovered: Int = 0
    }

    private func aggregate(samples: [SamplePoint]) -> [Int32: AggregateEntry] {
        var byPid: [Int32: AggregateEntry] = [:]
        for sample in samples {
            for proc in sample.processes {
                var entry = byPid[proc.pid] ?? AggregateEntry(
                    pid: proc.pid,
                    name: proc.name,
                    bundleID: proc.bundleID,
                    executablePath: proc.executablePath
                )
                if entry.bundleID == nil { entry.bundleID = proc.bundleID }
                if entry.executablePath == nil { entry.executablePath = proc.executablePath }
                if entry.name.isEmpty { entry.name = proc.name }
                entry.totalCPUTime += proc.cpuTimeDelta
                entry.totalEnergyNanojoules &+= proc.energyNanojoulesDelta
                entry.totalBilledEnergy &+= proc.billedEnergyDelta
                entry.totalDiskReadBytes &+= proc.diskReadBytesDelta
                entry.totalDiskWriteBytes &+= proc.diskWriteBytesDelta
                entry.totalPageins &+= proc.pageinsDelta
                entry.peakResidentBytes = max(entry.peakResidentBytes, proc.residentBytes)
                entry.samplesCovered += 1
                byPid[proc.pid] = entry
            }
        }
        return byPid
    }

    private struct Percentiles { var energy: Double; var cpu: Double; var disk: Double; var pageins: Double }

    private func percentiles(qualifying: some Collection<AggregateEntry>) -> Percentiles {
        Percentiles(
            energy: percentile(qualifying.map { Double($0.totalEnergyNanojoules) }, 0.95),
            cpu: percentile(qualifying.map { $0.totalCPUTime * Double(configuration.coreCount) }, 0.95),
            disk: percentile(qualifying.map { Double($0.totalDiskReadBytes &+ $0.totalDiskWriteBytes) }, 0.95),
            pageins: percentile(qualifying.map { Double($0.totalPageins) }, 0.95)
        )
    }

    private func percentile(_ raw: [Double], _ p: Double) -> Double {
        let xs = raw.sorted()
        guard !xs.isEmpty else { return 0 }
        let pos = max(0, min(Double(xs.count - 1), p * Double(xs.count - 1)))
        let lo = Int(pos.rounded(.down))
        let hi = Int(pos.rounded(.up))
        if lo == hi { return xs[lo] }
        let frac = pos - Double(lo)
        return xs[lo] * (1 - frac) + xs[hi] * frac
    }

    private func normalize(_ value: Double, _ p95: Double) -> Double {
        guard p95 > 0 else { return 0 }
        return min(value / p95, 1.5)
    }

    // MARK: - Pattern derivation

    private func derivePatterns(samples: [SamplePoint], top: [Suspect], all: [Suspect]) -> PatternFlags {
        let thermalThrottle = thermalThrottle(samples: samples)
        let fanSpike = fanSpike(samples: samples)
        let memSpike = memoryPressureSpike(samples: samples)
        let pair = correlatedWriterReader(samples: samples)
        return PatternFlags(
            correlatedWriterReader: pair,
            thermalThrottle: thermalThrottle,
            fanSpike: fanSpike,
            memoryPressureSpike: memSpike
        )
    }

    private func thermalThrottle(samples: [SamplePoint]) -> Bool {
        guard !samples.isEmpty else { return false }
        let serious = samples.filter { $0.thermalState >= 2 }.count
        return Double(serious) / Double(samples.count) > 0.5
    }

    private func fanSpike(samples: [SamplePoint]) -> Bool {
        let allRPM = samples.flatMap(\.fanRPM)
        guard let max = allRPM.max(), max > 0 else { return false }
        return max >= 4500
    }

    private func memoryPressureSpike(samples: [SamplePoint]) -> Bool {
        guard let peak = samples.map(\.memoryPressurePct).max() else { return false }
        return peak > 80
    }

    private func correlatedWriterReader(samples: [SamplePoint]) -> PatternFlags.CorrelatedPair? {
        // Per sample, find the pid with the largest writes and the pid with
        // the largest reads. Tally how often a (writer, reader) pair appears
        // *together* in the same sample, and how many bytes they exchanged.
        struct Tally {
            var writerName: String
            var readerName: String
            var samples: Int
            var writerBytes: UInt64
            var readerBytes: UInt64
        }
        var tallies: [String: Tally] = [:]
        for sample in samples {
            guard let writer = sample.processes.max(by: { $0.diskWriteBytesDelta < $1.diskWriteBytesDelta }),
                  let reader = sample.processes.max(by: { $0.diskReadBytesDelta < $1.diskReadBytesDelta }),
                  writer.pid != reader.pid,
                  writer.diskWriteBytesDelta > 50 * 1024 * 1024,
                  reader.diskReadBytesDelta > 50 * 1024 * 1024
            else { continue }
            let key = "\(writer.pid)|\(reader.pid)"
            var tally = tallies[key] ?? Tally(
                writerName: writer.name,
                readerName: reader.name,
                samples: 0,
                writerBytes: 0,
                readerBytes: 0
            )
            tally.samples += 1
            tally.writerBytes &+= writer.diskWriteBytesDelta
            tally.readerBytes &+= reader.diskReadBytesDelta
            tallies[key] = tally
        }
        guard let (key, tally) = tallies.max(by: { $0.value.samples < $1.value.samples }),
              tally.samples >= max(2, samples.count / 4) else { return nil }
        let parts = key.split(separator: "|")
        let writerPid = Int32(parts[0]) ?? 0
        let readerPid = Int32(parts[1]) ?? 0
        return PatternFlags.CorrelatedPair(
            writer: .init(pid: writerPid, name: tally.writerName),
            reader: .init(pid: readerPid, name: tally.readerName),
            writerBytes: tally.writerBytes,
            readerBytes: tally.readerBytes
        )
    }
}
