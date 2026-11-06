import Foundation
import CTelemetry

struct ProcessApplicationIdentity:Equatable {
    let id:String
    let name:String
}

// Path and bundle metadata are cached in memory, never persisted in recorded frames.
// Each executable path is queried once per observed PID lifetime.
final class ProcessApplicationResolver {
    private struct CachedIdentity {var identity:ProcessApplicationIdentity?}
    private var processes:[String:CachedIdentity]=[:]
    private var bundles:[String:CachedIdentity]=[:]
    func identity(for process:WattProcess)->ProcessApplicationIdentity? {
        let key="\(process.pid):\(process.start)"
        if let cached=processes[key] {return cached.identity}
        let capacity=4096
        var path=[CChar](repeating:0,count:capacity)
        var identity:ProcessApplicationIdentity?
        if watt_process_path(process.pid,&path,Int32(capacity))>0 {
            identity=Self.outermostApplication(in:String(cString:path)) {url in
                if let cached=self.bundles[url.path] {return cached.identity}
                let result=Bundle(url:url).flatMap {bundle -> ProcessApplicationIdentity? in
                    guard let id=bundle.bundleIdentifier,!id.isEmpty else {return nil}
                    let name=(bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey:"CFBundleName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    return ProcessApplicationIdentity(id:id,name:name)
                }
                self.bundles[url.path]=CachedIdentity(identity:result)
                return result
            }
        }
        processes[key]=CachedIdentity(identity:identity)
        return identity
    }
    func retain(processIDs:Set<String>) {
        processes=processes.filter {processIDs.contains($0.key)}
        if bundles.count>1024 {bundles.removeAll(keepingCapacity:true)}
    }
    static func outermostApplication(in executablePath:String,resolve:(URL)->ProcessApplicationIdentity?)->ProcessApplicationIdentity? {
        var url=URL(fileURLWithPath:"/")
        for component in URL(fileURLWithPath:executablePath).standardizedFileURL.pathComponents.dropFirst() {
            url.appendPathComponent(component)
            if url.pathExtension.lowercased()=="app",let identity=resolve(url) {return identity}
        }
        return nil
    }
}

struct AppPowerGroup:Identifiable {
    let id:String
    var name:String
    var processes:[ProcessRow]=[]
    var cpu:Double?
    var cpuPowerWatts:Double?
    var measuredEnergyProcesses=0
    var measuredCPUProcesses=0
    var hasUnattributedProcesses=false
    var observedProcesses:Int {processes.count}
    var isPartial:Bool {measuredEnergyProcesses<observedProcesses}
}
struct AppEnergySummary:Identifiable {
    let id:String
    var name:String
    var energyJoules=0.0
    var energyCoveredSeconds=0.0
    var peakPower:Double?
    var isPartial=false
    var hasUnattributedProcesses=false
    var observedProcessIDs=Set<String>()
    var observedProcesses:Int {observedProcessIDs.count}
    var averagePower:Double? {energyCoveredSeconds>0 ? energyJoules/energyCoveredSeconds : nil}
}

enum AppPowerGrouping {
    static func snapshot(_ frame:Frame)->[AppPowerGroup] {
        let lookup=Dictionary(frame.processes.map {($0.pid,$0)},uniquingKeysWith:{$0.start>$1.start ? $0 : $1})
        var groups:[String:AppPowerGroup]=[:]
        for process in frame.processes {
            let identity=identity(for:process,lookup:lookup)
            var group=groups[identity.id] ?? AppPowerGroup(id:identity.id,name:identity.name,hasUnattributedProcesses:frame.denied>0)
            group.processes.append(process)
            if let cpu=process.cpu,cpu.isFinite {group.cpu=(group.cpu ?? 0)+cpu;group.measuredCPUProcesses+=1}
            if let power=process.cpuPowerWatts(elapsed:frame.elapsed) {
                group.cpuPowerWatts=(group.cpuPowerWatts ?? 0)+power
                group.measuredEnergyProcesses+=1
            }
            groups[identity.id]=group
        }
        return Array(groups.values).sorted {($0.cpuPowerWatts ?? -1)>($1.cpuPowerWatts ?? -1)}
    }
    static func summarize(_ frames:[Frame],range:DateInterval,gaps:[RecordingGap])->[AppEnergySummary] {
        var result:[String:AppEnergySummary]=[:]
        for frame in frames.sorted(by:{$0.time<$1.time}) where frame.time>=range.start && frame.time<=range.end {
            let elapsed=frame.elapsed ?? 0
            let intervalStart=frame.time.addingTimeInterval(-elapsed)
            let valid=elapsed.isFinite && elapsed>0 && intervalStart>=range.start
                && !gaps.contains {$0.start<frame.time && ($0.end ?? .distantFuture)>intervalStart}
            for group in snapshot(frame) {
                var summary=result[group.id] ?? AppEnergySummary(id:group.id,name:group.name)
                summary.observedProcessIDs.formUnion(group.processes.map(\.id))
                summary.isPartial = summary.isPartial || group.isPartial
                summary.hasUnattributedProcesses = summary.hasUnattributedProcesses || group.hasUnattributedProcesses
                if let power=group.cpuPowerWatts {summary.peakPower=max(summary.peakPower ?? power,power)}
                if valid,let power=group.cpuPowerWatts {
                    // Count each app's covered wall interval once, not once per helper.
                    summary.energyJoules += power*elapsed
                    summary.energyCoveredSeconds += elapsed
                }
                result[group.id]=summary
            }
        }
        return Array(result.values).sorted {$0.energyJoules>$1.energyJoules}
    }
    private static func identity(for process:ProcessRow,lookup:[Int32:ProcessRow])->ProcessApplicationIdentity {
        var candidate=process
        var visited=Set<Int32>()
        for _ in 0..<64 {
            if let id=candidate.applicationID,!id.isEmpty {
                return ProcessApplicationIdentity(id:"app:"+id,name:candidate.applicationName ?? id)
            }
            guard visited.insert(candidate.pid).inserted,let parent=lookup[candidate.parent],parent.start<=candidate.start else {break}
            candidate=parent
        }
        // Unknown daemons/tools stay separate; names are never treated as ownership evidence.
        return ProcessApplicationIdentity(id:"process:"+process.id,name:process.name)
    }
}
