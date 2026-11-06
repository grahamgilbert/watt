import SwiftUI
import Charts

final class ProcessExplorerControls:ObservableObject {
    @Published var center=Date()
    @Published var duration=900.0
    @Published var selection:String?
    @Published var sort="CPU"
    @Published var search=""
    @Published var mode="At cursor"
    @Published var tree=false
    @Published var scope="Processes"
    @Published var applicationSelection:String?
    @Published var applicationSummaries:[AppEnergySummary]=[]
}

struct ProcessExplorerView:View {
    @ObservedObject var monitor:Monitor
    @ObservedObject private var controls:ProcessExplorerControls
    private let initializeControls:Bool
    init(monitor:Monitor,controls:ProcessExplorerControls?=nil) {
        self.monitor=monitor
        self.controls=controls ?? ProcessExplorerControls()
        initializeControls=controls == nil
    }
    private var range:DateInterval {
        monitor.historyRange ?? DateInterval(start:(monitor.liveFrame?.time ?? monitor.frames.last?.time ?? Date()).addingTimeInterval(-controls.duration),duration:controls.duration)
    }
    private var cursor:Date? {monitor.selected ?? monitor.liveFrame?.time}
    private var displayFrames:[Frame] {monitor.visibleFrames.filter {$0.time>=range.start && $0.time<=range.end}}
    private var summaryMode:Bool {controls.mode=="Interval summary" && monitor.historyRange != nil}
    private var isLive:Bool {monitor.historyRange==nil && monitor.selected==nil}
    private var applicationsMode:Bool {controls.scope=="Applications"}
    private var hasLegacyCPU:Bool {displayFrames.contains {$0.processCPUAccounting == nil}}
    private var hasCorrectedCPU:Bool {displayFrames.contains {$0.processCPUAccounting != nil}}
    private var mixedCPUAccounting:Bool {hasLegacyCPU && hasCorrectedCPU}
    private var accountedSummaries:[ProcessSummary] {
        guard mixedCPUAccounting else {return monitor.historySummaries}
        let corrected=HistoryAnalysis.summarize(displayFrames.filter {$0.processCPUAccounting != nil},range:range,gaps:monitor.visibleGaps)
        let lookup=Dictionary(corrected.map {($0.id,$0)},uniquingKeysWith:{$1})
        return monitor.historySummaries.map {original in
            var result=original
            result.peakCPU=lookup[original.id]?.peakCPU
            result.cpuSeconds=lookup[original.id]?.cpuSeconds ?? 0
            result.cpuCoveredSeconds=lookup[original.id]?.cpuCoveredSeconds ?? 0
            return result
        }
    }
    private var applicationGroups:[AppPowerGroup] {
        guard let frame=monitor.current else {return []}
        return AppPowerGrouping.snapshot(frame).filter {group in
            controls.search.isEmpty || group.name.localizedCaseInsensitiveContains(controls.search) || group.processes.contains {String($0.pid).contains(controls.search)}
        }.sorted {controls.sort=="CPU" ? ($0.cpu ?? -1)>($1.cpu ?? -1) : ($0.cpuPowerWatts ?? -1)>($1.cpuPowerWatts ?? -1)}
    }
    private var applicationSummaries:[AppEnergySummary] {
        guard !monitor.historyLoading else {return []}
        return controls.applicationSummaries.filter {controls.search.isEmpty || $0.name.localizedCaseInsensitiveContains(controls.search)}.sorted {($0.energyCoveredSeconds>0 ? $0.energyJoules : -1)>($1.energyCoveredSeconds>0 ? $1.energyJoules : -1)}
    }
    private func refreshApplicationSummaries() {
        guard applicationsMode,summaryMode else {return}
        controls.applicationSummaries=AppPowerGrouping.summarize(displayFrames,range:range,gaps:monitor.visibleGaps)
    }
    private var processes:[ProcessRow] {
        let all=(monitor.current?.processes ?? []).filter {matches($0)}
        let sorted=all.sorted {
            switch controls.sort {
            case "CPU energy":return ($0.cpuPowerWatts(elapsed:monitor.current?.elapsed) ?? -1)>($1.cpuPowerWatts(elapsed:monitor.current?.elapsed) ?? -1)
            case "Memory":return $0.memory>$1.memory
            case "Disk read":return ($0.read ?? 0)>($1.read ?? 0)
            case "Disk write":return ($0.written ?? 0)>($1.written ?? 0)
            default:return ($0.cpu ?? -1)>($1.cpu ?? -1)
            }
        }
        guard controls.tree else {return sorted}
        let pids=Set(all.map(\.pid));var result:[ProcessRow]=[];var seen=Set<String>()
        func append(_ row:ProcessRow) {guard seen.insert(row.id).inserted else {return};result.append(row);for child in sorted where child.parent==row.pid {append(child)}}
        for row in sorted where !pids.contains(row.parent) {append(row)}
        for row in sorted {append(row)}
        return result
    }
    private var summaries:[ProcessSummary] {
        accountedSummaries.filter {matches($0.process)}.sorted {
            switch controls.sort {
            case "CPU energy":return ($0.energyCoveredSeconds>0 ? $0.energyJoules : -1)>($1.energyCoveredSeconds>0 ? $1.energyJoules : -1)
            case "Memory":return $0.peakMemory>$1.peakMemory
            case "Disk read":return $0.readBytes>$1.readBytes
            case "Disk write":return $0.writtenBytes>$1.writtenBytes
            default:return $0.cpuSeconds>$1.cpuSeconds
            }
        }
    }
    private func matches(_ process:ProcessRow)->Bool {controls.search.isEmpty || process.name.localizedCaseInsensitiveContains(controls.search) || String(process.pid).contains(controls.search)}
    private func depth(_ row:ProcessRow)->Int {
        guard controls.tree else {return 0}
        let map=Dictionary((monitor.current?.processes ?? []).map {($0.pid,$0)},uniquingKeysWith:{$1})
        var pid=row.parent,seen=Set<Int32>(),count=0
        while let parent=map[pid],seen.insert(pid).inserted,count<8 {count+=1;pid=parent.parent}
        return count
    }
    private func load() {monitor.loadHistory(center:controls.center,duration:controls.duration);controls.mode="Interval summary"}
    private func moveWindow(_ direction:Double) {controls.center=controls.center.addingTimeInterval(controls.duration*direction);load()}
    private func selectTime(_ date:Date) {monitor.selected=date;controls.mode="At cursor"}
    private var selectedIdentity:ProcessRow? {
        guard let id=controls.selection else {return nil}
        return monitor.current?.processes.first(where:{$0.id==id}) ?? monitor.historySummaries.first(where:{$0.id==id})?.process ?? displayFrames.reversed().lazy.compactMap {$0.processes.first(where:{$0.id==id})}.first
    }
    var body:some View {
        VStack(spacing:0) {
            header
            Divider()
            timeToolbar
            systemTracks
            Divider()
            HStack(alignment:.top,spacing:0) {
                VStack(spacing:0) {
                    processToolbar
                    Divider()
                    if applicationsMode {
                        if summaryMode {applicationSummaryTable} else {applicationSnapshotTable}
                    } else {
                        if summaryMode {summaryTable} else {snapshotTable}
                        if let identity=selectedIdentity {Divider();selectedProcessTracks(identity)}
                    }
                    tableFooter
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                if applicationsMode {
                    ExplorerApplicationInspector(group:applicationGroups.first {$0.id==controls.applicationSelection},summary:summaryMode ? applicationSummaries.first {$0.id==controls.applicationSelection} : nil,summaryMode:summaryMode,range:range,elapsed:monitor.current?.elapsed)
                        .frame(width:290)
                } else {
                    ProcessInspector(identity:selectedIdentity,current:monitor.current,summary:summaryMode ? accountedSummaries.first(where:{$0.id==controls.selection}) : nil,frames:displayFrames,range:range,cursor:cursor,gaps:monitor.visibleGaps)
                        .frame(width:290)
                }
            }.frame(maxHeight:.infinity)
            Divider()
            statusFooter
        }.background(ExplorerPalette.background)
            .frame(minWidth:1280,minHeight:780)
            .onChange(of:controls.scope) {_,_ in
                if applicationsMode {controls.sort="CPU energy"}
                refreshApplicationSummaries()
            }
            .onChange(of:controls.mode) {_,_ in
                if applicationsMode && summaryMode {controls.sort="CPU energy"}
                refreshApplicationSummaries()
            }
            .onChange(of:monitor.historyLoading) {_,loading in if loading {controls.applicationSummaries=[]} else {refreshApplicationSummaries()}}
            .onAppear {
                refreshApplicationSummaries()
                guard initializeControls else {return}
                if let range=monitor.historyRange {controls.center=range.start.addingTimeInterval(range.duration/2);controls.duration=range.duration;controls.mode="Interval summary"}
                else {controls.center=(monitor.liveFrame?.time ?? monitor.historyBounds?.end ?? Date()).addingTimeInterval(-controls.duration/2)}
            }
    }
    private var header:some View {
        HStack(spacing:10) {
            Image(systemName:"waveform.path").font(.system(size:17,weight:.medium)).foregroundStyle(ExplorerPalette.cpu)
            Text("Process Explorer").font(.system(size:18,weight:.semibold))
            Text("This Mac").font(.system(size:11)).foregroundStyle(.secondary)
            Spacer()
            if monitor.historyLoading {ProgressView().controlSize(.small)}
            Button("Return to live") {monitor.returnToLive();controls.mode="At cursor"}.controlSize(.small).disabled(isLive)
        }.padding(.horizontal,20).padding(.vertical,13)
    }
    private var timeToolbar:some View {
        HStack(spacing:10) {
            Text(isLive ? "Live" : range.start.formatted(date:.abbreviated,time:.omitted)).font(.system(size:14,weight:.semibold)).frame(minWidth:54,alignment:.leading)
            DatePicker("Go to",selection:$controls.center,displayedComponents:[.date,.hourAndMinute]).labelsHidden().accessibilityLabel("History date and time").frame(width:185)
            Picker("Window",selection:$controls.duration) {Text("2 minutes").tag(120.0);Text("5 minutes").tag(300.0);Text("15 minutes").tag(900.0);Text("1 hour").tag(3600.0);Text("2 hours").tag(7200.0)}.labelsHidden().frame(width:110)
            HStack(spacing:2) {
                Button {moveWindow(-1)} label:{Image(systemName:"chevron.left").frame(width:20,height:20)}.help("Earlier window")
                Button {moveWindow(1)} label:{Image(systemName:"chevron.right").frame(width:20,height:20)}.help("Later window")
            }.buttonStyle(.borderless).disabled(monitor.historyLoading)
            Button("Inspect",action:load).controlSize(.small).disabled(monitor.historyLoading)
            Spacer(minLength:12)
            HStack(spacing:6) {Text("Cursor").foregroundStyle(.secondary);Text(cursor?.formatted(date:.omitted,time:.standard) ?? "—").monospacedDigit()}
                .font(.system(size:11)).padding(.horizontal,10).padding(.vertical,5).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:5))
            Text("Local · \(TimeZone.current.abbreviation() ?? "")").font(.system(size:10)).foregroundStyle(.secondary)
        }.controlSize(.small).padding(.horizontal,20).padding(.vertical,10)
    }
    private var systemTracks:some View {
        VStack(spacing:0) {
            ExplorerSystemTrack(title:"CPU",value:monitor.current.map {String(format:"%.0f%%",$0.cpu)} ?? "—",subtitle:"Machine capacity · 0–100%",metric:"CPU",color:ExplorerPalette.cpu,frames:displayFrames,range:range,cursor:cursor,gaps:monitor.visibleGaps,onSelect:selectTime)
            ExplorerSystemTrack(title:"Memory",value:monitor.current.map {"\(bytes($0.memory)) / \(bytes(ProcessInfo.processInfo.physicalMemory))"} ?? "—",subtitle:monitor.current.map {$0.memoryAccounting == nil ? "Legacy VM estimate" : "Used RAM · reclaimable cache excluded"} ?? "No sample at cursor",metric:"Memory",color:ExplorerPalette.memory,frames:displayFrames,range:range,cursor:cursor,gaps:monitor.visibleGaps,onSelect:selectTime)
            ExplorerSystemTrack(title:"Disk I/O",value:systemDiskText,subtitle:"Observed processes · read / write",metric:"Disk",color:ExplorerPalette.disk,frames:displayFrames,range:range,cursor:cursor,gaps:monitor.visibleGaps,onSelect:selectTime)
        }.padding(.horizontal,20).padding(.bottom,10)
    }
    private var systemDiskText:String {
        guard let frame=monitor.current,let elapsed=frame.elapsed,elapsed>0 else {return "—"}
        let reads=frame.processes.compactMap(\.read),writes=frame.processes.compactMap(\.written)
        guard !reads.isEmpty || !writes.isEmpty else {return "—"}
        let read=reads.reduce(0.0) {$0+Double($1)}/elapsed
        let write=writes.reduce(0.0) {$0+Double($1)}/elapsed
        return "\(reads.isEmpty ? "—" : String(format:"%.1f",read/1048576)) / \(writes.isEmpty ? "—" : String(format:"%.1f",write/1048576)) MiB/s"
    }
    private var processToolbar:some View {
        HStack(spacing:10) {
            HStack(spacing:6) {Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField(applicationsMode ? "Application or PID" : "Process or PID",text:$controls.search).textFieldStyle(.plain)}
                .font(.system(size:11)).padding(.horizontal,8).frame(width:160,height:26).background(.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:5))
            Picker("Scope",selection:$controls.scope) {Text("Processes").tag("Processes");Text("Applications").tag("Applications")}.pickerStyle(.segmented).labelsHidden().frame(width:180)
            Picker("View",selection:$controls.mode) {Text("At cursor").tag("At cursor");Text("Interval summary").tag("Interval summary")}.pickerStyle(.segmented).labelsHidden().frame(width:175).disabled(monitor.historyRange==nil)
            Picker("Rank",selection:$controls.sort) {
                ForEach(applicationsMode ? ["CPU","CPU energy"] : ["CPU","CPU energy","Memory","Disk read","Disk write"],id:\.self){Text($0).tag($0).disabled(applicationsMode && summaryMode && $0=="CPU")}
            }.frame(width:135)
            if !applicationsMode {Toggle("Parent tree",isOn:$controls.tree).toggleStyle(.checkbox).disabled(summaryMode)}
            Spacer(minLength:0)
        }.font(.system(size:11)).controlSize(.small).padding(.horizontal,16).padding(.vertical,10)
    }
    private var tableFooter:some View {
        HStack {
            Text(applicationsMode ? "\(summaryMode ? applicationSummaries.count : applicationGroups.count) observed application / unassigned groups" : summaryMode ? "\(summaries.count) process instances · \(monitor.historyFrames.count) samples" : "\(processes.count) observed processes").foregroundStyle(.secondary)
            Spacer()
            Text(applicationsMode ? "Observed members only · application bundles, not macOS coalitions" : summaryMode && mixedCPUAccounting ? "CPU coverage uses corrected records only" : summaryMode ? "Complete covered intervals only" : "CPU 100% = one core · footprints are not additive").foregroundStyle(.tertiary)
        }.font(.system(size:10)).padding(.horizontal,16).padding(.vertical,8)
    }
    private var statusFooter:some View {
        HStack(spacing:6) {
            Circle().fill(Color.orange.opacity(0.8)).frame(width:4,height:4)
            if let error=monitor.historyError ?? monitor.error {Text(error).foregroundStyle(.orange)}
            else {Text("Sampled history · short-lived processes can be missed · — means unavailable").foregroundStyle(.secondary)}
            if (summaryMode && hasLegacyCPU) || (monitor.current.map {$0.processCPUAccounting == nil} ?? false) {
                Text(mixedCPUAccounting && summaryMode ? "· mixed CPU accounting: corrected records only" : "· legacy process CPU scaling").foregroundStyle(.orange)
            }
            Spacer()
            if let frame=monitor.current {Text("\(frame.processes.count) observed · \(max(0,frame.denied)) queries unavailable").foregroundStyle(.secondary)}
            else if let reason=monitor.selectionGap()?.reason {Text(reason).foregroundStyle(.orange)}
            else {Text("No nearby recorded sample at cursor").foregroundStyle(.orange)}
            if let bounds=monitor.historyBounds {Text("Retained \(bounds.start.formatted(date:.abbreviated,time:.shortened))").foregroundStyle(.tertiary)}
        }.font(.system(size:10)).lineLimit(1).padding(.horizontal,20).padding(.vertical,9)
    }
    private func selectedProcessTracks(_ identity:ProcessRow)->some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {Text("\(identity.name) · PID \(identity.pid)").fontWeight(.semibold);Spacer();Text("Selected process · shared timeline").foregroundStyle(.secondary)}.font(.system(size:10))
            ForEach(["CPU","Memory","Energy","Disk"],id:\.self) {metric in
                HStack(spacing:12) {
                    Text(metric=="Memory" ? "Physical footprint · MiB" : metric=="Energy" ? "CPU power · W est." : metric=="Disk" ? "Disk read / write · MiB/s" : "CPU · one-core %")
                        .font(.system(size:9)).foregroundStyle(metric=="Memory" ? ExplorerPalette.memory : metric=="Energy" ? ExplorerPalette.energy : metric=="Disk" ? ExplorerPalette.disk : ExplorerPalette.cpu).frame(width:155,alignment:.leading)
                    ExplorerTrace(frames:displayFrames,range:range,cursor:cursor,processID:identity.id,metric:metric,gaps:monitor.visibleGaps,showXAxis:false).frame(height:25)
                }
            }
        }.padding(.horizontal,16).padding(.top,10).padding(.bottom,8).background(.primary.opacity(0.018))
    }
    private var applicationSnapshotTable:some View {
        Table(applicationGroups,selection:$controls.applicationSelection) {
            TableColumn("Application / unassigned process") {Text($0.name)}.width(min:200,ideal:260)
            TableColumn("CPU % · observed") {Text(explorerPercent($0.cpu)).foregroundStyle(ExplorerPalette.cpu)}.width(115)
            TableColumn("CPU W est. · observed") {Text(explorerPower($0.cpuPowerWatts)).foregroundStyle(ExplorerPalette.energy)}.width(140)
            TableColumn("Processes") {Text(String($0.observedProcesses))}.width(85)
            TableColumn("Energy coverage") {Text("\($0.measuredEnergyProcesses) / \($0.observedProcesses) measured")}.width(135)
            TableColumn("Grouping") {Text($0.id.hasPrefix("app:") ? "Application bundle" : "Unassigned process").foregroundStyle(.secondary)}.width(145)
        }.tableStyle(.inset(alternatesRowBackgrounds:false)).font(.system(size:11)).monospacedDigit().controlSize(.small).frame(maxHeight:.infinity)
    }
    private var applicationSummaryTable:some View {
        Table(applicationSummaries,selection:$controls.applicationSelection) {
            TableColumn("Application / unassigned process") {Text($0.name)}.width(min:200,ideal:260)
            TableColumn("CPU W avg / peak") {Text("\(explorerPower($0.averagePower)) / \(explorerPower($0.peakPower))").foregroundStyle(ExplorerPalette.energy)}.width(145)
            TableColumn("CPU energy · J") {Text($0.energyCoveredSeconds>0 ? String(format:"%.3f",$0.energyJoules) : "—")}.width(115)
            TableColumn("Processes observed") {Text(String($0.observedProcesses))}.width(125)
            TableColumn("Covered seconds") {Text(String(format:"%.1f",$0.energyCoveredSeconds))}.width(120)
            TableColumn("Coverage") {Text($0.isPartial ? "Partial members" : "Observed members").foregroundStyle(.secondary)}.width(140)
        }.tableStyle(.inset(alternatesRowBackgrounds:false)).font(.system(size:11)).monospacedDigit().controlSize(.small).frame(maxHeight:.infinity)
    }
    private var snapshotTable:some View {
        Table(processes,selection:$controls.selection) {
            TableColumn("Process / observed parent") {p in Text(p.name).padding(.leading,CGFloat(depth(p))*12)}.width(min:150,ideal:205)
            TableColumn("PID") {Text(String($0.pid))}.width(52)
            TableColumn("Parent") {Text(String($0.parent))}.width(52)
            TableColumn("CPU %") {Text($0.cpu.map {String(format:"%.1f",$0)} ?? "—").foregroundStyle(ExplorerPalette.cpu).help(monitor.current?.processCPUAccounting == nil ? "Legacy recorded CPU values use the prototype scaling and can be underreported." : "CPU 100% equals one core. Native Mach CPU time has been converted to nanoseconds.")}.width(70)
            TableColumn("CPU W est.") {Text(explorerPower($0.cpuPowerWatts(elapsed:monitor.current?.elapsed)))}.width(85)
            TableColumn("Footprint") {Text(bytes($0.memory))}.width(100)
            TableColumn("Δ memory") {p in Text(explorerDelta(p.growth))}.width(95)
            TableColumn("Read/s") {Text(diskRate($0.read,elapsed:monitor.current?.elapsed))}.width(100)
            TableColumn("Write/s") {Text(diskRate($0.written,elapsed:monitor.current?.elapsed))}.width(100)
        }.tableStyle(.inset(alternatesRowBackgrounds:false)).font(.system(size:11)).monospacedDigit().controlSize(.small).frame(maxHeight:.infinity)
    }
    private var summaryTable:some View {
        Table(summaries,selection:$controls.selection) {
            TableColumn("Process") {Text($0.process.name)}.width(min:150,ideal:205)
            TableColumn("PID") {Text(String($0.process.pid))}.width(52)
            TableColumn("CPU avg / peak") {p in Text("\(explorerPercent(p.averageCPU)) / \(explorerPercent(p.peakCPU))").foregroundStyle(ExplorerPalette.cpu)}.width(125)
            TableColumn("CPU W avg / peak") {p in Text("\(explorerPower(p.averagePower)) / \(explorerPower(p.peakPower))")}.width(125)
            TableColumn("CPU energy · J") {p in Text(p.energyCoveredSeconds>0 ? String(format:"%.3f",p.energyJoules) : "—")}.width(95)
            TableColumn("CPU time") {Text($0.cpuCoveredSeconds>0 ? String(format:"%.2f s",$0.cpuSeconds) : "—")}.width(80)
            TableColumn("Footprint last / peak") {p in Text("\(bytes(p.lastMemory)) / \(bytes(p.peakMemory))")}.width(165)
            TableColumn("Δ memory") {p in Text(explorerDelta(p.memoryChange))}.width(95)
            TableColumn("Read total") {Text($0.ioSamples>0 ? bytes($0.readBytes) : "—")}.width(95)
            TableColumn("Write total") {Text($0.ioSamples>0 ? bytes($0.writtenBytes) : "—")}.width(95)
        }.tableStyle(.inset(alternatesRowBackgrounds:false)).font(.system(size:11)).monospacedDigit().controlSize(.small).frame(maxHeight:.infinity)
    }
}

private func explorerPower(_ value:Double?)->String {value.map {String(format:$0<0.01 ? "%.3f" : "%.2f",$0)} ?? "—"}
private func explorerPercent(_ value:Double?)->String {value.map {String(format:"%.1f%%",$0)} ?? "—"}
private func explorerDelta(_ value:Int64?)->String {value.map {$0 == 0 ? "0 B" : ($0<0 ? "−" : "+")+bytes(UInt64(abs($0)))} ?? "—"}

private struct ExplorerSystemTrack:View {
    let title:String
    let value:String
    let subtitle:String
    let metric:String
    let color:Color
    let frames:[Frame]
    let range:DateInterval
    let cursor:Date?
    let gaps:[RecordingGap]
    let onSelect:(Date)->Void
    var body:some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:3) {
                HStack(spacing:10) {Text(title).fontWeight(.semibold).foregroundStyle(color);Text(value).monospacedDigit()}.font(.system(size:11))
                Text(subtitle).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width:255,alignment:.leading)
            ExplorerTrace(frames:frames,range:range,cursor:cursor,processID:nil,metric:metric,gaps:gaps,showXAxis:metric=="Disk")
                .frame(height:metric=="Disk" ? 61 : 42)
                .chartOverlay {proxy in
                    GeometryReader {geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged {event in
                            guard let plot=proxy.plotFrame else {return}
                            let x=min(max(0,event.location.x-geometry[plot].origin.x),geometry[plot].width)
                            if let date:Date=proxy.value(atX:x),range.contains(date) {onSelect(date)}
                        })
                    }
                }.accessibilityLabel("\(title) timeline")
        }.padding(.vertical,6).overlay(alignment:.bottom) {if metric != "Disk" {Divider().opacity(0.5)}}
    }
}

private struct ProcessInspector:View {
    let identity:ProcessRow?
    let current:Frame?
    let summary:ProcessSummary?
    let frames:[Frame]
    let range:DateInterval
    let cursor:Date?
    let gaps:[RecordingGap]
    private var process:ProcessRow? {guard let identity else{return nil};return current?.processes.first {$0.id==identity.id}}
    private var displayedCPU:Double? {if let summary {return summary.averageCPU};return process?.cpu}
    private var hasLegacyCPU:Bool {frames.contains {$0.processCPUAccounting == nil && $0.processes.contains {$0.id==identity?.id}}}
    private var hasCorrectedCPU:Bool {frames.contains {$0.processCPUAccounting != nil && $0.processes.contains {$0.id==identity?.id}}}
    private var displayedPower:Double? {if let summary {return summary.averagePower};return process?.cpuPowerWatts(elapsed:current?.elapsed)}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:17) {
                Text("PROCESS INSPECTOR").font(.system(size:9,weight:.semibold)).tracking(1.4).foregroundStyle(.secondary)
                if let identity {
                    VStack(alignment:.leading,spacing:5) {
                        Text(identity.name).font(.system(size:20,weight:.semibold)).lineLimit(2)
                        Text("PID \(identity.pid) · parent \(identity.parent)").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                        Text(summary != nil ? "Selected interval" : process == nil ? "Not observed at cursor" : "Observed at cursor").font(.system(size:10)).foregroundStyle(.secondary)
                    }
                    Divider()
                    inspectorSection("CPU") {
                        if (summary != nil && hasLegacyCPU) || (summary == nil && current?.processCPUAccounting == nil) {
                            Text(hasCorrectedCPU && summary != nil ? "Corrected records only; legacy CPU samples excluded." : "Legacy recorded CPU scaling · may be underreported.").font(.system(size:9)).foregroundStyle(.orange)
                        }
                        inspectorRow("\(summary == nil ? "At cursor" : "Average") · one-core %",explorerPercent(displayedCPU),color:ExplorerPalette.cpu)
                        if let summary {inspectorRow("Sampled peak",explorerPercent(summary.peakCPU));inspectorRow("Covered CPU time",summary.cpuCoveredSeconds>0 ? String(format:"%.2f s",summary.cpuSeconds) : "—")}
                    }
                    inspectorSection("MEMORY BEHAVIOR") {
                        inspectorRow("Physical footprint",(summary?.lastMemory ?? process?.memory).map(bytes) ?? "—",color:ExplorerPalette.memory)
                        if let summary {inspectorRow("Peak in interval",bytes(summary.peakMemory));inspectorRow("End − start",explorerDelta(summary.memoryChange))}
                        else {inspectorRow("Change in sample",explorerDelta(process?.growth))}
                    }
                    inspectorSection("CPU ENERGY · ESTIMATE") {
                        inspectorRow(summary == nil ? "Power at cursor" : "Average power",displayedPower.map {explorerPower($0)+" W"} ?? "Unavailable",color:ExplorerPalette.energy)
                        if let summary {
                            inspectorRow("Sampled peak",explorerPower(summary.peakPower)+" W")
                            inspectorRow("Energy in interval",summary.energyCoveredSeconds>0 ? String(format:"%.3f J",summary.energyJoules) : "—")
                            Text(String(format:"Energy coverage %.1f / %.1f seconds",summary.energyCoveredSeconds,range.duration)).font(.system(size:9)).foregroundStyle(.secondary)
                        }
                        Text("Kernel-attributed CPU energy. GPU and other device energy are not included.").font(.system(size:9)).foregroundStyle(.secondary)
                    }
                    inspectorSection("DISK ACTIVITY") {
                        inspectorRow(summary == nil ? "Read rate" : "Read total",summary.map {$0.ioSamples>0 ? bytes($0.readBytes) : "—"} ?? diskRate(process?.read,elapsed:current?.elapsed),color:ExplorerPalette.disk)
                        inspectorRow(summary == nil ? "Write rate" : "Write total",summary.map {$0.ioSamples>0 ? bytes($0.writtenBytes) : "—"} ?? diskRate(process?.written,elapsed:current?.elapsed),color:.orange)
                    }
                    inspectorSection("IDENTITY / COVERAGE") {
                        inspectorRow("Started",Date(timeIntervalSince1970:Double(identity.start)/1_000_000).formatted(date:.abbreviated,time:.shortened))
                        inspectorRow("Observed parent",String(identity.parent))
                        inspectorRow("Samples in window",String(frames.filter {$0.processes.contains {$0.id==identity.id}}.count))
                        Text("Parent links are observations. Executable paths, signatures and arguments are not recorded. Missing readings are unavailable, not zero.").font(.system(size:9)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Select a process").font(.system(size:18,weight:.medium))
                    Text("Inspect its CPU, physical footprint, disk activity and estimated CPU energy at the shared cursor.").font(.system(size:11)).foregroundStyle(.secondary)
                    Divider()
                    Text("The process table and all tracks describe the same recorded moment. Drag any system track to inspect another time.").font(.system(size:10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(18)
        }.background(ExplorerPalette.inspector)
    }
    private func inspectorSection<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:8) {Text(title).font(.system(size:9,weight:.semibold)).tracking(1).foregroundStyle(.secondary);content()}
    }
    private func inspectorRow(_ title:String,_ value:String,color:Color = .primary)->some View {
        HStack(alignment:.firstTextBaseline,spacing:8) {Text(title).foregroundStyle(.secondary);Spacer(minLength:4);Text(value).monospacedDigit().foregroundStyle(color).multilineTextAlignment(.trailing)}.font(.system(size:10))
    }
}

private struct ExplorerPoint:Identifiable {
    let time:Date
    let value:Double
    let series:String
    let channel:String
    var id:String {"\(time.timeIntervalSince1970)-\(series)"}
}

struct ExplorerTrace:View {
    let frames:[Frame]
    let range:DateInterval
    let cursor:Date?
    let processID:String?
    let metric:String
    let gaps:[RecordingGap]
    var showXAxis=false
    private var color:Color {metric=="Memory" ? ExplorerPalette.memory : metric=="Disk" ? ExplorerPalette.disk : metric=="Energy" ? ExplorerPalette.energy : ExplorerPalette.cpu}
    private var points:[ExplorerPoint] {
        let correctedProcessCPU=processID != nil && metric=="CPU" && frames.contains {$0.processCPUAccounting != nil}
        var result:[ExplorerPoint]=[];var run=0
        for frame in frames.sorted(by:{$0.time<$1.time}) {
            let process=processID.flatMap {id in frame.processes.first {$0.id==id}}
            let elapsed=frame.elapsed ?? 0
            let blocked=elapsed>0 && gaps.contains {$0.start<frame.time && ($0.end ?? .distantFuture)>frame.time.addingTimeInterval(-elapsed)}
            var values:[(String,Double)]=[]
            if !blocked {
                switch metric {
                case "Memory":
                    if processID == nil {values=[("value",Double(frame.memory)/1048576)]}
                    else if let process {values=[("value",Double(process.memory)/1048576)]}
                case "Disk":
                    if elapsed>0 {
                        if processID == nil {
                            let reads=frame.processes.compactMap(\.read),writes=frame.processes.compactMap(\.written)
                            if !reads.isEmpty {values.append(("read",reads.reduce(0.0) {$0+Double($1)}/elapsed/1048576))}
                            if !writes.isEmpty {values.append(("write",writes.reduce(0.0) {$0+Double($1)}/elapsed/1048576))}
                        } else if let process {
                            if let read=process.read {values.append(("read",Double(read)/elapsed/1048576))}
                            if let written=process.written {values.append(("write",Double(written)/elapsed/1048576))}
                        }
                    }
                case "Energy":if let watts=process?.cpuPowerWatts(elapsed:frame.elapsed) {values=[("value",watts)]}
                default:
                    if processID == nil {values=[("value",frame.cpu)]}
                    else if let cpu=process?.cpu,!correctedProcessCPU || frame.processCPUAccounting != nil {values=[("value",cpu)]}
                }
            }
            if values.isEmpty {run+=1;continue}
            for (channel,value) in values where value.isFinite {
                result.append(ExplorerPoint(time:frame.time,value:value,series:(frame.segment ?? "legacy")+"-\(run)-"+channel,channel:channel))
            }
        }
        return result
    }
    private var domain:ClosedRange<Double> {
        if metric=="CPU" && processID==nil {return 0...100}
        if metric=="Memory" && processID==nil {return 0...Double(ProcessInfo.processInfo.physicalMemory)/1048576}
        return 0...max(1,(points.map(\.value).max() ?? 1)*1.08)
    }
    var body:some View {
        Chart {
            ForEach(points) {point in
                if metric=="CPU" && processID==nil {
                    AreaMark(x:.value("Time",point.time),y:.value("Value",point.value),series:.value("Series",point.series)).foregroundStyle(color.opacity(0.07))
                }
                LineMark(x:.value("Time",point.time),y:.value("Value",point.value),series:.value("Series",point.series))
                    .foregroundStyle(point.channel=="write" ? ExplorerPalette.energy : color).lineStyle(StrokeStyle(lineWidth:1.5))
            }
            if let cursor {RuleMark(x:.value("Cursor",cursor)).foregroundStyle(.secondary.opacity(0.55)).lineStyle(StrokeStyle(lineWidth:1))}
            ForEach(gaps.filter {$0.start<range.end && ($0.end ?? Date())>range.start}) {gap in
                RectangleMark(xStart:.value("Gap",max(range.start,gap.start)),xEnd:.value("Gap end",min(range.end,gap.end ?? Date()))).foregroundStyle(.orange.opacity(0.08))
            }
        }.chartXScale(domain:range.start...range.end).chartYScale(domain:domain).chartYAxis(.hidden).chartLegend(.hidden)
            .chartXAxis {
                if showXAxis {
                    AxisMarks(values:.automatic(desiredCount:5)) {value in
                        AxisValueLabel {
                            if let date=value.as(Date.self) {Text(date.formatted(.dateTime.hour().minute().second())).font(.system(size:9)).foregroundStyle(.secondary)}
                        }
                    }
                }
            }
    }
}

// Existing callers can keep the shared trace API while the Explorer adds aligned system tracks.
struct HistoryTrace:View {
    var frames:[Frame];var range:DateInterval;var cursor:Date?;var processID:String?;var metric:String;var gaps:[RecordingGap]
    var body:some View {ExplorerTrace(frames:frames,range:range,cursor:cursor,processID:processID,metric:metric,gaps:gaps,showXAxis:true)}
}

private enum ExplorerPalette {
    private static func adaptive(_ dark:(Double,Double,Double),_ light:(Double,Double,Double))->Color {
        Color(nsColor:NSColor(name:nil) {appearance in
            let rgb=appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed:rgb.0,green:rgb.1,blue:rgb.2,alpha:1)
        })
    }
    static let background=adaptive((0.105,0.132,0.16),(0.96,0.97,0.98))
    static let inspector=adaptive((0.09,0.115,0.145),(0.935,0.945,0.955))
    static let cpu=adaptive((0.59,0.84,0.75),(0.14,0.45,0.35))
    static let memory=adaptive((0.73,0.67,0.86),(0.43,0.32,0.63))
    static let disk=adaptive((0.60,0.74,0.91),(0.18,0.39,0.67))
    static let energy=adaptive((0.90,0.73,0.46),(0.57,0.36,0.10))
}

private struct ExplorerApplicationInspector:View {
    let group:AppPowerGroup?
    let summary:AppEnergySummary?
    let summaryMode:Bool
    let range:DateInterval
    let elapsed:Double?
    private var name:String? {summary?.name ?? group?.name}
    private var identity:String? {summary?.id ?? group?.id}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("APPLICATION INSPECTOR").font(.system(size:9,weight:.semibold)).tracking(1.4).foregroundStyle(.secondary)
                if let name {
                    Text(name).font(.system(size:20,weight:.semibold)).lineLimit(2)
                    Text(identity?.hasPrefix("app:") == true ? "Application bundle · observed members" : "Unassigned process · no captured app identity").font(.system(size:10)).foregroundStyle(.secondary)
                    Divider()
                    sectionTitle("CPU ENERGY · ESTIMATE")
                    if let summary,summaryMode {
                        valueRow("Average CPU power",summary.averagePower.map {explorerPower($0)+" W"} ?? "Unavailable",color:ExplorerPalette.energy)
                        valueRow("Sampled peak",summary.peakPower.map {explorerPower($0)+" W"} ?? "Unavailable")
                        valueRow("CPU energy",summary.energyCoveredSeconds>0 ? String(format:"%.3f J",summary.energyJoules) : "Unavailable")
                        valueRow("Observed process lifetimes",String(summary.observedProcesses))
                        Text(String(format:"Energy coverage %.1f / %.1f seconds",summary.energyCoveredSeconds,range.duration)).font(.system(size:10)).foregroundStyle(.secondary)
                        if summary.isPartial {coverageWarning}
                    } else if let group,!summaryMode {
                        valueRow("CPU power at cursor",group.cpuPowerWatts.map {explorerPower($0)+" W"} ?? "Unavailable",color:ExplorerPalette.energy)
                        valueRow("Observed CPU",explorerPercent(group.cpu),color:ExplorerPalette.cpu)
                        valueRow("Energy measured", "\(group.measuredEnergyProcesses) / \(group.observedProcesses) processes")
                        if group.isPartial {coverageWarning}
                    } else {
                        Text("Not observed at cursor.").font(.system(size:11)).foregroundStyle(.secondary)
                    }
                    Text("CPU-only energy summed across observed members. This is not Activity Monitor’s unitless Energy Impact score.").font(.system(size:10)).foregroundStyle(.secondary)
                    if summary?.hasUnattributedProcesses == true || group?.hasUnattributedProcesses == true {
                        Text("Some process queries were unavailable, so collection may omit helpers.").font(.system(size:10)).foregroundStyle(.orange)
                    }
                    Divider()
                    sectionTitle("GROUPING / COVERAGE")
                    Text("Processes are grouped by captured application bundle identity, with observed parent ancestry as a fallback. This is not macOS coalition accounting.").font(.system(size:10)).foregroundStyle(.secondary)
                    Text("Memory footprints are not added together because shared accounting can overlap.").font(.system(size:10)).foregroundStyle(.secondary)
                    if let group,!summaryMode {
                        Divider()
                        sectionTitle("OBSERVED MEMBERS")
                        ForEach(group.processes.prefix(12)) {process in
                            HStack(alignment:.top,spacing:8) {
                                VStack(alignment:.leading,spacing:3) {Text(process.name).lineLimit(1);Text("PID \(process.pid)").font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)}
                                Spacer(minLength:2)
                                Text(process.cpuPowerWatts(elapsed:elapsed).map {explorerPower($0)+" W"} ?? "—").monospacedDigit().foregroundStyle(ExplorerPalette.energy)
                            }.font(.system(size:10))
                        }
                        if group.observedProcesses>12 {Text("+ \(group.observedProcesses-12) other observed members").font(.system(size:9)).foregroundStyle(.secondary)}
                    }
                } else {
                    Text("Select an application").font(.system(size:18,weight:.medium))
                    Text("Inspect CPU energy aggregated across its observed processes. Switch to Processes for individual PIDs and full CPU, memory and disk details.").font(.system(size:11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(18)
        }.background(ExplorerPalette.inspector)
    }
    private var coverageWarning:some View {Text("Partial energy coverage: one or more observed members have no usable energy reading.").font(.system(size:10)).foregroundStyle(.orange)}
    private func sectionTitle(_ title:String)->some View {Text(title).font(.system(size:9,weight:.semibold)).tracking(1).foregroundStyle(.secondary)}
    private func valueRow(_ title:String,_ value:String,color:Color = .primary)->some View {
        HStack(alignment:.firstTextBaseline,spacing:8) {Text(title).foregroundStyle(.secondary);Spacer(minLength:4);Text(value).monospacedDigit().foregroundStyle(color).multilineTextAlignment(.trailing)}.font(.system(size:10))
    }
}
