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
    var memoryComparisonAvailable=true
    var memoryComparisonSegment:String?
    var memoryComparisonSource:String?
    var readBytes:UInt64=0
    var writtenBytes:UInt64=0
    var ioSamples=0
    var energyJoules=0.0
    var energyCoveredSeconds=0.0
    var peakPower:Double?
    var network=ProcessNetworkTotals()
    var averagePower:Double? {energyCoveredSeconds>0 ? energyJoules/energyCoveredSeconds : nil}
    var id:String {process.id}
    var averageCPU:Double? {cpuCoveredSeconds>0 ? cpuSeconds/cpuCoveredSeconds*100 : nil}
    var memoryChange:Int64? {
        guard memoryComparisonAvailable,samples>1,let firstMemory,let lastMemory,
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
            // The same recording gaps apply to every process in this frame.
            // Find their latest end once rather than scanning them per row.
            let memoryGapEnd=gaps.lazy.filter {$0.start<f.time}.map {$0.end ?? .distantFuture}.max()
            // Totals only use fully contained, known intervals. Legacy records retain gauges/peaks.
            let validInterval=elapsed.isFinite && elapsed>0 && intervalStart>=range.start && !gaps.contains { gap in
                gap.start < f.time && (gap.end ?? .distantFuture)>intervalStart
            }
            for p in f.processes {
                var summary=result[p.id] ?? ProcessSummary(process:p,firstSeen:f.time,lastSeen:f.time,firstMemory:p.memory)
                if summary.samples==0 {summary.memoryComparisonSegment=f.segment;summary.memoryComparisonSource=p.metricSource}
                else if summary.memoryComparisonSegment != f.segment || summary.memoryComparisonSource != p.metricSource
                    || memoryGapEnd.map({$0>summary.firstSeen}) == true {
                    summary.memoryComparisonAvailable=false
                }
                if p.memory == nil {summary.memoryComparisonAvailable=false}
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
        for (capture,_) in networkCaptures(frames,range:range,gaps:gaps) {
            for task in capture.tasks {
                var summary=result[task.id] ?? ProcessSummary(process:networkIdentity(task),firstSeen:capture.endedAt,lastSeen:capture.endedAt)
                summary.firstSeen=min(summary.firstSeen,capture.endedAt)
                summary.lastSeen=max(summary.lastSeen,capture.endedAt)
                summary.network.add(received:task.receivedBytes,sent:task.sentBytes,capture:capture)
                result[task.id]=summary
            }
        }
        return Array(result.values)
    }
    static func networkIdentity(_ task:ProcessNetworkTask)->ProcessRow {
        ProcessRow(pid:task.pid,parent:task.parent,start:task.start,name:task.name,cpu:nil,memory:nil,growth:nil,read:nil,written:nil,
                   applicationID:task.applicationID,applicationName:task.applicationName,userID:task.userID,metricSource:"network")
    }
    static func networkGroups(_ frames:[Frame],range:DateInterval,gaps:[RecordingGap],isCancelled:()->Bool = {false})->[ProcessNetworkGroup] {
        var groups:[String:ProcessNetworkGroup]=[:]
        for (capture,frame) in networkCaptures(frames,range:range,gaps:gaps) {
            if isCancelled() {return []}
            let lookup=Dictionary(frame.processes.map {($0.pid,$0)},uniquingKeysWith:{$0.start>$1.start ? $0 : $1})
            for tasks in Dictionary(grouping:capture.tasks,by:{networkGroupIdentity($0,lookup:lookup).id}).values {
                guard let first=tasks.first else {continue}
                let identity=networkGroupIdentity(first,lookup:lookup)
                var group=groups[identity.id] ?? ProcessNetworkGroup(id:identity.id,name:identity.name)
                for task in tasks {
                    var process=networkIdentity(task)
                    if identity.id.hasPrefix("app:") {process.applicationID=String(identity.id.dropFirst(4));process.applicationName=identity.name}
                    group.members[task.id]=process
                }
                let reads=tasks.compactMap(\.receivedBytes),writes=tasks.compactMap(\.sentBytes)
                group.isPartial = group.isPartial || reads.count<tasks.count || writes.count<tasks.count
                group.hasUnattributedProcesses = group.hasUnattributedProcesses || capture.unmatchedProcesses>0
                group.totals.add(received:sumNetworkBytes(reads),sent:sumNetworkBytes(writes),capture:capture)
                groups[identity.id]=group
            }
        }
        return Array(groups.values)
    }
    static func networkGroupID(_ task:ProcessNetworkTask)->String {
        if let id=task.applicationID,!id.isEmpty {return "app:"+id}
        return "process:"+task.id
    }
    static func networkGroupName(_ task:ProcessNetworkTask)->String {
        if let id=task.applicationID,!id.isEmpty {return task.applicationName ?? id}
        return task.name
    }
    private static func networkGroupIdentity(_ task:ProcessNetworkTask,lookup:[Int32:ProcessRow])->ProcessApplicationIdentity {
        var process=networkIdentity(task),visited=Set<Int32>()
        for _ in 0..<64 {
            if let id=process.applicationID,!id.isEmpty {return ProcessApplicationIdentity(id:"app:"+id,name:process.applicationName ?? id)}
            guard visited.insert(process.pid).inserted,let parent=lookup[process.parent],parent.start<=process.start else {break}
            process=parent
        }
        return ProcessApplicationIdentity(id:"process:"+task.id,name:task.name)
    }
    private static func sumNetworkBytes(_ values:[UInt64])->UInt64? {
        guard !values.isEmpty else {return nil}
        var total:UInt64=0
        for value in values {
            let next=total.addingReportingOverflow(value)
            guard !next.overflow else {return nil}
            total=next.partialValue
        }
        return total
    }
    private static func networkCaptures(_ frames:[Frame],range:DateInterval,gaps:[RecordingGap])->[(ProcessNetworkSample,Frame)] {
        var seen=Set<String>(),captures:[(ProcessNetworkSample,Frame)]=[]
        for frame in frames {
            guard let capture=frame.processNetwork,!capture.id.isEmpty,capture.isFresh(at:frame.time),
                  capture.startedAt>=range.start,capture.endedAt<=range.end,
                  capture.startedAt<capture.endedAt,
                  abs(capture.endedAt.timeIntervalSince(capture.startedAt)-capture.elapsed)<=2,
                  !gaps.contains(where:{$0.start<capture.endedAt && ($0.end ?? .distantFuture)>capture.startedAt}),
                  seen.insert(capture.id).inserted else {continue}
            captures.append((capture,frame))
        }
        return captures.sorted {$0.0.endedAt == $1.0.endedAt ? $0.0.id<$1.0.id : $0.0.endedAt<$1.0.endedAt}
    }
}

struct ProcessNetworkTotals {
    private(set) var receivedBytes:UInt64?
    private(set) var sentBytes:UInt64?
    private(set) var receiveCoveredSeconds=0.0
    private(set) var sendCoveredSeconds=0.0
    private(set) var peakDownloadRate:Double?
    private(set) var peakUploadRate:Double?
    private(set) var captures=0
    private var receiveEnd:Date?
    private var sendEnd:Date?
    private var receiveOverflow=false
    private var sendOverflow=false
    init() {}
    var averageDownloadRate:Double? {receivedBytes.flatMap {receiveCoveredSeconds>0 ? Double($0)/receiveCoveredSeconds : nil}}
    var averageUploadRate:Double? {sentBytes.flatMap {sendCoveredSeconds>0 ? Double($0)/sendCoveredSeconds : nil}}
    mutating func add(received:UInt64?,sent:UInt64?,capture:ProcessNetworkSample) {
        guard capture.elapsed.isFinite,capture.elapsed>0,capture.startedAt<capture.endedAt else {return}
        var accepted=false
        if let received,receiveEnd.map({capture.startedAt >= $0}) ?? true {
            let next=(receivedBytes ?? 0).addingReportingOverflow(received)
            receiveOverflow = receiveOverflow || next.overflow
            receivedBytes=receiveOverflow ? nil : next.partialValue
            receiveCoveredSeconds+=capture.elapsed
            let rate=Double(received)/capture.elapsed
            peakDownloadRate=max(peakDownloadRate ?? rate,rate)
            receiveEnd=capture.endedAt;accepted=true
        }
        if let sent,sendEnd.map({capture.startedAt >= $0}) ?? true {
            let next=(sentBytes ?? 0).addingReportingOverflow(sent)
            sendOverflow = sendOverflow || next.overflow
            sentBytes=sendOverflow ? nil : next.partialValue
            sendCoveredSeconds+=capture.elapsed
            let rate=Double(sent)/capture.elapsed
            peakUploadRate=max(peakUploadRate ?? rate,rate)
            sendEnd=capture.endedAt;accepted=true
        }
        if accepted {captures+=1}
    }
}

struct ProcessNetworkGroup:Identifiable {
    let id:String
    var name:String
    var members:[String:ProcessRow]=[:]
    var totals=ProcessNetworkTotals()
    var isPartial=false
    var hasUnattributedProcesses=false
}
