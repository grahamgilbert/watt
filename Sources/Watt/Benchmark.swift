import Foundation
import Darwin

private func cpuTime() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

func runBenchmark() {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("watt-benchmark-" + UUID().uuidString + ".sqlite").path
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath:path+suffix) } }
    do {
        let store = try HistoryStore(path:path)
        let collector = Collector(); _ = collector.sample()
        let start = ProcessInfo.processInfo.systemUptime, cpuStart = cpuTime()
        var times:[Double]=[], count=0, processes=0, unavailable=0
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval:5)
            let began=ProcessInfo.processInfo.systemUptime
            if let frame=collector.sample() {try store.append(frame); count += 1; processes=frame.processes.count; unavailable=frame.denied}
            times.append(ProcessInfo.processInfo.systemUptime-began)
        }
        try store.checkpoint()
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        let cpu=cpuTime()-cpuStart
        let sorted=times.sorted()
        let report:[String:Any] = ["duration_seconds":elapsed,"frames":count,"cadence_seconds":5,"last_observed_processes":processes,"last_unavailable_queries":unavailable,"cpu_percent_of_one_core":cpu/elapsed*100,"sample_and_write_median_ms":sorted[sorted.count/2]*1000,"sample_and_write_max_ms":sorted.last!*1000,"database_bytes":store.diskBytes,"payload_bytes":store.payloadBytes,"payload_gib_per_day_at_observed_rate":Double(store.payloadBytes)/elapsed*86400/1073741824,"scope":"60-second recorder-only benchmark; excludes GUI, helper, battery-life claims and causal build overhead"]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    } catch { fputs("Benchmark failed: \(error.localizedDescription)\n",stderr); exit(1) }
}
