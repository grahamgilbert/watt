import AppKit
import Darwin
import Foundation
import WattAnalysis
import WattSamplingC

public actor ProcSampler {
    public init() {}

    /// Per-pid prior values, keyed by `(pid, ri_proc_start_abstime)` so that
    /// pid reuse never produces nonsense deltas.
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
    /// Cache of pid -> bundleID. NSRunningApplication does Launch Services
    /// roundtrips that we'd rather not pay every tick.
    private var bundleCache: [Int32: String?] = [:]
    /// Cache of pid -> executable path. proc_pidpath is a syscall; paths
    /// don't change for the lifetime of a process.
    private var pathCache: [Int32: String?] = [:]

    public func read() -> ProcessReading {
        var processes: [ProcessPoint] = []
        let pidCount = Int(watt_proc_listallpids(nil, 0))
        guard pidCount > 0 else { return ProcessReading(processes: []) }
        var pids = [Int32](repeating: 0, count: pidCount * 2)
        let bytesPerPid = Int32(MemoryLayout<Int32>.size)
        let actualBytes = pids.withUnsafeMutableBufferPointer { ptr -> Int32 in
            watt_proc_listallpids(ptr.baseAddress, Int32(ptr.count) * bytesPerPid)
        }
        let actualCount = Int(max(actualBytes, 0)) / Int(bytesPerPid)
        guard actualCount > 0 else { return ProcessReading(processes: []) }
        let validPids = Array(pids.prefix(actualCount))
        var freshPriors: [PriorKey: Prior] = [:]

        for pid in validPids where pid > 0 {
            let name = readName(for: pid)
            let path = cachedPath(for: pid)
            var info = rusage_info_v6()
            let rusageResult = watt_proc_pid_rusage_v6(pid, &info)

            if rusageResult == 0 {
                // We have full per-process accounting (typically processes
                // we own). Compute deltas against the prior snapshot.
                let key = PriorKey(pid: pid, startAbs: info.ri_proc_start_abstime)
                let prior = priors[key]
                let prevTotalCPU = prior.map { $0.userTime &+ $0.systemTime } ?? 0
                let curTotalCPU = info.ri_user_time &+ info.ri_system_time
                let cpuDeltaNs = curTotalCPU &- prevTotalCPU
                let cpuDeltaSec = Double(cpuDeltaNs) / 1_000_000_000.0
                let energyDelta = info.ri_energy_nj &- (prior?.energyNJ ?? info.ri_energy_nj)
                let billedDelta = info.ri_billed_energy &- (prior?.billedEnergy ?? info.ri_billed_energy)
                let readDelta = info.ri_diskio_bytesread &- (prior?.diskRead ?? info.ri_diskio_bytesread)
                let writeDelta = info.ri_diskio_byteswritten &- (prior?.diskWritten ?? info.ri_diskio_byteswritten)
                let pageinsDelta = info.ri_pageins &- (prior?.pageins ?? info.ri_pageins)

                if prior != nil {
                    processes.append(ProcessPoint(
                        pid: pid,
                        name: name,
                        bundleID: bundleID(forPID: pid),
                        executablePath: path,
                        cpuTimeDelta: max(cpuDeltaSec, 0),
                        energyNanojoulesDelta: energyDelta,
                        billedEnergyDelta: billedDelta,
                        diskReadBytesDelta: readDelta,
                        diskWriteBytesDelta: writeDelta,
                        pageinsDelta: pageinsDelta,
                        residentBytes: info.ri_resident_size
                    ))
                }
                freshPriors[key] = Prior(
                    userTime: info.ri_user_time,
                    systemTime: info.ri_system_time,
                    energyNJ: info.ri_energy_nj,
                    billedEnergy: info.ri_billed_energy,
                    diskRead: info.ri_diskio_bytesread,
                    diskWritten: info.ri_diskio_byteswritten,
                    pageins: info.ri_pageins
                )
            } else {
                // proc_pid_rusage returns -1 (typically EPERM) for processes
                // we don't own — including the root-owned daemons that
                // matter most: CrowdStrike Falcon, Cyberhaven, management agents, etc.
                // Record the existence of these so the agent matcher and
                // the periodic top-process leaderboard can flag them, even
                // though we have no per-tick CPU/energy deltas for them.
                processes.append(ProcessPoint(
                    pid: pid,
                    name: name,
                    bundleID: bundleID(forPID: pid),
                    executablePath: path,
                    cpuTimeDelta: 0,
                    energyNanojoulesDelta: 0,
                    billedEnergyDelta: 0,
                    diskReadBytesDelta: 0,
                    diskWriteBytesDelta: 0,
                    pageinsDelta: 0,
                    residentBytes: 0
                ))
            }
        }
        priors = freshPriors
        // Evict path cache entries for pids that no longer exist.
        let livePidSet = Set(validPids)
        pathCache = pathCache.filter { livePidSet.contains($0.key) }
        return ProcessReading(processes: processes)
    }

    private nonisolated func readName(for pid: Int32) -> String {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: 256)
        let len = watt_proc_name(pid, buffer, 256)
        return len > 0 ? String(cString: buffer) : "pid \(pid)"
    }

    private func cachedPath(for pid: Int32) -> String? {
        if let cached = pathCache[pid] { return cached }
        let resolved = readPath(for: pid)
        pathCache[pid] = resolved
        return resolved
    }

    private nonisolated func readPath(for pid: Int32) -> String? {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: 4096)
        let len = watt_proc_pidpath(pid, buffer, 4096)
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    private func bundleID(forPID pid: Int32) -> String? {
        if let cached = bundleCache[pid] { return cached }
        let resolved = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        bundleCache[pid] = resolved
        return resolved
    }
}
