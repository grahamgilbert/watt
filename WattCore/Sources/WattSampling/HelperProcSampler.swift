import Foundation
import WattAnalysis
import WattHelperClient
import WattHelperProtocol

/// Pulls per-process telemetry from the privileged helper. The helper runs
/// as root via launchd, so it sees Endpoint Security extension processes
/// (CrowdStrike Falcon, Cyberhaven, etc.) that an unprivileged client like
/// `ProcSampler` cannot enumerate.
///
/// Computes deltas the same way `ProcSampler` does — per-(pid, start
/// abstime) prior snapshot, so pid reuse never produces nonsense numbers.
public actor HelperProcSampler {
    private struct PriorKey: Hashable {
        var pid: Int32
        var startAbs: UInt64
    }
    private struct Prior {
        var userTime: UInt64
        var systemTime: UInt64
        var energyNJ: UInt64
        var billedEnergy: UInt64
        var diskRead: UInt64
        var diskWritten: UInt64
        var pageins: UInt64
    }
    private var priors: [PriorKey: Prior] = [:]

    private let client: HelperClient

    public init(client: HelperClient = HelperClient()) {
        self.client = client
    }

    public func read() async -> [ProcessPoint] {
        let snapshot: [HelperProcessInfo]
        do {
            snapshot = try await client.listProcesses()
        } catch {
            return []
        }

        var results: [ProcessPoint] = []
        var freshPriors: [PriorKey: Prior] = [:]

        for info in snapshot where info.pid > 0 {
            let key = PriorKey(pid: info.pid, startAbs: info.startAbsTime)
            let prior = priors[key]
            let prevTotalCPU = prior.map { $0.userTime &+ $0.systemTime } ?? 0
            let curTotalCPU = info.userTimeNs &+ info.systemTimeNs
            let cpuDeltaNs = curTotalCPU &- prevTotalCPU
            let cpuDeltaSec = Double(cpuDeltaNs) / 1_000_000_000.0
            let energyDelta = info.energyNanojoules &- (prior?.energyNJ ?? info.energyNanojoules)
            let billedDelta = info.billedEnergyNanojoules &- (prior?.billedEnergy ?? info.billedEnergyNanojoules)
            let readDelta = info.diskReadBytes &- (prior?.diskRead ?? info.diskReadBytes)
            let writeDelta = info.diskWriteBytes &- (prior?.diskWritten ?? info.diskWriteBytes)
            let pageinsDelta = info.pageins &- (prior?.pageins ?? info.pageins)

            // Skip the very first observation so we don't emit a zero-baseline
            // delta as a real reading.
            if prior != nil {
                results.append(ProcessPoint(
                    pid: info.pid,
                    name: info.name,
                    bundleID: info.bundleID,
                    executablePath: info.executablePath,
                    cpuTimeDelta: max(cpuDeltaSec, 0),
                    energyNanojoulesDelta: energyDelta,
                    billedEnergyDelta: billedDelta,
                    diskReadBytesDelta: readDelta,
                    diskWriteBytesDelta: writeDelta,
                    pageinsDelta: pageinsDelta,
                    residentBytes: info.residentBytes
                ))
            }

            freshPriors[key] = Prior(
                userTime: info.userTimeNs,
                systemTime: info.systemTimeNs,
                energyNJ: info.energyNanojoules,
                billedEnergy: info.billedEnergyNanojoules,
                diskRead: info.diskReadBytes,
                diskWritten: info.diskWriteBytes,
                pageins: info.pageins
            )
        }
        priors = freshPriors
        return results
    }
}
