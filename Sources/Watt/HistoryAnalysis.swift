import Foundation

enum HistoryQueryError:LocalizedError {
    case tooBroad
    var errorDescription:String? {"This interval contains too much detailed data. Choose a shorter window; samples have not been discarded or downsampled."}
}
struct ProcessSummary:Identifiable {
    var process:ProcessRow
    var firstSeen:Date
    var lastSeen:Date
    var samples=0
    var peakCPU:Double?
    var cpuSeconds=0.0
    var cpuCoveredSeconds=0.0
    var peakMemory:UInt64?
    var firstMemory:UInt64?
    var lastMemory:UInt64?
    var readBytes:UInt64=0
    var writtenBytes:UInt64=0
    var ioSamples=0
    var energyJoules=0.0
    var energyCoveredSeconds=0.0
    var peakPower:Double?
    var averagePower:Double? {energyCoveredSeconds>0 ? energyJoules/energyCoveredSeconds : nil}
    var id:String {process.id}
    var averageCPU:Double? {cpuCoveredSeconds>0 ? cpuSeconds/cpuCoveredSeconds*100 : nil}
    var memoryChange:Int64? {
        guard samples>1,let firstMemory,let lastMemory,
              firstMemory<=UInt64(Int64.max),lastMemory<=UInt64(Int64.max) else {return nil}
        return Int64(lastMemory)-Int64(firstMemory)
    }
}
enum HistoryAnalysis {
    static func snapshot(at time:Date,frames:[Frame],gaps:[RecordingGap]) -> Frame? {
        guard !gaps.contains(where:{$0.contains(time)}),let nearest=frames.min(by:{abs($0.time.timeIntervalSince(time))<abs($1.time.timeIntervalSince(time))}) else {return nil}
        // Do not claim a distant retained observation describes an unrecorded time.
        let tolerance=max(1,(nearest.cadence ?? nearest.elapsed ?? 5)/2+0.5)
        return abs(nearest.time.timeIntervalSince(time))<=tolerance ? nearest : nil
    }
    static func summarize(_ frames:[Frame],range:DateInterval,gaps:[RecordingGap]) -> [ProcessSummary] {
        var result:[String:ProcessSummary]=[:]
        for f in frames.sorted(by:{$0.time<$1.time}) where f.time>=range.start && f.time<=range.end {
            let elapsed=f.elapsed ?? 0
            let intervalStart=f.time.addingTimeInterval(-elapsed)
            // Totals only use fully contained, known intervals. Legacy records retain gauges/peaks.
            let validInterval=elapsed.isFinite && elapsed>0 && intervalStart>=range.start && !gaps.contains { gap in
                gap.start < f.time && (gap.end ?? .distantFuture)>intervalStart
            }
            for p in f.processes {
                var summary=result[p.id] ?? ProcessSummary(process:p,firstSeen:f.time,lastSeen:f.time,firstMemory:p.memory)
                summary.process=p;summary.lastSeen=f.time;summary.samples+=1
                if let memory=p.memory {summary.peakMemory=max(summary.peakMemory ?? memory,memory)}
                // Preserve unavailable endpoints. Substituting the nearest measured
                // footprint would turn a restricted reading into invented growth.
                summary.lastMemory=p.memory
                if let cpu=p.cpu {summary.peakCPU=max(summary.peakCPU ?? cpu,cpu)}
                if let power=p.cpuPowerWatts(elapsed:f.elapsed) {summary.peakPower=max(summary.peakPower ?? power,power)}
                if validInterval {
                    if let energy=p.energyNanojoules {
                        summary.energyJoules += Double(energy)/1e9
                        summary.energyCoveredSeconds += elapsed
                    }
                    if let cpu=p.cpu {summary.cpuSeconds += cpu/100*elapsed;summary.cpuCoveredSeconds += elapsed}
                    if let read=p.read,let write=p.written {summary.readBytes += read;summary.writtenBytes += write;summary.ioSamples += 1}
                }
                result[p.id]=summary
            }
        }
        return Array(result.values)
    }
}
