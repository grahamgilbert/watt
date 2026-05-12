import Darwin
import Foundation
import WattSamplingC

public actor HostStatsSampler {
    private var prevCpuTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []

    public init() {}

    public func read() -> HostStatsReading {
        let cpu = readCPU()
        let mem = readMemory()
        return HostStatsReading(
            systemCPUUsage: cpu,
            memoryPressurePct: mem.pressurePct,
            memoryUsedBytes: mem.usedBytes
        )
    }

    private func readCPU() -> Double {
        var cpuCount: natural_t = 0
        var infoArray: processor_cpu_load_info_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = watt_host_processor_load(&cpuCount, &infoArray, &infoCount)
        guard kr == KERN_SUCCESS, let infoArray else { return 0 }
        defer {
            let address = vm_address_t(UInt(bitPattern: infoArray))
            watt_vm_deallocate_info(address, infoCount)
        }
        let infos = UnsafeBufferPointer(start: infoArray, count: Int(cpuCount))
        var usages: [Double] = []
        var nextPrev: [(UInt64, UInt64, UInt64, UInt64)] = []
        for (i, info) in infos.enumerated() {
            let user = UInt64(info.cpu_ticks.0)
            let system = UInt64(info.cpu_ticks.1)
            let idle = UInt64(info.cpu_ticks.2)
            let nice = UInt64(info.cpu_ticks.3)
            nextPrev.append((user, system, idle, nice))
            if i < prevCpuTicks.count {
                let prev = prevCpuTicks[i]
                let dUser = user &- prev.user
                let dSystem = system &- prev.system
                let dIdle = idle &- prev.idle
                let dNice = nice &- prev.nice
                let total = dUser &+ dSystem &+ dIdle &+ dNice
                let busy = dUser &+ dSystem &+ dNice
                if total > 0 {
                    usages.append(Double(busy) / Double(total))
                }
            }
        }
        prevCpuTicks = nextPrev.map { (user: $0.0, system: $0.1, idle: $0.2, nice: $0.3) }
        guard !usages.isEmpty else { return 0 }
        return usages.reduce(0, +) / Double(usages.count)
    }

    private struct MemoryReading {
        var pressurePct: Double
        var usedBytes: UInt64
    }

    private func readMemory() -> MemoryReading {
        var stats = vm_statistics64()
        let kr = watt_host_vm_statistics64(&stats)
        guard kr == KERN_SUCCESS else {
            return MemoryReading(pressurePct: 0, usedBytes: 0)
        }
        let pageSize = watt_page_size()
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let internalPages = UInt64(stats.internal_page_count) * pageSize
        let used = active &+ wired &+ compressed
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let pressure = totalBytes > 0
            ? min(100.0, Double(used) / Double(totalBytes) * 100.0)
            : 0
        _ = internalPages
        return MemoryReading(pressurePct: pressure, usedBytes: used)
    }
}
