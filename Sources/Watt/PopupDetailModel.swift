import Foundation
import WattEnergyProtocol

enum PopupDetailDestination:String,CaseIterable {
    case cpu,memory,network,disk,energy,battery
    init(item:PopupItemID) {
        switch item.rawValue {
        case "memory","memoryDetail":self = .memory
        case "network","download","upload":self = .network
        case "diskActivity","diskRead","diskWrite":self = .disk
        case "energy","processCPUPower","applicationCPUPower","energyImpact":self = .energy
        case "batteryFlow":self = .battery
        default:self = .cpu
        }
    }
    var title:String {
        switch self {
        case .cpu:return "CPU"
        case .memory:return "Memory"
        case .network:return "Network"
        case .disk:return "Process disk activity"
        case .energy:return "Energy"
        case .battery:return "Battery"
        }
    }
    func initialMode(item:PopupItemID)->String {
        switch self {
        case .memory:return item == .memoryDetail ? "Compression / swap" : "Footprint"
        case .network:return item == .upload ? "Upload" : "Download"
        case .disk:return item == .diskWrite ? "Writes" : "Reads"
        case .energy:return item == .energyImpact ? "Energy Impact" : "CPU power"
        default:return "CPU"
        }
    }
    func explorerSort(mode:String)->String {
        switch self {
        case .cpu:return "CPU"
        case .memory:return mode == "Growth" ? "Memory growth" : "Memory"
        case .network:return mode == "Upload" ? "Network sent" : "Network received"
        case .disk:return mode == "Writes" ? "Disk write" : "Disk read"
        case .energy:return mode == "Energy Impact" ? "Energy Impact" : "CPU energy"
        case .battery:return "CPU energy"
        }
    }
}

struct PopupExplorerContext {
    var item:PopupItemID
    var duration:Double
    var selectedTime:Date?
    var processID:String?
    var scope:String
    var sort:String
    var applicationID:String? = nil
    var range:DateInterval? = nil
    var intervalSummary=false

    static func detail(item:PopupItemID,duration:Double,selectedTime:Date?,sampleTime:Date?,graphRange:DateInterval?,
                       selection:PopupDetailRow?,scope:String,mode:String)->Self {
        let destination=PopupDetailDestination(item:item)
        let summary=destination == .memory && mode == "Growth"
        let cursor=selectedTime != nil || selection != nil ? sampleTime ?? selectedTime : nil
        var range=graphRange,window=duration
        // Memory's range delta ends at the displayed cursor, not at later
        // observations still visible to its right on the history graph.
        if summary,selectedTime != nil,let cursor,let original=graphRange {
            let end=min(original.end,max(original.start,cursor))
            range=DateInterval(start:original.start,end:end)
            window=max(1,end.timeIntervalSince(original.start))
        }
        return .init(item:item,duration:window,selectedTime:cursor,processID:selection?.process?.id,
                     scope:selection?.process != nil ? "Processes" : scope,sort:destination.explorerSort(mode:mode),
                     applicationID:selection?.applicationID,range:range,intervalSummary:summary)
    }
}

struct PopupDetailReadout:Identifiable {
    let title:String
    let value:String
    let unit:String
    let context:String
    var id:String {title}
}
struct PopupDetailFact:Identifiable {
    let title:String
    let value:String
    var id:String {title}
}
struct PopupDetailRow:Identifiable {
    let id:String
    let name:String
    let process:ProcessRow?
    var applicationID:String? = nil
    let primary:Double?
    let primaryText:String
    let secondaryText:String
    var children:[PopupDetailRow] = []
    var partial:Bool = false
}
struct PopupDetailChartPoint:Identifiable {
    let time:Date
    let value:Double
    let series:String
    let segment:String
    var id:String {"\(series):\(segment):\(time.timeIntervalSinceReferenceDate)"}
}
struct PopupDetailSelection {
    let row:PopupDetailRow
    let facts:[PopupDetailFact]
    let coverage:String
}

struct PopupDetailData {
    var sampleTime:Date?
    var readouts:[PopupDetailReadout] = []
    var facts:[PopupDetailFact] = []
    var rows:[PopupDetailRow] = []
    var columns:[String] = []
    var points:[PopupDetailChartPoint] = []
    var series:[String] = []
    var chartTitle=""
    var chartUnit=""
    var chartCeiling:Double?
    var signedChart=false
    var selection:PopupDetailSelection?
    var coverage=""
    var emptyTitle=""
    var emptyDetail=""
    var range:DateInterval?

    static func make(frame liveFrame:Frame?,frames suppliedFrames:[Frame],gaps:[RecordingGap],item:PopupItemID,
                     selectedTime:Date?,duration:Double,mode:String,scope:String,selectedRowID:String?,physicalMemory:UInt64)->Self {
        let family=PopupDetailDestination(item:item)
        let end=suppliedFrames.last?.time ?? liveFrame?.time
        let range=end.map {DateInterval(start:$0.addingTimeInterval(-max(1,duration)),end:$0)}
        let frames=range.map {range in suppliedFrames.filter {$0.time>=range.start && $0.time<=range.end}} ?? []
        let current=selectedTime.flatMap {HistoryAnalysis.snapshot(at:$0,frames:frames,gaps:gaps)} ?? (selectedTime == nil ? liveFrame : nil)
        var result=Self()
        result.range=frames.first.flatMap {first in frames.last.map {DateInterval(start:first.time,end:max(first.time,$0.time))}}
        guard let frame=current else {
            result.emptyTitle=selectedTime == nil ? "Waiting for a complete sample" : "No sample at this time"
            result.emptyDetail=selectedTime.flatMap {time in gaps.first {$0.contains(time)}?.reason} ?? "Missing readings are not treated as zero."
            // Keep the recorded graph visible while the cursor is in a gap.
            result.configureChart(frames:frames,gaps:gaps,family:family,mode:mode,selected:nil,physicalMemory:physicalMemory)
            return result
        }
        result.sampleTime=frame.time
        let usableElapsed=frame.elapsed.flatMap {$0.isFinite && $0>0 ? $0 : nil}
        let interval=usableElapsed.map {String(format:"%.2f-second sample",$0)} ?? "Sample interval unavailable"
        var presentationFrame=frame
        if family == .memory {presentationFrame.processes=memoryRangeRows(frame:frame,frames:frames,gaps:gaps)}
        let allRows=rows(frame:presentationFrame,family:family,mode:mode,scope:scope)
        let leading=allRows.first {$0.primary != nil}
        let selected=allRows.first {$0.id==selectedRowID} ?? allRows.lazy.flatMap(\.children).first {$0.id==selectedRowID}
        result.rows=Array(allRows.prefix(6))
        if let selected,!result.rows.contains(where:{$0.id==selected.id}),!result.rows.contains(where:{$0.children.contains(where:{$0.id==selected.id})}) {
            result.rows=Array(result.rows.prefix(5))+[selected]
        }
        switch family {
        case .cpu:
            result.readouts=[.init(title:"Machine CPU",value:decimal(frame.cpu,places:0),unit:"%",context:"100% = the whole machine"),
                             .init(title:"Busiest process",value:leading?.name ?? "—",unit:"",context:interval)]
            result.columns=[scope == "Applications" ? "Application / process" : "Process","CPU %",scope == "Applications" ? "Tasks" : "Memory"]
            result.coverage="Process CPU: 100% = one logical CPU · \(accessCoverage(frame))"
        case .memory:
            let percentage=physicalMemory>0 ? Double(frame.memory)/Double(physicalMemory)*100 : 0
            result.readouts=[.init(title:"Used memory",value:bytes(frame.memory),unit:"",context:"\(decimal(percentage,places:0))% of \(bytes(physicalMemory)) physical"),
                             .init(title:"Compressed",value:bytes(frame.compressed),unit:"",context:"Swap \(bytes(frame.swap))")]
            result.columns=["Process","Footprint","Δ range"]
            result.facts=[.init(title:"Compressed",value:bytes(frame.compressed)),.init(title:"Swap",value:bytes(frame.swap))]
            result.coverage="Δ range is observed footprint change; gaps or unavailable endpoints remain —"
        case .network:
            let receive=rateComponents(frame.download),send=rateComponents(frame.upload)
            result.readouts=[.init(title:"↓ Download",value:receive.0,unit:receive.1,context:interval),
                             .init(title:"↑ Upload",value:send.0,unit:send.1,context:"Physical interfaces")]
            result.columns=[scope == "Applications" ? "Application / process" : "Process","Download/s","Upload/s"]
            if let sample=networkSample(frame) {
                result.coverage="TCP/UDP process sample \(decimal(max(0,frame.time.timeIntervalSince(sample.endedAt)),places:1))s old · \(decimal(sample.elapsed,places:2))s interval · \(sample.unmatchedProcesses) unmatched"
            } else {
                let sample=frame.processNetwork
                switch sample?.status {
                case .waiting:result.emptyTitle="Waiting for process traffic"
                case .unsupported:result.emptyTitle="Process traffic unsupported"
                case .available where sample!.endedAt<frame.time.addingTimeInterval(-max(15,sample!.elapsed*2.5)):result.emptyTitle="Process traffic sample is stale"
                case .available,.unavailable:result.emptyTitle="Process traffic unavailable"
                case nil:result.emptyTitle="Process traffic not recorded"
                }
                result.emptyDetail=sample?.error ?? "This interval has aggregate traffic only. Missing process rates are not zero."
                result.coverage="Physical-interface rates and process TCP/UDP rates have different scopes"
            }
        case .disk:
            let read=popupDiskRate(frame,read:true),write=popupDiskRate(frame,read:false)
            let r=read.map(rateComponents),w=write.map(rateComponents)
            result.readouts=[.init(title:"↓ Reads",value:r?.0 ?? "—",unit:r?.1 ?? "",context:"Observed process I/O"),
                             .init(title:"↑ Writes",value:w?.0 ?? "—",unit:w?.1 ?? "",context:interval)]
            result.columns=["Process","Read/s","Write/s"]
            result.coverage="Process counters, not disk-device throughput · \(accessCoverage(frame))"
        case .energy:
            if mode == "Energy Impact" {
                result.readouts=[.init(title:"Leading process",value:leading?.name ?? "—",unit:"",context:"Apple-derived process score"),
                                 .init(title:"Energy Impact",value:leading?.primary.map {decimal($0,places:1)} ?? "—",unit:"",context:"Unitless · not watts")]
                result.columns=["Process","Impact","CPU %"]
                result.coverage=frame.energyImpact.map {"Process score · sample age \(decimal(max(0,frame.time.timeIntervalSince($0.endedAt)),places:1))s"} ?? "Energy Impact not recorded · enable the collector in Preferences"
            } else {
                let values=frame.processes.compactMap {$0.cpuPowerWatts(elapsed:frame.elapsed)}
                result.readouts=[.init(title:"Measured CPU power",value:values.isEmpty ? "—" : decimal(values.reduce(0,+),places:2),unit:values.isEmpty ? "" : "W",context:"Observed process subtotal · estimate"),
                                 .init(title:"Top contributor",value:leading?.name ?? "—",unit:"",context:"Excludes GPU and whole-device power")]
                result.columns=[scope == "Applications" ? "Application / process" : "Process","CPU W","CPU %"]
                result.coverage="CPU energy measured for \(values.count) / \(frame.processes.count) observed processes"
            }
        case .battery:
            let power=frame.power
            let usable=power?.hasUsableCurrent == true
            let flow=usable ? power!.watts : nil
            let direction=flow.map {$0 < -0.05 ? "Discharging" : $0 > 0.05 ? "Charging" : "Battery flow"} ?? "Battery flow"
            result.readouts=[.init(title:direction,value:flow.map {decimal(abs($0),places:1)} ?? "—",unit:usable ? "W" : "",context:"Battery electrical flow · estimate"),
                             .init(title:"Power source",value:power.map {$0.externalPower ? "External power" : "Battery"} ?? "—",unit:"",context:"CPU watts below are context only")]
            result.facts=[.init(title:"Voltage",value:power.map {decimal($0.volts,places:2)+" V"} ?? "—"),
                          .init(title:"Current",value:usable ? decimal(power!.amps,places:3)+" A" : "—")]
            result.columns=["CPU-power context","CPU W","CPU %"]
            result.coverage="CPU watts do not allocate battery discharge to processes"
        }
        if result.rows.isEmpty,result.emptyTitle.isEmpty {
            result.emptyTitle="No measured process values"
            result.emptyDetail="Restricted or missing counters remain unavailable."
        }
        result.configureChart(frames:frames,gaps:gaps,family:family,mode:mode,selected:selected ?? (family == .energy && mode == "Energy Impact" ? leading : nil),physicalMemory:physicalMemory)
        if let selected,let range {
            result.selection=selection(row:selected,frame:frame,frames:frames,range:range,gaps:gaps)
        }
        return result
    }

    private static func rows(frame:Frame,family:PopupDetailDestination,mode:String,scope:String)->[PopupDetailRow] {
        if family == .network {return networkRows(frame:frame,mode:mode,scope:scope)}
        if (family == .cpu || family == .energy && mode != "Energy Impact") && scope == "Applications" {
            return AppPowerGrouping.snapshot(frame).map {group in
                let power=group.cpuPowerWatts
                let primary=family == .cpu ? group.cpu : power
                return PopupDetailRow(id:group.id,name:group.name,process:nil,applicationID:group.id,primary:primary,
                    primaryText:primary.map {decimal($0,places:family == .cpu ? 1 : 2)} ?? "—",
                    secondaryText:family == .cpu ? "\(group.processes.count) processes" : group.cpu.map {decimal($0,places:1)} ?? "—",
                    children:group.processes.map {processRow($0,frame:frame,family:family,mode:mode)}.sorted {($0.primary ?? -1)>($1.primary ?? -1)},
                    partial:group.isPartial || group.hasUnattributedProcesses)
            }.sorted {($0.primary ?? -1)>($1.primary ?? -1)}
        }
        return frame.processes.map {processRow($0,frame:frame,family:family,mode:mode)}.sorted {
            guard let a=$0.primary else {return $1.primary == nil && $0.id<$1.id}
            guard let b=$1.primary else {return true}
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a>b
        }
    }
    private static func memoryRangeRows(frame current:Frame,frames:[Frame],gaps:[RecordingGap])->[ProcessRow] {
        struct Endpoint {
            var time:Date
            var segment:String?
            var memory:UInt64?
            var source:String?
            var count:Int
            var valid:Bool
        }
        let identities=Set(current.processes.map(\.id))
        var first:[String:Endpoint]=[:]
        for frame in frames where frame.time<=current.time {
            for process in frame.processes where identities.contains(process.id) {
                if var endpoint=first[process.id] {
                    endpoint.count+=1
                    endpoint.valid = endpoint.valid && endpoint.segment==frame.segment && endpoint.source==process.metricSource && process.memory != nil
                    first[process.id]=endpoint
                } else {first[process.id]=Endpoint(time:frame.time,segment:frame.segment,memory:process.memory,source:process.metricSource,count:1,valid:process.memory != nil)}
            }
        }
        return current.processes.map {process in
            var copy=process;copy.growth=nil
            guard let first=first[process.id],first.count>1,first.valid,
                  first.segment==current.segment,first.source==process.metricSource,
                  !gaps.contains(where:{$0.start<current.time && ($0.end ?? .distantFuture)>first.time}),
                  let start=first.memory,let end=process.memory,start<=UInt64(Int64.max),end<=UInt64(Int64.max) else {return copy}
            copy.growth=end>=start ? Int64(exactly:end-start) : Int64(exactly:start-end).map {-($0)}
            return copy
        }
    }
    private static func networkRows(frame:Frame,mode:String,scope:String)->[PopupDetailRow] {
        guard let sample=networkSample(frame) else {return []}
        let processes=Dictionary(frame.processes.map {($0.id,$0)},uniquingKeysWith:{$1})
        var rows:[PopupDetailRow]=[]
        for task in sample.tasks {
            let process=processes[task.id] ?? ProcessRow(pid:task.pid,parent:task.parent,start:task.start,name:task.name,cpu:nil,memory:nil,growth:nil,read:nil,written:nil,applicationID:task.applicationID,applicationName:task.applicationName,userID:task.userID,metricSource:sample.source)
            let primary=mode == "Upload" ? task.uploadRate(elapsed:sample.elapsed) : task.downloadRate(elapsed:sample.elapsed)
            let row=PopupDetailRow(id:task.id,name:task.name,process:process,primary:primary,
                                   primaryText:task.downloadRate(elapsed:sample.elapsed).map(fullRate) ?? "—",
                                   secondaryText:task.uploadRate(elapsed:sample.elapsed).map(fullRate) ?? "—",
                                   partial:task.receivedBytes == nil || task.sentBytes == nil)
            rows.append(row)
        }
        if scope == "Applications" {
            let identities=Dictionary(rows.map {($0.id,$0)},uniquingKeysWith:{$1})
            let range=DateInterval(start:sample.startedAt,end:sample.endedAt)
            rows=HistoryAnalysis.networkGroups([frame],range:range,gaps:[]).map {group in
                let download=group.totals.averageDownloadRate,upload=group.totals.averageUploadRate
                let children=group.members.keys.compactMap {identities[$0]}.sorted {($0.primary ?? -1)>($1.primary ?? -1)}
                return PopupDetailRow(id:group.id,name:group.name,process:nil,applicationID:group.id,primary:mode == "Upload" ? upload : download,
                                      primaryText:download.map(fullRate) ?? "—",secondaryText:upload.map(fullRate) ?? "—",children:children,partial:group.isPartial || group.hasUnattributedProcesses)
            }
        }
        return rows.sorted {$0.primary == $1.primary ? $0.id<$1.id : ($0.primary ?? -1)>($1.primary ?? -1)}
    }
    private static func processRow(_ process:ProcessRow,frame:Frame,family:PopupDetailDestination,mode:String)->PopupDetailRow {
        let primary:Double?,text:String,secondary:String
        switch family {
        case .cpu:
            primary=process.cpu;text=primary.map {decimal($0,places:1)} ?? "—";secondary=process.memory.map(bytes) ?? "—"
        case .memory:
            primary=mode == "Growth" ? process.growth.map(Double.init) : process.memory.map(Double.init)
            text=process.memory.map(bytes) ?? "—";secondary=process.growth.map(signedBytes) ?? "—"
        case .disk:
            primary=processRate(mode == "Writes" ? process.written : process.read,elapsed:frame.elapsed)
            text=processRate(process.read,elapsed:frame.elapsed).map(fullRate) ?? "—"
            secondary=processRate(process.written,elapsed:frame.elapsed).map(fullRate) ?? "—"
        case .energy where mode == "Energy Impact":
            primary=impact(process:process,frame:frame)
            text=primary.map {decimal($0,places:1)} ?? "—";secondary=process.cpu.map {decimal($0,places:1)} ?? "—"
        case .energy,.battery:
            primary=process.cpuPowerWatts(elapsed:frame.elapsed);text=primary.map {decimal($0,places:2)} ?? "—"
            secondary=process.cpu.map {decimal($0,places:1)} ?? "—"
        case .network:
            primary=nil;text="—";secondary="—"
        }
        return PopupDetailRow(id:process.id,name:process.name,process:process,primary:primary,primaryText:text,secondaryText:secondary)
    }
    private mutating func configureChart(frames:[Frame],gaps:[RecordingGap],family:PopupDetailDestination,mode:String,selected:PopupDetailRow?,physicalMemory:UInt64) {
        let selectedName=selected?.name
        switch family {
        case .cpu:series=[selectedName ?? "Machine CPU"];chartTitle=selectedName.map {$0+" · 100% = one logical CPU"} ?? "Machine capacity";chartUnit="%";chartCeiling=selected == nil ? 100 : nil
        case .memory:
            series=mode == "Compression / swap" ? ["Compressed","Swap"] : [selectedName ?? "Used memory"]
            chartTitle=selectedName.map {$0+" · physical footprint"} ?? (mode == "Compression / swap" ? "Compression and swap" : "Used RAM · cache excluded")
            chartUnit="bytes";chartCeiling=selected == nil && mode != "Compression / swap" ? Double(physicalMemory) : nil
        case .network:series=["Download","Upload"];chartTitle=selectedName.map {$0+" · process TCP/UDP traffic"} ?? "Physical-interface traffic";chartUnit="bytes/s"
        case .disk:series=["Read","Write"];chartTitle=selectedName.map {$0+" · observed process I/O"} ?? "Observed process I/O";chartUnit="bytes/s"
        case .energy:
            series=[mode == "Energy Impact" ? "Energy Impact" : "CPU power"]
            chartTitle=mode == "Energy Impact" ? (selectedName ?? "Leading process")+" · unitless process score" : (selectedName ?? "Observed process subtotal")+" · CPU power estimate"
            chartUnit=mode == "Energy Impact" ? "impact" : "W"
        case .battery:series=["Battery flow"];chartTitle="Battery flow · positive charging / negative discharging";chartUnit="W";signedChart=true
        }
        let leadingImpactID=selected?.process?.id ?? (family == .energy && mode == "Energy Impact" ? frames.last.map {Self.rows(frame:$0,family:.energy,mode:mode,scope:"Processes").first?.id} ?? nil : nil)
        var run=0
        var previous:Frame?
        var seenNetworkCaptures=Set<String>()
        for frame in frames {
            let networkInterval=family == .network && selected != nil ? Self.networkSample(frame) : nil
            let intervalEnd=networkInterval?.endedAt ?? frame.time
            let intervalStart=networkInterval?.startedAt ?? frame.time.addingTimeInterval(-(frame.elapsed ?? 0))
            let gap=gaps.contains {$0.contains(intervalEnd) || $0.start<intervalEnd && ($0.end ?? .distantFuture)>intervalStart}
            if gap {run+=1;previous=frame;continue}
            if let previous,previous.segment != frame.segment || frame.time.timeIntervalSince(previous.time)>max(15,(frame.cadence ?? frame.elapsed ?? 5)*2.5) {run+=1}
            let matching:[ProcessRow]
            if let selected,family != .network {
                if selected.process != nil {matching=frame.processes.filter {$0.id==selected.id}}
                else {matching=AppPowerGrouping.snapshot(frame).first {$0.id==selected.id}?.processes ?? []}
            } else {matching=frame.processes}
            var values:[Double?]
            var pointTime=frame.time
            switch family {
            case .cpu:values=[selected == nil ? frame.cpu : Self.sum(matching.compactMap(\.cpu))]
            case .memory:
                values=mode == "Compression / swap" ? [Double(frame.compressed),Double(frame.swap)] : [selected == nil ? Double(frame.memory) : Self.sum(matching.compactMap {$0.memory.map(Double.init)})]
            case .network:
                if let selected {
                    guard let sample=Self.networkSample(frame),seenNetworkCaptures.insert(sample.id).inserted else {continue}
                    pointTime=sample.endedAt
                    let row=Self.networkRows(frame:frame,mode:mode,scope:selected.process == nil ? "Applications" : "Processes").first {$0.id==selected.id}
                    let ids=Set(row?.process.map {[$0.id]} ?? row?.children.map(\.id) ?? [])
                    values=[Self.sum(sample.tasks.filter {ids.contains($0.id)}.compactMap {$0.downloadRate(elapsed:sample.elapsed)}),Self.sum(sample.tasks.filter {ids.contains($0.id)}.compactMap {$0.uploadRate(elapsed:sample.elapsed)})]
                } else {values=[frame.download,frame.upload]}
            case .disk:values=[Self.sum(matching.compactMap {Self.processRate($0.read,elapsed:frame.elapsed)}),Self.sum(matching.compactMap {Self.processRate($0.written,elapsed:frame.elapsed)})]
            case .energy:
                if mode == "Energy Impact" {
                    values=[leadingImpactID.flatMap {id in frame.processes.first {$0.id==id}}.flatMap {Self.impact(process:$0,frame:frame)}]
                } else {values=[Self.sum(matching.compactMap {$0.cpuPowerWatts(elapsed:frame.elapsed)})]}
            case .battery:values=[frame.power.flatMap {$0.hasUsableCurrent ? $0.watts : nil}]
            }
            for (index,value) in values.enumerated() {
                guard let value,value.isFinite else {run+=1;continue}
                let phase=family == .battery ? (frame.power?.externalPower == true ? ":external" : ":battery") : ""
                points.append(.init(time:pointTime,value:value,series:series[index],segment:"\(series[index]):\(frame.segment ?? "legacy"):\(run)\(phase)"))
            }
            previous=frame
        }
    }
    private static func selection(row:PopupDetailRow,frame:Frame,frames:[Frame],range:DateInterval,gaps:[RecordingGap])->PopupDetailSelection {
        let ids=Set(row.process.map {[$0.id]} ?? row.children.map(\.id))
        let scoped=frames.map {frame -> Frame in
            var copy=frame
            copy.processes=row.process == nil ? AppPowerGrouping.snapshot(frame).first {$0.id==row.id}?.processes ?? [] : frame.processes.filter {ids.contains($0.id)}
            return copy
        }
        let summaries=HistoryAnalysis.summarize(scoped,range:range,gaps:gaps)
        let process=row.process
        var facts:[PopupDetailFact]=[]
        var partial=row.partial
        if let process {
            facts.append(.init(title:"PID / owner",value:"\(process.pid) / \(process.userID.map {String($0)} ?? "unknown")"))
            facts.append(.init(title:"Source",value:process.metricSource ?? "Recorded sample"))
        } else {facts.append(.init(title:"Observed helpers",value:"\(row.children.count)"))}
        if frame.processNetwork != nil {
            let totals:ProcessNetworkTotals
            if let process {
                totals=summaries.first {$0.id==process.id}?.network ?? .init()
            } else {
                let group=HistoryAnalysis.networkGroups(frames,range:range,gaps:gaps).first {$0.id==row.id}
                totals=group?.totals ?? .init()
                partial = partial || group?.isPartial == true || group?.hasUnattributedProcesses == true
            }
            facts.append(.init(title:"Received in range",value:totals.receivedBytes.map(bytes) ?? "—"))
            facts.append(.init(title:"Sent in range",value:totals.sentBytes.map(bytes) ?? "—"))
            facts.append(.init(title:"Average receive / send",value:(totals.averageDownloadRate.map(fullRate) ?? "—")+" / "+(totals.averageUploadRate.map(fullRate) ?? "—")))
            facts.append(.init(title:"Peak receive / send",value:(totals.peakDownloadRate.map(fullRate) ?? "—")+" / "+(totals.peakUploadRate.map(fullRate) ?? "—")))
        }
        facts.append(.init(title:"CPU",value:process?.cpu.map {decimal($0,places:1)+"% · one-core scale"} ?? "—"))
        facts.append(.init(title:"Footprint",value:process?.memory.map(bytes) ?? "—"))
        facts.append(.init(title:"Read / write",value:(process.flatMap {processRate($0.read,elapsed:frame.elapsed)}.map(fullRate) ?? "—")+" / "+(process.flatMap {processRate($0.written,elapsed:frame.elapsed)}.map(fullRate) ?? "—")))
        let energySummaries=summaries.filter {$0.energyCoveredSeconds>0}
        let energy=energySummaries.reduce(0) {$0+$1.energyJoules}
        facts.append(.init(title:"CPU energy in range",value:energySummaries.isEmpty ? "—" : decimal(energy,places:2)+" J"))
        if let process=row.process,let summary=summaries.first(where:{$0.id==process.id}) {
            facts.append(.init(title:"Average / peak CPU power",value:(summary.averagePower.map {decimal($0,places:2)+" W"} ?? "—")+" / "+(summary.peakPower.map {decimal($0,places:2)+" W"} ?? "—")))
            facts.append(.init(title:"Peak footprint in range",value:summary.peakMemory.map(bytes) ?? "—"))
        } else if let summary=AppPowerGrouping.summarize(scoped,range:range,gaps:gaps).first(where:{$0.id==row.id}) {
            facts.append(.init(title:"Average / peak CPU power",value:(summary.averagePower.map {decimal($0,places:2)+" W"} ?? "—")+" / "+(summary.peakPower.map {decimal($0,places:2)+" W"} ?? "—")))
        }
        let read=summaries.filter {$0.ioSamples>0}
        facts.append(.init(title:"Observed bytes in range",value:read.isEmpty ? "—" : bytes(read.reduce(0) {$0+$1.readBytes})+" read / "+bytes(read.reduce(0) {$0+$1.writtenBytes})+" written"))
        if let idle=process?.idleWakeups,let elapsed=frame.elapsed,elapsed>0 {facts.append(.init(title:"Idle wakeups",value:decimal(Double(idle)/elapsed,places:1)+"/s"))}
        return .init(row:row,facts:facts,coverage:partial ? "Partial measurement coverage; unavailable helpers are not zero." : "Observed intervals only; gaps and missing counters are excluded.")
    }
    static func processRate(_ value:UInt64?,elapsed:Double?)->Double? {
        guard let value,let elapsed,elapsed.isFinite,elapsed>0 else {return nil}
        return Double(value)/elapsed
    }
    static func rateComponents(_ value:Double)->(String,String) {
        let formatted=popupRateValue(value)
        return (formatted.value,formatted.unit)
    }
    static func fullRate(_ value:Double)->String {let parts=rateComponents(value);return parts.0+(parts.1.isEmpty ? "" : " "+parts.1)}
    private static func decimal(_ value:Double,places:Int)->String {String(format:"%.*f",places,value)}
    private static func signedBytes(_ value:Int64)->String {value<0 ? "−"+bytes(value == Int64.min ? UInt64(Int64.max)+1 : UInt64(-value)) : "+"+bytes(UInt64(value))}
    private static func sum(_ values:[Double])->Double? {values.isEmpty ? nil : values.reduce(0,+)}
    private static func accessCoverage(_ frame:Frame)->String {frame.denied<0 ? "access coverage unavailable" : frame.denied>0 ? "\(frame.denied) process queries restricted" : "observed process readings"}
    private static func networkSample(_ frame:Frame)->ProcessNetworkSample? {
        guard let sample=frame.processNetwork,sample.isFresh(at:frame.time) else {return nil}
        return sample
    }
    private static func impact(process:ProcessRow,frame:Frame)->Double? {
        guard process.start>0,let value=frame.energyImpact?.task(forPID:process.pid,processStart:Date(timeIntervalSince1970:Double(process.start)/1e6),at:frame.time,maximumAge:15)?.energyImpactPerSecond,value.isFinite,value>=0 else {return nil}
        return value
    }
}
