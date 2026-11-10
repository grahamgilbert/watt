import SwiftUI
import WattEnergyProtocol

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
    @Published var impactSummaries:[String:ExplorerImpactSummary]=[:]
    @Published var networkGroups:[ProcessNetworkGroup]=[]
    @Published var networkGroupsLoading=false
    @Published var networkApplicationFilterID:String?
    @Published var networkApplicationFilterName:String?
    @Published var networkApplicationMemberIDs=Set<String>()
    let snapshotCache=ExplorerSnapshotCache()
    private var networkTask:Task<Void,Never>?
    private var networkRequest=UUID()
    private var networkHistoryKey:[Date]?
    func releaseDerivedData() {
        snapshotCache.clear();applicationSummaries=[];impactSummaries=[:];releaseNetworkGroups()
    }
    func releaseNetworkGroups() {
        networkTask?.cancel();networkTask=nil;networkRequest=UUID();networkHistoryKey=nil
        networkGroups=[];networkGroupsLoading=false
    }
    @MainActor func prepareNetworkGroups(frames:[Frame],range:DateInterval,gaps:[RecordingGap]) {
        let key=frames.map(\.time)+[range.start,range.end]+gaps.flatMap {[$0.start,$0.end ?? .distantFuture]}
        guard key != networkHistoryKey else {return}
        networkHistoryKey=key;networkTask?.cancel()
        let request=UUID();networkRequest=request
        networkGroups=[];networkGroupsLoading=true
        networkTask=Task { @MainActor [weak self] in
            let computation=Task.detached(priority:.utility) {
                HistoryAnalysis.networkGroups(frames,range:range,gaps:gaps,isCancelled:{Task<Never,Never>.isCancelled})
            }
            let groups=await withTaskCancellationHandler(operation:{await computation.value},onCancel:{computation.cancel()})
            guard !Task<Never,Never>.isCancelled,let self,self.networkRequest==request else {return}
            self.networkGroups=groups;self.networkGroupsLoading=false;self.networkTask=nil
        }
    }
    deinit {networkTask?.cancel()}
}

struct ProcessExplorerView:View {
    @ObservedObject var monitor:Monitor
    @StateObject private var traceCache=ExplorerTraceCache()
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
    private var networkFocus:Bool {controls.sort=="Network received" || controls.sort=="Network sent"}
    private var receivedFocus:Bool {controls.sort != "Network sent"}
    private var networkGroups:[ProcessNetworkGroup] {
        (summaryMode ? controls.networkGroups : snapshot.networkGroups).filter {group in
            controls.search.isEmpty || group.name.localizedCaseInsensitiveContains(controls.search) || group.members.values.contains {String($0.pid).contains(controls.search)}
        }.sorted {left,right in
            let a=receivedFocus ? left.totals.averageDownloadRate : left.totals.averageUploadRate
            let b=receivedFocus ? right.totals.averageDownloadRate : right.totals.averageUploadRate
            return a==b ? left.id<right.id : (a ?? -1)>(b ?? -1)
        }
    }
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
    private func refreshImpactSummaries() {
        controls.impactSummaries=ExplorerImpactSummary.summarize(displayFrames,range:range,gaps:monitor.visibleGaps)
    }
    private func refreshApplicationSummaries() {
        guard applicationsMode,summaryMode,!networkFocus else {return}
        controls.applicationSummaries=AppPowerGrouping.summarize(displayFrames,range:range,gaps:monitor.visibleGaps)
    }
    private func refreshNetworkGroups() {
        guard networkFocus,applicationsMode,summaryMode else {controls.releaseNetworkGroups();return}
        controls.prepareNetworkGroups(frames:displayFrames,range:range,gaps:monitor.visibleGaps)
    }
    private var snapshot:ExplorerSnapshotData {controls.snapshotCache.data(frame:monitor.current,includeDepths:controls.tree)}
    private var processes:[ProcessRow] {
        let all=snapshot.processes.filter {matches($0)}
        let impactScores=controls.sort=="Energy Impact" ? snapshot.impactScores : [:]
        let sorted=all.sorted {
            switch controls.sort {
            case "Energy Impact":return (impactScores[$0.id] ?? -1)>(impactScores[$1.id] ?? -1)
            case "CPU energy":return ($0.cpuPowerWatts(elapsed:monitor.current?.elapsed) ?? -1)>($1.cpuPowerWatts(elapsed:monitor.current?.elapsed) ?? -1)
            case "Memory":return ($0.memory.map(Double.init) ?? -1)>($1.memory.map(Double.init) ?? -1)
            case "Memory growth":return ($0.growth.map(Double.init) ?? -.infinity)>($1.growth.map(Double.init) ?? -.infinity)
            case "Disk read":return ($0.read ?? 0)>($1.read ?? 0)
            case "Disk write":return ($0.written ?? 0)>($1.written ?? 0)
            case "Network received":return (snapshot.networkTasks[$0.id]?.downloadRate(elapsed:snapshot.networkElapsed ?? 0) ?? -1)>(snapshot.networkTasks[$1.id]?.downloadRate(elapsed:snapshot.networkElapsed ?? 0) ?? -1)
            case "Network sent":return (snapshot.networkTasks[$0.id]?.uploadRate(elapsed:snapshot.networkElapsed ?? 0) ?? -1)>(snapshot.networkTasks[$1.id]?.uploadRate(elapsed:snapshot.networkElapsed ?? 0) ?? -1)
            default:return ($0.cpu ?? -1)>($1.cpu ?? -1)
            }
        }
        guard controls.tree else {return sorted}
        let pids=Set(all.map(\.pid));var result:[ProcessRow]=[];var seen=Set<String>()
        let children=Dictionary(grouping:sorted,by:\.parent)
        func append(_ row:ProcessRow) {guard seen.insert(row.id).inserted else {return};result.append(row);for child in children[row.pid] ?? [] {append(child)}}
        for row in sorted where !pids.contains(row.parent) {append(row)}
        for row in sorted {append(row)}
        return result
    }
    private var summaries:[ProcessSummary] {
        accountedSummaries.filter {matches($0.process)}.sorted {
            switch controls.sort {
            case "Energy Impact":return (controls.impactSummaries[$0.id]?.average ?? -1)>(controls.impactSummaries[$1.id]?.average ?? -1)
            case "CPU energy":return ($0.energyCoveredSeconds>0 ? $0.energyJoules : -1)>($1.energyCoveredSeconds>0 ? $1.energyJoules : -1)
            case "Memory":return ($0.peakMemory.map(Double.init) ?? -1)>($1.peakMemory.map(Double.init) ?? -1)
            case "Memory growth":return ($0.memoryChange.map(Double.init) ?? -.infinity)>($1.memoryChange.map(Double.init) ?? -.infinity)
            case "Disk read":return $0.readBytes>$1.readBytes
            case "Disk write":return $0.writtenBytes>$1.writtenBytes
            case "Network received":return ($0.network.receivedBytes.map(Double.init) ?? -1)>($1.network.receivedBytes.map(Double.init) ?? -1)
            case "Network sent":return ($0.network.sentBytes.map(Double.init) ?? -1)>($1.network.sentBytes.map(Double.init) ?? -1)
            default:return $0.cpuSeconds>$1.cpuSeconds
            }
        }
    }
    private func matches(_ process:ProcessRow)->Bool {
        if networkFocus,let filter=controls.networkApplicationFilterID {
            let id=process.applicationID.flatMap {$0.isEmpty ? nil : "app:"+$0} ?? "process:"+process.id
            let recorded=snapshot.networkGroupIDs[process.id] ?? id
            guard recorded==filter || controls.networkApplicationMemberIDs.contains(process.id) else {return false}
        }
        return controls.search.isEmpty || process.name.localizedCaseInsensitiveContains(controls.search) || String(process.pid).contains(controls.search)
    }
    private func depth(_ row:ProcessRow)->Int {
        guard controls.tree else {return 0}
        return snapshot.depths[row.id] ?? 0
    }
    private func load() {monitor.loadHistory(center:controls.center,duration:controls.duration);controls.mode="Interval summary"}
    private func moveWindow(_ direction:Double) {controls.center=controls.center.addingTimeInterval(controls.duration*direction);load()}
    private func selectTime(_ date:Date) {monitor.selected=date;controls.mode="At cursor"}
    private var selectedIdentity:ProcessRow? {
        guard let id=controls.selection else {return nil}
        return snapshot.processes.first(where:{$0.id==id}) ?? monitor.historySummaries.first(where:{$0.id==id})?.process ?? displayFrames.reversed().lazy.compactMap {$0.processes.first(where:{$0.id==id})}.first
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
                        if networkFocus {networkApplicationTable}
                        else if summaryMode {applicationSummaryTable} else {applicationSnapshotTable}
                    } else {
                        if summaryMode {summaryTable} else {snapshotTable}
                        if let identity=selectedIdentity {Divider();selectedProcessTracks(identity)}
                    }
                    tableFooter
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                if applicationsMode {
                    if networkFocus {
                        ExplorerNetworkApplicationInspector(group:networkGroups.first {$0.id==controls.applicationSelection},summaryMode:summaryMode,range:range,onInspect:inspectNetworkMember).frame(width:290)
                    } else {
                        ExplorerApplicationInspector(group:applicationGroups.first {$0.id==controls.applicationSelection},summary:summaryMode ? applicationSummaries.first {$0.id==controls.applicationSelection} : nil,summaryMode:summaryMode,range:range,elapsed:monitor.current?.elapsed).frame(width:290)
                    }
                } else {
                    ProcessInspector(identity:selectedIdentity,current:monitor.current,summary:summaryMode ? accountedSummaries.first(where:{$0.id==controls.selection}) : nil,frames:displayFrames,range:range,cursor:cursor,gaps:monitor.visibleGaps,impactSummary:summaryMode ? controls.impactSummaries[controls.selection ?? ""] : nil)
                        .frame(width:290)
                }
            }.frame(maxHeight:.infinity)
            Divider()
            statusFooter
        }.background(ExplorerPalette.background)
            .frame(minWidth:1280,minHeight:780)
            .onChange(of:controls.scope) {_,_ in
                if applicationsMode && !networkFocus {controls.sort="CPU energy"}
                refreshApplicationSummaries();refreshNetworkGroups()
            }
            .onChange(of:controls.mode) {_,_ in
                refreshImpactSummaries()
                if applicationsMode && summaryMode && !networkFocus {controls.sort="CPU energy"}
                refreshApplicationSummaries();refreshNetworkGroups()
            }
            .onChange(of:controls.sort) {_,_ in refreshApplicationSummaries();refreshNetworkGroups()}
            .onChange(of:monitor.historyLoading) {_,loading in if loading {controls.applicationSummaries=[];controls.impactSummaries=[:];controls.releaseNetworkGroups()} else {refreshApplicationSummaries();refreshImpactSummaries();refreshNetworkGroups()}}
            .onAppear {
                refreshImpactSummaries()
                refreshApplicationSummaries();refreshNetworkGroups()
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
            Picker("Window",selection:$controls.duration) {
                if ![60.0,120,300,900,3600,7200].contains(controls.duration) {Text(String(format:"%.0f seconds",controls.duration)).tag(controls.duration)}
                Text("1 minute").tag(60.0);Text("2 minutes").tag(120.0);Text("5 minutes").tag(300.0);Text("15 minutes").tag(900.0);Text("1 hour").tag(3600.0);Text("2 hours").tag(7200.0)
            }.labelsHidden().frame(width:110)
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
            ExplorerSystemTrack(title:"CPU",value:monitor.current.map {String(format:"%.0f%%",$0.cpu)} ?? "—",subtitle:"Machine capacity · 0–100%",metric:"CPU",color:ExplorerPalette.cpu,frames:displayFrames,range:range,cursor:cursor,gaps:monitor.visibleGaps,traceCache:traceCache,onSelect:selectTime)
            ExplorerSystemTrack(title:"Memory",value:monitor.current.map {"\(bytes($0.memory)) / \(bytes(ProcessInfo.processInfo.physicalMemory))"} ?? "—",subtitle:monitor.current.map {$0.memoryAccounting == nil ? "Legacy VM estimate" : "Used RAM · reclaimable cache excluded"} ?? "No sample at cursor",metric:"Memory",color:ExplorerPalette.memory,frames:displayFrames,range:range,cursor:cursor,gaps:monitor.visibleGaps,traceCache:traceCache,onSelect:selectTime)
            if networkFocus {
                ExplorerSystemTrack(title:"Network",value:systemNetworkText,subtitle:"Physical interfaces · download / upload",metric:"Network",color:ExplorerPalette.network,frames:displayFrames,range:range,cursor:cursor,gaps:monitor.visibleGaps,traceCache:traceCache,onSelect:selectTime)
            } else {
                ExplorerSystemTrack(title:"Disk I/O",value:systemDiskText,subtitle:"Observed processes · read / write",metric:"Disk",color:ExplorerPalette.disk,frames:displayFrames,range:range,cursor:cursor,gaps:monitor.visibleGaps,traceCache:traceCache,onSelect:selectTime)
            }
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
    private var systemNetworkText:String {
        guard let frame=monitor.current else {return "—"}
        return "\(popupRateValue(frame.download).description) / \(popupRateValue(frame.upload).description)"
    }
    private var processToolbar:some View {
        HStack(spacing:10) {
            HStack(spacing:6) {Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField(applicationsMode ? "Application or PID" : "Process or PID",text:$controls.search).textFieldStyle(.plain).accessibilityLabel(applicationsMode ? "Search applications or PIDs" : "Search processes or PIDs").accessibilityIdentifier("explorer.processSearch")}
                .font(.system(size:11)).padding(.horizontal,8).frame(width:160,height:26).background(.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:5))
            Picker("Scope",selection:$controls.scope) {Text("Processes").tag("Processes");Text("Applications").tag("Applications")}.pickerStyle(.segmented).labelsHidden().frame(width:180)
            Picker("View",selection:$controls.mode) {Text("At cursor").tag("At cursor");Text("Interval summary").tag("Interval summary")}.pickerStyle(.segmented).labelsHidden().frame(width:175).disabled(monitor.historyRange==nil)
            Picker("Rank",selection:$controls.sort) {
                ForEach(applicationsMode ? ["CPU","CPU energy","Network received","Network sent"] : ["CPU","Energy Impact","CPU energy","Memory","Memory growth","Disk read","Disk write","Network received","Network sent"],id:\.self){Text($0).tag($0).disabled(applicationsMode && summaryMode && $0=="CPU")}
            }.frame(width:135)
            if !applicationsMode {Toggle("Parent tree",isOn:$controls.tree).toggleStyle(.checkbox).disabled(summaryMode)}
            if networkFocus,!applicationsMode,let name=controls.networkApplicationFilterName {
                HStack(spacing:4) {
                    Text("\(name) helpers").lineLimit(1)
                    Button {controls.networkApplicationFilterID=nil;controls.networkApplicationFilterName=nil;controls.networkApplicationMemberIDs=[]} label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.borderless).accessibilityLabel("Show all processes")
                }.foregroundStyle(ExplorerPalette.network)
            }
            Spacer(minLength:0)
        }.font(.system(size:11)).controlSize(.small).padding(.horizontal,16).padding(.vertical,10)
    }
    private var tableFooter:some View {
        HStack {
            Text(applicationsMode ? "\(networkFocus ? networkGroups.count : summaryMode ? applicationSummaries.count : applicationGroups.count) observed application / unassigned groups" : summaryMode ? "\(summaries.count) process instances · \(monitor.historyFrames.count) samples" : "\(processes.count) observed processes").foregroundStyle(.secondary)
            Spacer()
            Text(networkFocus ? "External TCP/UDP attribution · differs from physical-interface totals" : applicationsMode ? "Observed members only · application bundles, not macOS coalitions" : summaryMode && mixedCPUAccounting ? "CPU coverage uses corrected records only" : summaryMode ? "Complete covered intervals only" : "CPU 100% = one core · footprints are not additive").foregroundStyle(.tertiary)
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
            if let frame=monitor.current {
                let restricted=frame.processes.reduce(0) {$0+($1.memory == nil ? 1 : 0)}
                Text(restricted>0 ? "\(frame.processes.count) listed · \(restricted) restricted" : "\(frame.processes.count) observed · \(max(0,frame.denied)) queries unavailable").foregroundStyle(.secondary)
            }
            else if let reason=monitor.selectionGap()?.reason {Text(reason).foregroundStyle(.orange)}
            else {Text("No nearby recorded sample at cursor").foregroundStyle(.orange)}
            if let bounds=monitor.historyBounds {Text("Retained \(bounds.start.formatted(date:.abbreviated,time:.shortened))").foregroundStyle(.tertiary)}
        }.font(.system(size:10)).lineLimit(1).padding(.horizontal,20).padding(.vertical,9)
    }
    private func selectedProcessTracks(_ identity:ProcessRow)->some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {Text("\(identity.name) · PID \(identity.pid)").fontWeight(.semibold);Spacer();Text("Selected process · shared timeline").foregroundStyle(.secondary)}.font(.system(size:10))
            ForEach(networkFocus ? ["CPU","Memory","Energy","Disk","Network"] : ["CPU","Memory","Energy","Disk"],id:\.self) {metric in
                HStack(spacing:12) {
                    Text(metric=="Memory" ? "Physical footprint · MiB" : metric=="Energy" ? "CPU power · W est." : metric=="Disk" ? "Disk read / write · MiB/s" : metric=="Network" ? "Network received / sent · MB/s" : "CPU · one-core %")
                        .font(.system(size:9)).foregroundStyle(metric=="Memory" ? ExplorerPalette.memory : metric=="Energy" ? ExplorerPalette.energy : metric=="Disk" ? ExplorerPalette.disk : metric=="Network" ? ExplorerPalette.network : ExplorerPalette.cpu).frame(width:155,alignment:.leading)
                    ExplorerTrace(frames:displayFrames,range:range,cursor:cursor,processID:identity.id,metric:metric,gaps:monitor.visibleGaps,showXAxis:false,traceCache:traceCache).frame(height:25)
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
    private var networkApplicationTable:some View {
        Table(networkGroups,selection:$controls.applicationSelection) {
            TableColumn("Application / unassigned process") {Text($0.name)}.width(min:200,ideal:260)
            TableColumn(summaryMode ? "Received avg/s" : "Download/s") {Text(explorerNetworkRateText($0.totals.averageDownloadRate)).foregroundStyle(ExplorerPalette.network)}.width(115)
            TableColumn(summaryMode ? "Sent avg/s" : "Upload/s") {Text(explorerNetworkRateText($0.totals.averageUploadRate)).foregroundStyle(ExplorerPalette.energy)}.width(115)
            TableColumn(summaryMode ? "Received / sent in range" : "Received / sent in capture") {Text("\($0.totals.receivedBytes.map(bytes) ?? "—") / \($0.totals.sentBytes.map(bytes) ?? "—")")}.width(170)
            TableColumn("Observed members") {Text("\($0.members.count)\($0.isPartial ? " · partial" : "")")}.width(115)
        }.tableStyle(.inset(alternatesRowBackgrounds:false)).font(.system(size:11)).monospacedDigit().controlSize(.small).frame(maxHeight:.infinity)
            .overlay {if controls.networkGroupsLoading {ProgressView("Summarizing network captures…").padding(16).background(ExplorerPalette.background,in:RoundedRectangle(cornerRadius:8))}}
    }
    private func inspectNetworkMember(_ process:ProcessRow,_ group:ProcessNetworkGroup) {
        controls.networkApplicationFilterID=group.id;controls.networkApplicationFilterName=group.name
        controls.networkApplicationMemberIDs=Set(group.members.keys)
        controls.selection=process.id;controls.search="";controls.scope="Processes"
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
    @ViewBuilder private var snapshotTable:some View {
        if networkFocus {networkSnapshotTable} else {resourceSnapshotTable}
    }
    private var resourceSnapshotTable:some View {
        Table(processes,selection:$controls.selection) {
            TableColumn("Process / observed parent") {p in processLabel(p).padding(.leading,CGFloat(depth(p))*12)}.width(min:150,ideal:205)
            TableColumn("PID") {Text(String($0.pid))}.width(52)
            TableColumn("Parent") {Text(String($0.parent))}.width(52)
            TableColumn("CPU %") {Text($0.cpu.map {String(format:"%.1f",$0)} ?? "—").foregroundStyle(ExplorerPalette.cpu).help(monitor.current?.processCPUAccounting == nil ? "Legacy recorded CPU values use the prototype scaling and can be underreported." : "CPU 100% equals one core. Native Mach CPU time has been converted to nanoseconds.")}.width(70)
            TableColumn("Energy Impact") {Text(explorerImpactText(snapshot.impactScores[$0.id])).foregroundStyle(ExplorerPalette.energy).help("Apple powermetrics unitless energy_impact_per_s score. Not watts; unavailable or stale captures show a dash.")}.width(105)
            TableColumn("CPU W est.") {Text(explorerPower($0.cpuPowerWatts(elapsed:monitor.current?.elapsed)))}.width(85)
            TableColumn("Footprint") {Text($0.memory.map(bytes) ?? "—")}.width(100)
            TableColumn("Δ memory") {p in Text(explorerDelta(p.growth))}.width(95)
            TableColumn("Read/s") {Text(diskRate($0.read,elapsed:monitor.current?.elapsed))}.width(100)
            TableColumn("Write/s") {Text(diskRate($0.written,elapsed:monitor.current?.elapsed))}.width(100)
        }.tableStyle(.inset(alternatesRowBackgrounds:false)).font(.system(size:11)).monospacedDigit().controlSize(.small).frame(maxHeight:.infinity)
    }
    private var networkSnapshotTable:some View {
        Table(processes,selection:$controls.selection) {
            TableColumn("Process / observed parent") {p in processLabel(p).padding(.leading,CGFloat(depth(p))*12)}.width(min:150,ideal:205)
            TableColumn("PID") {Text(String($0.pid))}.width(52)
            TableColumn("Parent") {Text(String($0.parent))}.width(52)
            TableColumn("CPU %") {Text(explorerPercent($0.cpu)).foregroundStyle(ExplorerPalette.cpu)}.width(70)
            TableColumn("Download/s") {Text(explorerNetworkRateText(snapshot.networkTasks[$0.id]?.downloadRate(elapsed:snapshot.networkElapsed ?? 0))).foregroundStyle(ExplorerPalette.network)}.width(105)
            TableColumn("Upload/s") {Text(explorerNetworkRateText(snapshot.networkTasks[$0.id]?.uploadRate(elapsed:snapshot.networkElapsed ?? 0))).foregroundStyle(ExplorerPalette.energy)}.width(105)
            TableColumn("Footprint") {Text($0.memory.map(bytes) ?? "—")}.width(100)
            TableColumn("Δ memory") {Text(explorerDelta($0.growth))}.width(95)
            TableColumn("Read/s") {Text(diskRate($0.read,elapsed:monitor.current?.elapsed))}.width(100)
            TableColumn("Write/s") {Text(diskRate($0.written,elapsed:monitor.current?.elapsed))}.width(100)
        }.tableStyle(.inset(alternatesRowBackgrounds:false)).font(.system(size:11)).monospacedDigit().controlSize(.small).frame(maxHeight:.infinity)
    }
    @ViewBuilder private var summaryTable:some View {
        if networkFocus {networkSummaryTable} else {resourceSummaryTable}
    }
    private var resourceSummaryTable:some View {
        Table(summaries,selection:$controls.selection) {
            TableColumn("Process") {processLabel($0.process)}.width(min:150,ideal:205)
            TableColumn("PID") {Text(String($0.process.pid))}.width(52)
            TableColumn("CPU avg / peak") {p in Text("\(explorerPercent(p.averageCPU)) / \(explorerPercent(p.peakCPU))").foregroundStyle(ExplorerPalette.cpu)}.width(125)
            TableColumn("Impact avg / peak") {p in Text(controls.impactSummaries[p.id].map {"\(explorerImpactText($0.average)) / \(explorerImpactText($0.peak))"} ?? "—").foregroundStyle(ExplorerPalette.energy)}.width(120)
            TableColumn("CPU W avg / peak") {p in Text("\(explorerPower(p.averagePower)) / \(explorerPower(p.peakPower))")}.width(125)
            TableColumn("CPU energy · J") {p in Text(p.energyCoveredSeconds>0 ? String(format:"%.3f",p.energyJoules) : "—")}.width(95)
            TableColumn("CPU time") {Text($0.cpuCoveredSeconds>0 ? String(format:"%.2f s",$0.cpuSeconds) : "—")}.width(80)
            TableColumn("Footprint last / peak") {p in Text("\(p.lastMemory.map(bytes) ?? "—") / \(p.peakMemory.map(bytes) ?? "—")")}.width(165)
            TableColumn("Δ memory") {p in Text(explorerDelta(p.memoryChange))}.width(95)
            TableColumn("Read / write total") {p in Text(p.ioSamples>0 ? "\(bytes(p.readBytes)) / \(bytes(p.writtenBytes))" : "—")}.width(170)
        }.tableStyle(.inset(alternatesRowBackgrounds:false)).font(.system(size:11)).monospacedDigit().controlSize(.small).frame(maxHeight:.infinity)
    }
    private var networkSummaryTable:some View {
        Table(summaries,selection:$controls.selection) {
            TableColumn("Process") {processLabel($0.process)}.width(min:150,ideal:205)
            TableColumn("PID") {Text(String($0.process.pid))}.width(52)
            TableColumn("CPU avg / peak") {Text("\(explorerPercent($0.averageCPU)) / \(explorerPercent($0.peakCPU))").foregroundStyle(ExplorerPalette.cpu)}.width(125)
            TableColumn("Received in range") {Text($0.network.receivedBytes.map(bytes) ?? "—")}.width(115)
            TableColumn("Sent in range") {Text($0.network.sentBytes.map(bytes) ?? "—")}.width(115)
            TableColumn("Download avg / peak") {Text("\(explorerNetworkRateText($0.network.averageDownloadRate)) / \(explorerNetworkRateText($0.network.peakDownloadRate))")}.width(170)
            TableColumn("Upload avg / peak") {Text("\(explorerNetworkRateText($0.network.averageUploadRate)) / \(explorerNetworkRateText($0.network.peakUploadRate))")}.width(170)
            TableColumn("Footprint last / peak") {Text("\($0.lastMemory.map(bytes) ?? "—") / \($0.peakMemory.map(bytes) ?? "—")")}.width(165)
            TableColumn("Δ memory") {Text(explorerDelta($0.memoryChange))}.width(95)
            TableColumn("Read / write total") {Text($0.ioSamples>0 ? "\(bytes($0.readBytes)) / \(bytes($0.writtenBytes))" : "—")}.width(170)
        }.tableStyle(.inset(alternatesRowBackgrounds:false)).font(.system(size:11)).monospacedDigit().controlSize(.small).frame(maxHeight:.infinity)
    }
    @ViewBuilder private func processLabel(_ process:ProcessRow)->some View {
        if process.metricSource=="network" {
            HStack(spacing:5) {Image(systemName:"network").font(.system(size:9)).foregroundStyle(.secondary).accessibilityLabel("Network observation only");Text(process.name)}.accessibilityElement(children:.combine)
        } else if process.memory == nil {
            HStack(spacing:5) {
                Image(systemName:"lock.fill").font(.system(size:9)).foregroundStyle(.secondary)
                    .accessibilityLabel("Restricted metrics").help("macOS withheld process resource metrics. The process is still recorded.")
                Text(process.name)
            }.accessibilityElement(children:.combine)
        } else {Text(process.name)}
    }
}

private func explorerPower(_ value:Double?)->String {value.map {String(format:$0<0.01 ? "%.3f" : "%.2f",$0)} ?? "—"}
private func explorerPercent(_ value:Double?)->String {value.map {String(format:"%.1f%%",$0)} ?? "—"}
private func explorerDelta(_ value:Int64?)->String {value.map {$0 == 0 ? "0 B" : ($0<0 ? "−" : "+")+bytes(UInt64(abs($0)))} ?? "—"}
private func explorerNetworkRateText(_ value:Double?)->String {value.map {popupRateValue($0).description} ?? "—"}

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
    let traceCache:ExplorerTraceCache
    let onSelect:(Date)->Void
    var body:some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:3) {
                HStack(spacing:10) {Text(title).fontWeight(.semibold).foregroundStyle(color);Text(value).monospacedDigit()}.font(.system(size:11))
                Text(subtitle).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width:255,alignment:.leading)
            ExplorerTrace(frames:frames,range:range,cursor:cursor,processID:nil,metric:metric,gaps:gaps,showXAxis:metric=="Disk",traceCache:traceCache)
                .frame(height:metric=="Disk" ? 61 : 42)
                .overlay {
                    GeometryReader {geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged {event in
                            if let date=ExplorerTimelinePosition.time(atX:event.location.x,width:geometry.size.width,range:range) {onSelect(date)}
                        })
                    }
                }.accessibilityLabel("\(title) timeline")
                .accessibilityValue(cursor.map {$0.formatted(date:.abbreviated,time:.standard)} ?? "No selected time")
                .accessibilityAdjustableAction {direction in
                    let step=max(1,frames.last?.cadence ?? frames.last?.elapsed ?? 5)
                    let date=cursor ?? range.end
                    switch direction {
                    case .increment:onSelect(min(range.end,date.addingTimeInterval(step)))
                    case .decrement:onSelect(max(range.start,date.addingTimeInterval(-step)))
                    @unknown default:break
                    }
                }
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
    let impactSummary:ExplorerImpactSummary?
    private var process:ProcessRow? {
        guard let identity else {return nil}
        return current?.processes.first {$0.id==identity.id} ?? networkTask.map(HistoryAnalysis.networkIdentity)
    }
    private var networkTask:ProcessNetworkTask? {
        guard let identity,let current,let sample=current.processNetwork,sample.isFresh(at:current.time) else {return nil}
        return sample.tasks.first {$0.id==identity.id}
    }
    private var displayedCPU:Double? {if let summary {return summary.averageCPU};return process?.cpu}
    private var hasLegacyCPU:Bool {frames.contains {$0.processCPUAccounting == nil && $0.processes.contains {$0.id==identity?.id}}}
    private var hasCorrectedCPU:Bool {frames.contains {$0.processCPUAccounting != nil && $0.processes.contains {$0.id==identity?.id}}}
    private var displayedPower:Double? {if let summary {return summary.averagePower};return process?.cpuPowerWatts(elapsed:current?.elapsed)}
    private var displayedMemory:UInt64? {if let summary {return summary.lastMemory};return process?.memory}
    private var coverageIdentity:ProcessRow? {summary?.process ?? process ?? identity}
    private var metricSource:String? {
        switch coverageIdentity?.metricSource {
        case "local":return "App"
        case "privileged":return "Privileged collector"
        case "restricted":return "Restricted by macOS"
        case "network":return "Network observation only"
        default:return nil
        }
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:17) {
                Text("PROCESS INSPECTOR").font(.system(size:9,weight:.semibold)).tracking(1.4).foregroundStyle(.secondary)
                if let identity {
                    VStack(alignment:.leading,spacing:5) {
                        Text(identity.name).font(.system(size:20,weight:.semibold)).lineLimit(2)
                        Text("PID \(identity.pid) · parent \(identity.parent)").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                        Text(summary != nil ? "Selected interval" : coverageIdentity?.metricSource=="network" ? "Observed in network capture" : process == nil ? "Not observed at cursor" : "Observed at cursor").font(.system(size:10)).foregroundStyle(.secondary)
                        if coverageIdentity?.metricSource=="network" {
                            Label("Network observation only",systemImage:"network").font(.system(size:10)).foregroundStyle(.secondary)
                        } else if coverageIdentity?.memory == nil {
                            Label("Resource metrics restricted",systemImage:"lock.fill").font(.system(size:10)).foregroundStyle(.secondary)
                            Text("macOS withheld process metrics. The privileged collector in Preferences can improve coverage; some protected processes remain restricted.").font(.system(size:9)).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    inspectorSection("CPU") {
                        if coverageIdentity?.metricSource != "network",(summary != nil && hasLegacyCPU) || (summary == nil && current?.processCPUAccounting == nil) {
                            Text(hasCorrectedCPU && summary != nil ? "Corrected records only; legacy CPU samples excluded." : "Legacy recorded CPU scaling · may be underreported.").font(.system(size:9)).foregroundStyle(.orange)
                        }
                        inspectorRow("\(summary == nil ? "At cursor" : "Average") · one-core %",explorerPercent(displayedCPU),color:ExplorerPalette.cpu)
                        if let summary {inspectorRow("Sampled peak",explorerPercent(summary.peakCPU));inspectorRow("Covered CPU time",summary.cpuCoveredSeconds>0 ? String(format:"%.2f s",summary.cpuSeconds) : "—")}
                    }
                    inspectorSection("MEMORY BEHAVIOR") {
                        inspectorRow("Physical footprint",displayedMemory.map(bytes) ?? "—",color:ExplorerPalette.memory)
                        if let summary {inspectorRow("Peak in interval",summary.peakMemory.map(bytes) ?? "—");inspectorRow("End − start",explorerDelta(summary.memoryChange))}
                        else {inspectorRow("Change in sample",explorerDelta(process?.growth))}
                    }
                    inspectorSection("APPLE ENERGY IMPACT") {
                        if let impactSummary {
                            inspectorRow("Average score",explorerImpactText(impactSummary.average),color:ExplorerPalette.energy)
                            inspectorRow("Sampled peak",explorerImpactText(impactSummary.peak))
                            inspectorRow("Distinct captures",String(impactSummary.captures))
                            Text(String(format:"Captured coverage %.1f / %.1f seconds",impactSummary.coveredSeconds,range.duration)).font(.system(size:9)).foregroundStyle(.secondary)
                        } else {
                            inspectorRow(summary == nil ? "Score at cursor" : "Average score",explorerImpactText(summary == nil ? process.flatMap {explorerImpact($0,frame:current)} : nil),color:ExplorerPalette.energy)
                            if summary == nil,let process,explorerImpact(process,frame:current) != nil,let frame=current,let capture=frame.energyImpact {
                                Text(String(format:"Capture age at cursor %.1f s · sampled %.1f s",frame.time.timeIntervalSince(capture.endedAt),capture.endedAt.timeIntervalSince(capture.startedAt))).font(.system(size:9)).foregroundStyle(.secondary)
                            }
                        }
                        Text("Apple powermetrics unitless per-second score. Includes more than CPU energy; Activity Monitor may use different grouping and sampling. — means no matching fresh capture.").font(.system(size:9)).foregroundStyle(.secondary)
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
                    inspectorSection("NETWORK ACTIVITY") {
                        if let summary {
                            inspectorRow("Received in range",summary.network.receivedBytes.map(bytes) ?? "—",color:ExplorerPalette.network)
                            inspectorRow("Sent in range",summary.network.sentBytes.map(bytes) ?? "—",color:ExplorerPalette.energy)
                            inspectorRow("Download avg / peak","\(explorerNetworkRateText(summary.network.averageDownloadRate)) / \(explorerNetworkRateText(summary.network.peakDownloadRate))")
                            inspectorRow("Upload avg / peak","\(explorerNetworkRateText(summary.network.averageUploadRate)) / \(explorerNetworkRateText(summary.network.peakUploadRate))")
                            inspectorRow("Distinct captures",String(summary.network.captures))
                            Text(String(format:"Receive / send coverage %.1f / %.1f seconds of %.1f",summary.network.receiveCoveredSeconds,summary.network.sendCoveredSeconds,range.duration)).font(.system(size:9)).foregroundStyle(.secondary)
                        } else if let task=networkTask,let capture=current?.processNetwork {
                            inspectorRow("Download rate",explorerNetworkRateText(task.downloadRate(elapsed:capture.elapsed)),color:ExplorerPalette.network)
                            inspectorRow("Upload rate",explorerNetworkRateText(task.uploadRate(elapsed:capture.elapsed)),color:ExplorerPalette.energy)
                            inspectorRow("Received / sent in capture","\(task.receivedBytes.map(bytes) ?? "—") / \(task.sentBytes.map(bytes) ?? "—")")
                            Text(String(format:"Captured %.1f s · age %.1f s at cursor",capture.elapsed,current?.time.timeIntervalSince(capture.endedAt) ?? 0)).font(.system(size:9)).foregroundStyle(.secondary)
                        } else {
                            Text(current?.processNetwork == nil ? "Process traffic not recorded." : "No matching fresh process traffic capture.").font(.system(size:10)).foregroundStyle(.secondary)
                        }
                        Text("Observed external TCP/UDP traffic. Its attribution scope differs from physical-interface totals. Missing counters are unavailable, not zero.").font(.system(size:9)).foregroundStyle(.secondary)
                    }
                    inspectorSection("IDENTITY / COVERAGE") {
                        inspectorRow("Started",Date(timeIntervalSince1970:Double(identity.start)/1_000_000).formatted(date:.abbreviated,time:.shortened))
                        inspectorRow("Observed parent",String(identity.parent))
                        if let uid=coverageIdentity?.userID {inspectorRow("Owner",uid == 0 ? "root · UID 0" : "UID \(uid)")}
                        if let metricSource {inspectorRow("Resource metrics",metricSource)}
                        inspectorRow("Samples in window",String(frames.filter {$0.processes.contains {$0.id==identity.id}}.count))
                        Text("Parent links are observations. Executable paths, signatures and arguments are not recorded. Missing readings are unavailable, not zero.").font(.system(size:9)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Select a process").font(.system(size:18,weight:.medium))
                    Text("Inspect its CPU, physical footprint, disk/network activity and estimated CPU energy at the shared cursor.").font(.system(size:11)).foregroundStyle(.secondary)
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

struct ExplorerPoint:Identifiable {
    let time:Date
    let value:Double
    let series:String
    let channel:String
    var id:String {"\(time.timeIntervalSince1970)-\(series)"}
}

// Frame timestamps identify immutable recorded snapshots. Keep derived chart values
// separate from the moving cursor so dragging never scans the process inventory.
struct ExplorerTraceData {
    var points:[ExplorerPoint]=[]
    var domain:ClosedRange<Double>=0...1
}
final class ExplorerTraceCache:ObservableObject {
    private struct GapKey:Equatable {let id:String;let start:Date;let end:Date?}
    private var frameTimes:[Date]=[]
    private var networkCaptureIDs:[String?]=[]
    private var gapKeys:[GapKey]=[]
    private var system:[String:ExplorerTraceData]?
    private var selected:(id:String,data:[String:ExplorerTraceData])?
    private(set) var preparationCount=0
    func data(frames:[Frame],gaps:[RecordingGap],processID:String?,metric:String)->ExplorerTraceData {
        let times=frames.map(\.time),networkIDs=frames.map {$0.processNetwork?.id},keys=gaps.map {GapKey(id:$0.id,start:$0.start,end:$0.end)}
        if times != frameTimes || networkIDs != networkCaptureIDs || keys != gapKeys {
            frameTimes=times;networkCaptureIDs=networkIDs;gapKeys=keys;system=nil;selected=nil
        }
        if let processID {
            if selected?.id != processID {selected=(processID,prepare(frames:frames,gaps:gaps,processID:processID))}
            return selected?.data[metric] ?? ExplorerTraceData()
        }
        if system == nil {system=prepare(frames:frames,gaps:gaps,processID:nil)}
        return system?[metric] ?? ExplorerTraceData()
    }
    private func prepare(frames:[Frame],gaps:[RecordingGap],processID:String?)->[String:ExplorerTraceData] {
        preparationCount+=1
        let metrics=["CPU","Memory","Energy","Disk","Network"]
        var result=Dictionary(uniqueKeysWithValues:metrics.map {($0,ExplorerTraceData())})
        var runs=Dictionary(uniqueKeysWithValues:metrics.map {($0,0)})
        let correctedCPU=processID != nil && frames.contains {$0.processCPUAccounting != nil}
        for frame in frames.sorted(by:{$0.time<$1.time}) {
            let process=processID.flatMap {id in frame.processes.first {$0.id==id}}
            let elapsed=frame.elapsed ?? 0
            let blocked=elapsed>0 && gaps.contains {$0.start<frame.time && ($0.end ?? .distantFuture)>frame.time.addingTimeInterval(-elapsed)}
            var values:[String:[(String,Double)]]=[:]
            if !blocked {
                if processID == nil {
                    values["CPU"]=[("value",frame.cpu)]
                    values["Memory"]=[("value",Double(frame.memory)/1048576)]
                    values["Network"]=[("read",frame.download/1_000_000),("write",frame.upload/1_000_000)]
                    if elapsed>0 {
                        var read=0.0,write=0.0,hasRead=false,hasWrite=false
                        for row in frame.processes {
                            if let bytes=row.read {read+=Double(bytes);hasRead=true}
                            if let bytes=row.written {write+=Double(bytes);hasWrite=true}
                        }
                        if hasRead {values["Disk",default:[]].append(("read",read/elapsed/1048576))}
                        if hasWrite {values["Disk",default:[]].append(("write",write/elapsed/1048576))}
                    }
                } else if let process {
                    if let cpu=process.cpu,!correctedCPU || frame.processCPUAccounting != nil {values["CPU"]=[("value",cpu)]}
                    if let memory=process.memory {values["Memory"]=[("value",Double(memory)/1048576)]}
                    if let watts=process.cpuPowerWatts(elapsed:frame.elapsed) {values["Energy"]=[("value",watts)]}
                    if elapsed>0 {
                        if let bytes=process.read {values["Disk",default:[]].append(("read",Double(bytes)/elapsed/1048576))}
                        if let bytes=process.written {values["Disk",default:[]].append(("write",Double(bytes)/elapsed/1048576))}
                    }
                }
            }
            for metric in metrics {
                let channels=values[metric] ?? []
                if channels.isEmpty {runs[metric,default:0]+=1;continue}
                for (channel,value) in channels where value.isFinite {
                    let point=ExplorerPoint(time:frame.time,value:value,series:(frame.segment ?? "legacy")+"-\(runs[metric,default:0])-"+channel,channel:channel)
                    result[metric,default:ExplorerTraceData()].points.append(point)
                }
            }
        }
        if let processID {
            var seen=Set<String>(),runs=[0,0],previousEnd:Date?
            for frame in frames.sorted(by:{$0.time<$1.time}) {
                guard let capture=frame.processNetwork,capture.isFresh(at:frame.time) else {runs[0]+=1;runs[1]+=1;continue}
                guard seen.insert(capture.id).inserted else {continue}
                let gap=gaps.contains {$0.start<capture.endedAt && ($0.end ?? .distantFuture)>capture.startedAt}
                guard !gap,let task=capture.tasks.first(where:{$0.id==processID}) else {runs[0]+=1;runs[1]+=1;continue}
                if let previousEnd,capture.startedAt>previousEnd.addingTimeInterval(0.05) {runs[0]+=1;runs[1]+=1}
                previousEnd=capture.endedAt
                let values=[task.downloadRate(elapsed:capture.elapsed),task.uploadRate(elapsed:capture.elapsed)]
                let session=capture.id.lastIndex(of:":").map {String(capture.id[..<$0])} ?? capture.id
                for lane in 0...1 {
                    guard let value=values[lane],value.isFinite else {runs[lane]+=1;continue}
                    let channel=lane==0 ? "read" : "write"
                    result["Network",default:ExplorerTraceData()].points.append(ExplorerPoint(time:capture.endedAt,value:value/1_000_000,series:"\(frame.segment ?? "legacy")-\(session)-\(runs[lane])-\(channel)",channel:channel))
                }
            }
        }
        for metric in metrics {
            if metric=="CPU" && processID==nil {result[metric]?.domain=0...100}
            else if metric=="Memory" && processID==nil {result[metric]?.domain=0...Double(ProcessInfo.processInfo.physicalMemory)/1048576}
            else {let maximum=result[metric]?.points.map(\.value).max() ?? 1;result[metric]?.domain=0...max(1,maximum*1.08)}
        }
        return result
    }
}

struct ExplorerSnapshotData {
    var impactScores:[String:Double]=[:]
    var depths:[String:Int]=[:]
    var processes:[ProcessRow]=[]
    var networkTasks:[String:ProcessNetworkTask]=[:]
    var networkElapsed:Double?
    var networkGroups:[ProcessNetworkGroup]=[]
    var networkGroupIDs:[String:String]=[:]
}
final class ExplorerSnapshotCache {
    private var time:Date?
    private var captureID:String?
    private var networkCaptureID:String?
    private var includesDepths=false
    private var value=ExplorerSnapshotData()
    func clear() {time=nil;captureID=nil;networkCaptureID=nil;includesDepths=false;value=ExplorerSnapshotData()}
    func data(frame:Frame?,includeDepths:Bool=false)->ExplorerSnapshotData {
        guard let frame else {clear();return value}
        guard frame.time != time || frame.energyImpact?.id != captureID || frame.processNetwork?.id != networkCaptureID || includeDepths != includesDepths else {return value}
        time=frame.time;captureID=frame.energyImpact?.id;networkCaptureID=frame.processNetwork?.id;includesDepths=includeDepths
        var result=ExplorerSnapshotData()
        result.processes=frame.processes
        if let sample=frame.processNetwork,sample.isFresh(at:frame.time) {
            result.networkTasks=Dictionary(sample.tasks.map {($0.id,$0)},uniquingKeysWith:{$1})
            result.networkElapsed=sample.elapsed
            let known=Set(frame.processes.map(\.id))
            result.processes += result.networkTasks.values.filter {!known.contains($0.id)}.sorted {$0.id<$1.id}.map(HistoryAnalysis.networkIdentity)
            result.networkGroups=HistoryAnalysis.networkGroups([frame],range:DateInterval(start:sample.startedAt,end:sample.endedAt),gaps:[])
            for group in result.networkGroups {for id in group.members.keys {result.networkGroupIDs[id]=group.id}}
        }
        let parents=includeDepths ? Dictionary(result.processes.map {($0.pid,$0)},uniquingKeysWith:{$1}) : [:]
        if frame.energyImpact == nil && !includeDepths {value=result;return value}
        for process in result.processes {
            if let score=explorerImpact(process,frame:frame) {result.impactScores[process.id]=score}
            if includeDepths {
                var pid=process.parent,seen=Set<Int32>(),depth=0
                while let parent=parents[pid],seen.insert(pid).inserted,depth<8 {depth+=1;pid=parent.parent}
                result.depths[process.id]=depth
            }
        }
        value=result;return value
    }
}

struct ExplorerTrace:View {
    let frames:[Frame]
    let range:DateInterval
    let cursor:Date?
    let processID:String?
    let metric:String
    let gaps:[RecordingGap]
    var showXAxis=false
    var traceCache:ExplorerTraceCache?=nil
    @StateObject private var localCache=ExplorerTraceCache()
    private var color:Color {metric=="Memory" ? ExplorerPalette.memory : metric=="Disk" ? ExplorerPalette.disk : metric=="Energy" ? ExplorerPalette.energy : metric=="Network" ? ExplorerPalette.network : ExplorerPalette.cpu}
    var body:some View {
        let data=(traceCache ?? localCache).data(frames:frames,gaps:gaps,processID:processID,metric:metric)
        VStack(spacing:3) {
            ExplorerPlotCanvas {context,size in
                let duration=max(0.001,range.duration),height=max(0.001,data.domain.upperBound-data.domain.lowerBound)
                func position(_ point:ExplorerPoint)->CGPoint {
                    CGPoint(x:point.time.timeIntervalSince(range.start)/duration*size.width,y:size.height-(point.value-data.domain.lowerBound)/height*size.height)
                }
                // Draw each recorded segment independently so gaps stay visibly empty.
                for gap in gaps where gap.start<range.end && (gap.end ?? range.end)>range.start {
                    let lower=max(range.start,gap.start),upper=min(range.end,gap.end ?? range.end)
                    let x=lower.timeIntervalSince(range.start)/duration*size.width
                    context.fill(Path(CGRect(x:x,y:0,width:upper.timeIntervalSince(lower)/duration*size.width,height:size.height)),with:.color(.orange.opacity(0.08)))
                }
                for points in Dictionary(grouping:data.points,by:\.series).values {
                    guard let first=points.first,let last=points.last else {continue}
                    var line=Path();line.move(to:position(first))
                    for point in points.dropFirst() {line.addLine(to:position(point))}
                    if metric=="CPU" && processID==nil {
                        var area=line
                        area.addLine(to:CGPoint(x:position(last).x,y:size.height));area.addLine(to:CGPoint(x:position(first).x,y:size.height));area.closeSubpath()
                        context.fill(area,with:.color(color.opacity(0.07)))
                    }
                    context.stroke(line,with:.color(first.channel=="write" ? ExplorerPalette.energy : color),style:StrokeStyle(lineWidth:1.5,dash:metric=="Network" && first.channel=="write" ? [3,2] : []))
                }
                if let cursor,range.start<=cursor,cursor<=range.end {
                    let x=cursor.timeIntervalSince(range.start)/duration*size.width
                    var line=Path();line.move(to:CGPoint(x:x,y:0));line.addLine(to:CGPoint(x:x,y:size.height))
                    context.stroke(line,with:.color(ExplorerPalette.background.opacity(0.9)),lineWidth:4)
                    context.stroke(line,with:.color(ExplorerPalette.cursor),lineWidth:2)
                }
            }.clipped()
            if showXAxis {
                GeometryReader {geometry in
                    ForEach(0..<5,id:\.self) {index in
                        let date=range.start.addingTimeInterval(range.duration*Double(index)/4)
                        Text(date.formatted(.dateTime.hour().minute().second()))
                            .font(.system(size:9)).foregroundStyle(.secondary)
                            .frame(width:90,alignment:index==0 ? .leading : index==4 ? .trailing : .center)
                            .position(x:index==0 ? 45 : index==4 ? geometry.size.width-45 : geometry.size.width*Double(index)/4,y:6)
                    }
                }.frame(height:13)
            }
        }.accessibilityElement(children:.ignore)
            .accessibilityLabel("\(metric) history")
            .accessibilityValue("\(data.points.count) recorded values, \(range.start.formatted(date:.omitted,time:.standard)) to \(range.end.formatted(date:.omitted,time:.standard))")
    }
}

enum ExplorerTimelinePosition {
    static func time(atX x:Double,width:Double,range:DateInterval)->Date? {
        guard x.isFinite,width.isFinite,width>0,range.duration.isFinite,range.duration>0 else {return nil}
        return range.start.addingTimeInterval(min(1,max(0,x/width))*range.duration)
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
    static let cursor=adaptive((0.94,0.97,1),(0.12,0.18,0.25))
    static let cpu=adaptive((0.59,0.84,0.75),(0.14,0.45,0.35))
    static let memory=adaptive((0.73,0.67,0.86),(0.43,0.32,0.63))
    static let disk=adaptive((0.60,0.74,0.91),(0.18,0.39,0.67))
    static let energy=adaptive((0.90,0.73,0.46),(0.57,0.36,0.10))
    static let network=adaptive((0.40,0.79,0.96),(0.07,0.48,0.68))
}

private struct ExplorerNetworkApplicationInspector:View {
    let group:ProcessNetworkGroup?
    let summaryMode:Bool
    let range:DateInterval
    let onInspect:(ProcessRow,ProcessNetworkGroup)->Void
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("NETWORK APPLICATION INSPECTOR").font(.system(size:9,weight:.semibold)).tracking(1).foregroundStyle(.secondary)
                if let group {
                    Text(group.name).font(.system(size:20,weight:.semibold)).lineLimit(2)
                    Text(group.id.hasPrefix("app:") ? "Application · observed helper processes" : "Unassigned process").font(.system(size:10)).foregroundStyle(.secondary)
                    Divider()
                    valueRow(summaryMode ? "Average download" : "Download",explorerNetworkRateText(group.totals.averageDownloadRate),color:ExplorerPalette.network)
                    valueRow(summaryMode ? "Average upload" : "Upload",explorerNetworkRateText(group.totals.averageUploadRate),color:ExplorerPalette.energy)
                    valueRow(summaryMode ? "Received in range" : "Received in capture",group.totals.receivedBytes.map(bytes) ?? "—")
                    valueRow(summaryMode ? "Sent in range" : "Sent in capture",group.totals.sentBytes.map(bytes) ?? "—")
                    if summaryMode {
                        valueRow("Peak download",explorerNetworkRateText(group.totals.peakDownloadRate))
                        valueRow("Peak upload",explorerNetworkRateText(group.totals.peakUploadRate))
                        Text(String(format:"Receive / send coverage %.1f / %.1f seconds of %.1f",group.totals.receiveCoveredSeconds,group.totals.sendCoveredSeconds,range.duration)).font(.system(size:9)).foregroundStyle(.secondary)
                    } else {
                        Text(String(format:"Capture interval %.1f seconds",max(group.totals.receiveCoveredSeconds,group.totals.sendCoveredSeconds))).font(.system(size:9)).foregroundStyle(.secondary)
                    }
                    if group.isPartial {Text("Some observed members have unavailable traffic counters.").font(.system(size:10)).foregroundStyle(.orange)}
                    if group.hasUnattributedProcesses {Text("Some source rows could not be matched to process identities.").font(.system(size:10)).foregroundStyle(.secondary)}
                    Divider()
                    Text("OBSERVED PROCESSES").font(.system(size:9,weight:.semibold)).tracking(1).foregroundStyle(.secondary)
                    ForEach(Array(group.members.values.sorted {$0.name==$1.name ? $0.id<$1.id : $0.name<$1.name}.prefix(20))) {process in
                        Button {onInspect(process,group)} label: {
                            HStack {Text(process.name).lineLimit(1);Spacer();Text(String(process.pid)).monospacedDigit().foregroundStyle(.secondary);Image(systemName:"chevron.right").font(.system(size:8))}
                        }.buttonStyle(.plain).font(.system(size:10)).accessibilityLabel("Inspect \(process.name), PID \(process.pid)")
                    }
                    if group.members.count>20,let process=group.members.values.first {Button("Show all \(group.members.count) observed processes") {onInspect(process,group)}.controlSize(.small)}
                    Text("External TCP/UDP traffic and observed app ownership. This is not a physical-interface total or an exact macOS coalition.").font(.system(size:9)).foregroundStyle(.secondary)
                } else {
                    Text("Select an application").font(.system(size:18,weight:.medium))
                    Text("Inspect its network rates, recorded transfer totals, coverage, and observed helper processes.").font(.system(size:11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(18)
        }.background(ExplorerPalette.inspector)
    }
    private func valueRow(_ title:String,_ value:String,color:Color = .primary)->some View {
        HStack(alignment:.firstTextBaseline,spacing:8) {Text(title).foregroundStyle(.secondary);Spacer(minLength:4);Text(value).monospacedDigit().foregroundStyle(color).multilineTextAlignment(.trailing)}.font(.system(size:10))
    }
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


// Scores are relative, not energy in joules. Never integrate a cached capture again
// just because the main collector attached it to another process snapshot.
struct ExplorerImpactSummary {
    var weightedScore=0.0
    var coveredSeconds=0.0
    var peak=0.0
    var captures=0
    var average:Double? {coveredSeconds>0 ? weightedScore/coveredSeconds : nil}
    static func summarize(_ frames:[Frame],range:DateInterval,gaps:[RecordingGap])->[String:Self] {
        var result:[String:Self]=[:],seen=Set<String>()
        for frame in frames.sorted(by:{$0.time<$1.time}) {
            guard let sample=frame.energyImpact,!seen.contains(sample.id) else {continue}
            let lower=max(range.start,sample.startedAt),upper=min(range.end,sample.endedAt)
            guard upper>lower,!gaps.contains(where:{$0.start<upper && ($0.end ?? .distantFuture)>lower}) else {continue}
            // A capture is only accepted through a fresh frame with a matching process lifetime.
            let values=frame.processes.compactMap {process -> (String,Double)? in
                guard let value=explorerImpact(process,frame:frame) else {return nil}
                return (process.id,value)
            }
            guard !values.isEmpty else {continue}
            seen.insert(sample.id)
            let seconds=upper.timeIntervalSince(lower)
            for (id,value) in values {
                var entry=result[id] ?? Self()
                entry.weightedScore+=value*seconds;entry.coveredSeconds+=seconds
                entry.peak=max(entry.peak,value);entry.captures+=1;result[id]=entry
            }
        }
        return result
    }
}
private func explorerImpact(_ process:ProcessRow,frame:Frame?)->Double? {
    guard let frame,process.start>0 else {return nil}
    let start=Date(timeIntervalSince1970:Double(process.start)/1_000_000)
    guard let value=frame.energyImpact?.task(forPID:process.pid,processStart:start,at:frame.time,maximumAge:15)?.energyImpactPerSecond,value.isFinite,value>=0 else {return nil}
    return value
}
private func explorerImpactText(_ score:Double?)->String {score.map {String(format:"%.1f",$0)} ?? "—"}
