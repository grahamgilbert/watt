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
}

struct ProcessExplorerView:View {
    @ObservedObject var monitor:Monitor
    @ObservedObject private var controls=ProcessExplorerControls()
    private var range:DateInterval {
        monitor.historyRange ?? DateInterval(start:(monitor.liveFrame?.time ?? monitor.frames.last?.time ?? Date()).addingTimeInterval(-controls.duration),duration:controls.duration)
    }
    private var displayFrames:[Frame] {monitor.visibleFrames.filter {$0.time>=range.start && $0.time<=range.end}}
    private var summaryMode:Bool {controls.mode=="Interval summary" && monitor.historyRange != nil}
    private var processes:[ProcessRow] {
        let all=(monitor.current?.processes ?? []).filter {controls.search.isEmpty || $0.name.localizedCaseInsensitiveContains(controls.search) || String($0.pid).contains(controls.search)}
        let sorted=all.sorted {
            switch controls.sort {
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
        monitor.historySummaries.filter {controls.search.isEmpty || $0.process.name.localizedCaseInsensitiveContains(controls.search) || String($0.process.pid).contains(controls.search)}.sorted {
            switch controls.sort {
            case "Memory":return $0.peakMemory>$1.peakMemory
            case "Disk read":return $0.readBytes>$1.readBytes
            case "Disk write":return $0.writtenBytes>$1.writtenBytes
            default:return $0.cpuSeconds>$1.cpuSeconds
            }
        }
    }
    private func depth(_ row:ProcessRow)->Int {
        guard controls.tree else {return 0}
        let map=Dictionary((monitor.current?.processes ?? []).map {($0.pid,$0)},uniquingKeysWith:{$1})
        var pid=row.parent,seen=Set<Int32>(),count=0
        while let parent=map[pid],seen.insert(pid).inserted,count<8 {count+=1;pid=parent.parent}
        return count
    }
    private func load() {monitor.loadHistory(center:controls.center,duration:controls.duration);controls.mode="Interval summary"}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text("Process Explorer").font(.title2.weight(.semibold))
                    if let bounds=monitor.historyBounds {Text("Retained: \(bounds.start.formatted()) – \(bounds.end.formatted())").font(.caption).foregroundStyle(.secondary)}
                }
                Spacer()
                Text(monitor.historyRange==nil && monitor.selected==nil ? "LIVE" : "HISTORY").font(.caption.monospaced()).foregroundStyle(.mint)
                if monitor.historyLoading {ProgressView().controlSize(.small)}
                Button("Live") {monitor.returnToLive();controls.mode="At cursor"}.disabled(monitor.historyRange==nil && monitor.selected==nil)
                Button(monitor.paused ? "Resume recording" : "Pause recording") {monitor.setPaused(!monitor.paused)}
            }
            HStack {
                DatePicker("Go to",selection:$controls.center,displayedComponents:[.date,.hourAndMinute]).labelsHidden().accessibilityLabel("History date and time")
                Picker("Window",selection:$controls.duration) {Text("5 minutes").tag(300.0);Text("15 minutes").tag(900.0);Text("1 hour").tag(3600.0);Text("2 hours").tag(7200.0)}.frame(width:180)
                Button("Inspect interval",action:load).disabled(monitor.historyLoading)
                Button("Earlier") {controls.center=controls.center.addingTimeInterval(-controls.duration);load()}.disabled(monitor.historyLoading)
                Button("Later") {controls.center=controls.center.addingTimeInterval(controls.duration);load()}.disabled(monitor.historyLoading)
                Spacer()
                Text("Local time · \(TimeZone.current.abbreviation() ?? "")").font(.caption).foregroundStyle(.secondary)
            }
            if let error=monitor.historyError ?? monitor.error {Text(error).foregroundStyle(.orange).textSelection(.enabled)}
            Text("\(range.start.formatted(date:.abbreviated,time:.standard)) – \(range.end.formatted(date:.abbreviated,time:.standard))").font(.callout.monospacedDigit())
            HistoryTrace(frames:displayFrames,range:range,cursor:monitor.selected,processID:nil,metric:"CPU",gaps:monitor.visibleGaps)
                .frame(height:85)
                .chartOverlay {proxy in
                    GeometryReader {geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged {event in
                            guard let plot=proxy.plotFrame else {return}
                            if let date:Date=proxy.value(atX:event.location.x-geometry[plot].origin.x),range.contains(date) {monitor.selected=date;controls.mode="At cursor"}
                        })
                    }
                }
            HStack {
                Text("Cursor").font(.caption)
                Slider(value:Binding(get:{min(range.end.timeIntervalSince1970,max(range.start.timeIntervalSince1970,(monitor.selected ?? monitor.liveFrame?.time ?? range.end).timeIntervalSince1970))},set:{monitor.selected=Date(timeIntervalSince1970:$0);controls.mode="At cursor"}),in:range.start.timeIntervalSince1970...max(range.start.timeIntervalSince1970+1,range.end.timeIntervalSince1970))
                Text((monitor.selected ?? monitor.liveFrame?.time ?? range.end).formatted(date:.omitted,time:.standard)).monospacedDigit().frame(width:105)
            }
            if let snapshot=monitor.current {
                HStack(spacing:22) {
                    Text("CPU \(String(format:"%.1f",snapshot.cpu))%").foregroundStyle(.mint)
                    Text("Memory \(bytes(snapshot.memory))\(snapshot.memoryAccounting == nil ? " · legacy estimate" : "")").foregroundStyle(.purple)
                    Text("↓ \(bytes(UInt64(snapshot.download)))/s  ↑ \(bytes(UInt64(snapshot.upload)))/s").foregroundStyle(.blue)
                    Text(snapshot.power?.formatted ?? "Power unavailable").foregroundStyle(.orange)
                    Spacer()
                    Text("Sample \(snapshot.time.formatted(date:.omitted,time:.standard))").foregroundStyle(.secondary)
                }.font(.callout.monospacedDigit())
            } else {Text(monitor.selectionGap().map {"No recorded state: \($0.reason)"} ?? "No nearby recorded sample. Missing data is not zero activity.").font(.caption).foregroundStyle(.orange)}
            HStack {
                TextField("Filter process or PID",text:$controls.search).textFieldStyle(.roundedBorder).frame(maxWidth:270)
                Picker("View",selection:$controls.mode) {Text("At cursor").tag("At cursor");Text("Interval summary").tag("Interval summary")}.frame(width:230).disabled(monitor.historyRange==nil)
                Picker("Rank by",selection:$controls.sort) {ForEach(["CPU","Memory","Disk read","Disk write"],id:\.self){Text($0).tag($0)}}.frame(width:180)
                Toggle("Parent tree",isOn:$controls.tree).toggleStyle(.checkbox).disabled(summaryMode)
                Spacer()
                Text(summaryMode ? "\(monitor.historyFrames.count) samples · \(summaries.count) process instances" : "\(monitor.current?.processes.count ?? 0) observed · \(max(0,monitor.current?.denied ?? 0)) unavailable").font(.caption).foregroundStyle(.secondary)
            }
            if summaryMode {summaryTable} else {snapshotTable}
            if let selected=controls.selection {
                HStack {
                    Text(selectedName(selected)).font(.callout.weight(.semibold))
                    Spacer()
                    if summaryMode,let summary=monitor.historySummaries.first(where:{$0.id==selected}) {Text(String(format:"CPU coverage: %.1f / %.1f seconds · %d observations",summary.cpuCoveredSeconds,range.duration,summary.samples)).font(.caption).foregroundStyle(.secondary)}
                }
                HStack(spacing:20) {trace(selected,"CPU");trace(selected,"Memory");trace(selected,"Disk")}.frame(height:120)
            } else {Text("Select a process for its CPU, memory and disk history.").foregroundStyle(.secondary)}
            Text(summaryMode ? "CPU 100% = one core. Totals/averages use complete covered intervals; peaks are sampled. Legacy samples without elapsed metadata cannot supply totals. Footprints are not additive." : "CPU 100% = one core. Disk rates use measured intervals. Parent links are observed relationships; polling can miss short-lived processes. Footprints are not additive.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth:1180,minHeight:740)
        .onAppear {
            if let range=monitor.historyRange {controls.center=range.start.addingTimeInterval(range.duration/2);controls.duration=range.duration;controls.mode="Interval summary"}
            else {controls.center=(monitor.liveFrame?.time ?? monitor.historyBounds?.end ?? Date()).addingTimeInterval(-controls.duration/2)}
        }
    }
    private var snapshotTable:some View {
        Table(processes,selection:$controls.selection) {
            TableColumn("Process") {p in Text(p.name).padding(.leading,CGFloat(depth(p))*12)}.width(min:170,ideal:230)
            TableColumn("PID") {Text(String($0.pid))}.width(60)
            TableColumn("Parent") {Text(String($0.parent))}.width(60)
            TableColumn("CPU · core %") {Text($0.cpu.map {String(format:"%.1f%%",$0)} ?? "—")}.width(100)
            TableColumn("Footprint") {Text(bytes($0.memory))}.width(110)
            TableColumn("Δ footprint") {p in Text(p.growth.map {($0<0 ? "−" : "+")+bytes(UInt64(abs($0)))} ?? "—")}.width(110)
            TableColumn("Disk read/s") {Text(diskRate($0.read,elapsed:monitor.current?.elapsed))}.width(110)
            TableColumn("Disk write/s") {Text(diskRate($0.written,elapsed:monitor.current?.elapsed))}.width(110)
        }.monospacedDigit().frame(minHeight:160)
    }
    private var summaryTable:some View {
        Table(summaries,selection:$controls.selection) {
            TableColumn("Process") {Text($0.process.name)}.width(min:150,ideal:210)
            TableColumn("PID") {Text(String($0.process.pid))}.width(55)
            TableColumn("CPU avg") {Text($0.averageCPU.map {String(format:"%.1f%%",$0)} ?? "—")}.width(75)
            TableColumn("CPU peak") {Text($0.peakCPU.map {String(format:"%.1f%%",$0)} ?? "—")}.width(75)
            TableColumn("CPU time") {Text($0.cpuCoveredSeconds>0 ? String(format:"%.2f s",$0.cpuSeconds) : "—")}.width(85)
            TableColumn("Last footprint") {Text(bytes($0.lastMemory))}.width(100)
            TableColumn("Peak footprint") {Text(bytes($0.peakMemory))}.width(100)
            TableColumn("Δ footprint") {p in Text(p.memoryChange.map {($0<0 ? "−" : "+")+bytes(UInt64(abs($0)))} ?? "—")}.width(95)
            TableColumn("Disk read total") {Text($0.ioSamples>0 ? bytes($0.readBytes) : "—")}.width(100)
            TableColumn("Disk write total") {Text($0.ioSamples>0 ? bytes($0.writtenBytes) : "—")}.width(100)
        }.monospacedDigit().frame(minHeight:160)
    }
    private func selectedName(_ id:String)->String {
        let p=monitor.current?.processes.first(where:{$0.id==id}) ?? monitor.historySummaries.first(where:{$0.id==id})?.process
        return p.map {"\($0.name) · PID \($0.pid)"} ?? "Recorded process \(id)"
    }
    private func trace(_ id:String,_ metric:String)->some View {
        VStack(alignment:.leading) {
            Text(metric=="Disk" ? "Disk · blue read / amber write · MiB/s" : metric=="Memory" ? "Physical footprint · MiB" : "CPU · one-core %").font(.caption)
            HistoryTrace(frames:displayFrames,range:range,cursor:monitor.selected,processID:id,metric:metric,gaps:[])
        }
    }
}

struct HistoryTrace:View {
    var frames:[Frame]
    var range:DateInterval
    var cursor:Date?
    var processID:String?
    var metric:String
    var gaps:[RecordingGap]
    var body:some View {
        Chart {
            ForEach(frames) { f in
                if let processID {
                    if let p=f.processes.first(where:{$0.id==processID}) {
                        if metric=="CPU",let cpu=p.cpu {LineMark(x:.value("Time",f.time),y:.value("Core %",cpu),series:.value("Series",f.segment ?? "legacy")).foregroundStyle(.mint)}
                        else if metric=="Memory" {LineMark(x:.value("Time",f.time),y:.value("MiB",Double(p.memory)/1048576),series:.value("Series",f.segment ?? "legacy")).foregroundStyle(.purple)}
                        else if metric=="Disk",let duration=f.elapsed,duration>0 {
                            if let read=p.read {LineMark(x:.value("Time",f.time),y:.value("Read MiB/s",Double(read)/duration/1048576),series:.value("Series","read-"+(f.segment ?? "legacy"))).foregroundStyle(.blue)}
                            if let written=p.written {LineMark(x:.value("Time",f.time),y:.value("Write MiB/s",Double(written)/duration/1048576),series:.value("Series","write-"+(f.segment ?? "legacy"))).foregroundStyle(.orange)}
                        }
                    }
                } else {LineMark(x:.value("Time",f.time),y:.value("Machine CPU %",f.cpu),series:.value("Series",f.segment ?? "legacy")).foregroundStyle(.mint)}
            }
            if let cursor {RuleMark(x:.value("Cursor",cursor)).foregroundStyle(.secondary)}
            ForEach(gaps.filter {$0.start<range.end && ($0.end ?? Date())>range.start}) {gap in
                RectangleMark(xStart:.value("Gap",max(range.start,gap.start)),xEnd:.value("Gap end",min(range.end,gap.end ?? Date()))).foregroundStyle(.orange.opacity(0.12))
            }
        }.chartXScale(domain:range.start...range.end).chartLegend(.hidden)
    }
}
