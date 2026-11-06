import SwiftUI
import Charts

// The dashboard reads the same recorded samples as Process Explorer.
struct PopupDashboard:View {
    let frame:Frame
    let frames:[Frame]
    @ObservedObject var layout:PopupLayoutSettings
    var tileSide:CGFloat=160
    var editingLayout:Bool=false
    @State private var targeted:PopupItemID?
    @State private var insertionTargeted:Int?
    static let spacing:CGFloat=12
    private var physical:Double {Double(ProcessInfo.processInfo.physicalMemory)}
    private var fullWidth:CGFloat {layout.contentWidth(tileSide:tileSide,spacing:Self.spacing)}
    private var networkCeiling:Double {max(1,frames.map {max($0.download,$0.upload)}.max() ?? 1)}

    var body:some View {
        VStack(alignment:.leading,spacing:Self.spacing) {
            if layout.rows.isEmpty {
                if editingLayout {insertionTarget(index:0,width:fullWidth,height:tileSide,title:"Drop a tile here")}
                else {Text("No popup tiles enabled. Choose tiles in Preferences → Popup layout.").font(.system(size:12)).foregroundStyle(.secondary).frame(width:fullWidth,alignment:.leading).padding(.vertical,24)}
            }
            ForEach(layout.rows) {row in
                HStack(alignment:.top,spacing:Self.spacing) {
                    ForEach(row.entries) {entry in
                        tileCell(entry)
                    }
                    if row.entries.count<layout.columnCount && row.entries.allSatisfy({$0.span == .square}) {
                        if editingLayout,let last=row.entries.last,let index=layout.visibleEntries.firstIndex(where:{$0.id==last.id}) {
                            insertionTarget(index:index+1,width:tileSide,height:tileSide,title:"Drop tile")
                        }
                        Spacer(minLength:0)
                    }
                }.frame(width:fullWidth,alignment:.leading)
            }
            if editingLayout && !layout.rows.isEmpty {insertionTarget(index:layout.visibleEntries.count,width:fullWidth,height:50,title:"Drop here to add at the end")}
        }.frame(width:fullWidth,alignment:.leading)
    }
    @ViewBuilder private func tileCell(_ entry:PopupLayoutEntry)->some View {
        if editingLayout {
            tileContent(entry)
                .overlay(alignment:.topTrailing) {Image(systemName:"line.3.horizontal").font(.system(size:8)).foregroundStyle(.tertiary).padding(8)}
                .draggable(entry.id.rawValue)
                .dropDestination(for:String.self) {items,_ in
                    guard let raw=items.first,let id=PopupItemID(rawValue:raw),id != entry.id else {return false}
                    layout.place(id,atPositionOf:entry.id);return true
                } isTargeted:{targeted=$0 ? entry.id : nil}
                .contextMenu {
                    Button("Square tile") {layout.setSpan(.square,for:entry.id)}.disabled(entry.span == .square)
                    Button("Full-width tile") {layout.setSpan(.fullWidth,for:entry.id)}.disabled(entry.span == .fullWidth)
                    Divider()
                    Button("Move earlier") {layout.moveVisible(entry.id,by:-1)}
                    Button("Move later") {layout.moveVisible(entry.id,by:1)}
                    Divider()
                    Button("Remove tile",role:.destructive) {layout.setVisible(false,for:entry.id)}
                }
                .focusable()
                .onMoveCommand {direction in
                    switch direction {case .left,.up:layout.moveVisible(entry.id,by:-1);case .right,.down:layout.moveVisible(entry.id,by:1);default:break}
                }
                .onDeleteCommand {layout.setVisible(false,for:entry.id)}
                .accessibilityAction(named:Text("Remove tile")) {layout.setVisible(false,for:entry.id)}
                .accessibilityAction(named:Text("Move earlier")) {layout.moveVisible(entry.id,by:-1)}
                .accessibilityAction(named:Text("Move later")) {layout.moveVisible(entry.id,by:1)}
        } else {tileContent(entry)}
    }
    private func insertionTarget(index:Int,width:CGFloat,height:CGFloat,title:String)->some View {
        Image(systemName:"plus").font(.system(size:13,weight:.light)).foregroundStyle(.tertiary)
            .frame(width:width,height:height)
            .background(insertionTargeted == index ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.015),in:RoundedRectangle(cornerRadius:12))
            .overlay {RoundedRectangle(cornerRadius:12).strokeBorder(insertionTargeted == index ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.14),style:StrokeStyle(lineWidth:1,dash:[4,4]))}
            .contentShape(RoundedRectangle(cornerRadius:12))
            .dropDestination(for:String.self) {items,_ in
                guard let raw=items.first,let id=PopupItemID(rawValue:raw) else {return false}
                layout.place(id,atVisibleIndex:index);return true
            } isTargeted:{insertionTargeted=$0 ? index : nil}
            .help(title)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier("popup.layout.insert.\(index)")
    }
    private func tileContent(_ entry:PopupLayoutEntry)->some View {
        tile(entry.id).padding(12)
            .frame(width:entry.span == .fullWidth ? fullWidth : tileSide,height:tileSide,alignment:.topLeading)
            .background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:13))
            .overlay {RoundedRectangle(cornerRadius:13).strokeBorder(targeted == entry.id ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.055),lineWidth:targeted == entry.id ? 1.5 : 0.5)}
            .contentShape(RoundedRectangle(cornerRadius:13))
            .accessibilityIdentifier("popup.tile.\(entry.id.rawValue)")
    }
    @ViewBuilder private func tile(_ id:PopupItemID)->some View {
        switch id {
        case .cpu:
            metricTile(title:"CPU",text:String(format:"%.0f",frame.cpu),unit:"%",caption:"Machine capacity",color:.mint,ceiling:100,value:{$0.cpu})
        case .memory:
            metricTile(title:"MEMORY",text:String(format:"%.0f",Double(frame.memory)/physical*100),unit:"%",caption:"\(bytes(frame.memory)) used",color:.purple,ceiling:100,value:{Double($0.memory)/physical*100})
                .help("Used RAM excludes reclaimable cache. This percentage is not memory pressure.")
        case .download:
            metricTile(title:"↓ DOWNLOAD",text:compactNetworkRate(frame.download),unit:"/s",caption:"Shared network scale",color:.cyan,ceiling:networkCeiling,value:{$0.download})
        case .upload:
            metricTile(title:"↑ UPLOAD",text:compactNetworkRate(frame.upload),unit:"/s",caption:"Shared network scale",color:.orange,ceiling:networkCeiling,value:{$0.upload})
        case .batteryFlow:
            metricTile(title:"BATTERY FLOW",text:batteryText,unit:"W",caption:batteryCaption,color:.yellow,ceiling:nil,value:{frame in guard let power=frame.power,power.hasUsableCurrent else {return nil};return abs(power.watts)})
                .help("Estimated battery electrical flow. This is not total system power on AC. Charging and discharging history remain separate.")
        case .cpuProcesses: processTile(energy:false)
        case .processCPUPower: processTile(energy:true)
        case .applicationCPUPower: applicationPowerTile
        case .diskRead: diskTile(read:true)
        case .diskWrite: diskTile(read:false)
        case .memoryDetail:
            VStack(alignment:.leading,spacing:6) {
                heading("MEMORY DETAILS",color:.purple)
                HStack {Text("Compressed");Spacer(minLength:0);Text(bytes(frame.compressed)).monospacedDigit()}.font(.system(size:11))
                PopupSpark(frames:frames,color:.purple,ceiling:nil,value:{Double($0.compressed)}).frame(maxHeight:.infinity)
                HStack {Text("Swap");Spacer(minLength:0);Text(bytes(frame.swap)).monospacedDigit()}.font(.system(size:11))
                Text("Compression ≠ pressure").font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    private var batteryText:String {
        guard let power=frame.power,power.hasUsableCurrent else {return "—"}
        return String(format:"%.1f",abs(power.watts))
    }
    private var batteryCaption:String {
        guard let power=frame.power,power.hasUsableCurrent else {return "Sensor unavailable"}
        if power.watts < -0.05 {return "Discharging · estimate"}
        if power.watts > 0.05 {return "Charging · estimate"}
        return "External power · estimate"
    }
    private func metricTile(title:String,text:String,unit:String,caption:String,color:Color,ceiling:Double?,value:@escaping(Frame)->Double?)->some View {
        VStack(alignment:.leading,spacing:6) {
            heading(title,color:color)
            HStack(alignment:.firstTextBaseline,spacing:2) {
                Text(text).font(.system(size:28,weight:.medium,design:.rounded)).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
                Text(unit).font(.system(size:12)).foregroundStyle(.secondary)
            }
            PopupSpark(frames:frames,color:color,ceiling:ceiling,value:value).frame(maxHeight:.infinity)
            Text(caption).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
    private func diskTile(read:Bool)->some View {
        let rate=popupDiskRate(frame,read:read)
        return metricTile(title:read ? "PROCESS READS" : "PROCESS WRITES",text:rate.map(compactNetworkRate) ?? "—",unit:"/s",caption:"Observed process I/O",color:read ? .blue : .indigo,ceiling:nil,value:{popupDiskRate($0,read:read)})
            .help("Sum of available process counter deltas divided by the actual sample interval. This is not a complete disk-device total; inaccessible processes are omitted.")
    }
    private func processTile(energy:Bool)->some View {
        let values=frame.processes.compactMap {process->(ProcessRow,Double)? in
            let value=energy ? process.cpuPowerWatts(elapsed:frame.elapsed) : process.cpu
            guard let value,value.isFinite,value>=0 else {return nil};return (process,value)
        }.sorted {$0.1>$1.1}.prefix(3)
        return VStack(alignment:.leading,spacing:9) {
            heading(energy ? "PROCESS CPU POWER" : "CPU PROCESSES",color:energy ? .pink : .mint)
            if values.isEmpty {
                Spacer(minLength:0)
                Text("Unavailable").font(.system(size:16,weight:.medium)).foregroundStyle(.secondary)
                Text(energy ? "Process energy not available" : "Waiting for CPU deltas").font(.system(size:9)).foregroundStyle(.tertiary)
                Spacer(minLength:0)
            } else {
                ForEach(Array(values),id:\.0.id) {process,value in
                    VStack(alignment:.leading,spacing:4) {
                        HStack(spacing:6) {
                            Text(process.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength:0)
                            Text(energy ? String(format:"%.2f W",value) : String(format:"%.0f%%",value)).monospacedDigit().layoutPriority(1)
                        }.font(.system(size:10,weight:.medium))
                        GeometryReader {geometry in
                            Capsule().fill(.primary.opacity(0.06))
                            Capsule().fill((energy ? Color.pink : .mint).opacity(0.65)).frame(width:geometry.size.width*min(1,max(0,value/max(values.first?.1 ?? 1,0.001))))
                        }.frame(height:3)
                    }
                }
                Spacer(minLength:0)
            }
            Text(energy ? "Estimated CPU power" : "CPU · 100% = one core").font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
        }.help(energy ? "Estimated CPU power from each process’s recorded CPU energy delta and the actual elapsed interval. This is not Apple’s Energy Impact score, GPU power, or whole-device power." : "Process CPU percentages use 100% for one logical CPU.")
    }
    private var applicationPowerTile:some View {
        let groups=AppPowerGrouping.snapshot(frame)
        let shown=Array(groups.prefix(3))
        let measured=groups.reduce(0) {$0+$1.measuredEnergyProcesses}
        let observed=groups.reduce(0) {$0+$1.observedProcesses}
        let ceiling=max(0.001,shown.compactMap {usableAppPower($0)}.max() ?? 0)
        return VStack(alignment:.leading,spacing:9) {
            heading("APPS CPU POWER",color:.pink)
            if shown.isEmpty {
                Spacer(minLength:0)
                Text("Unavailable").font(.system(size:16,weight:.medium)).foregroundStyle(.secondary)
                Spacer(minLength:0)
            } else {
                ForEach(shown) {group in
                    VStack(alignment:.leading,spacing:4) {
                        HStack(spacing:5) {
                            Text(group.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength:0)
                            if group.isPartial || group.hasUnattributedProcesses {
                                Circle().fill(Color.orange.opacity(0.85)).frame(width:4,height:4).accessibilityLabel("Partial coverage")
                            }
                            Text(usableAppPower(group).map {String(format:"%.2f W",$0)} ?? "—").monospacedDigit().layoutPriority(1)
                        }.font(.system(size:10,weight:.medium))
                        GeometryReader {geometry in
                            Capsule().fill(.primary.opacity(0.06))
                            if let watts=usableAppPower(group) {Capsule().fill(Color.pink.opacity(0.65)).frame(width:geometry.size.width*min(1,watts/ceiling))}
                        }.frame(height:3)
                    }.help(applicationPowerHelp(group))
                }
                Spacer(minLength:0)
            }
            Text("Estimated · \(measured)/\(observed) measured").font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
                .help("CPU energy available for \(measured) of \(observed) observed processes. \(frame.denied<0 ? "Process query coverage unavailable." : "\(frame.denied) process queries denied.") Totals include only measured, observed helpers; missing energy is not zero.")
        }.help("Estimated CPU power grouped by application and its observed helpers. Orange dots indicate partial energy coverage or denied process queries. Tools without an identified application remain separate. This is not Apple’s Energy Impact score, GPU power, or whole-device power.")
    }
    private func usableAppPower(_ group:AppPowerGroup)->Double? {
        guard let watts=group.cpuPowerWatts,watts.isFinite,watts>=0 else {return nil}
        return watts
    }
    private func applicationPowerHelp(_ group:AppPowerGroup)->String {
        let ownership=group.id.hasPrefix("app:") ? "Application with observed helpers." : "No identified application; this process is shown separately."
        let denied=group.hasUnattributedProcesses ? " Some process queries were denied, so additional helpers may be absent." : ""
        return "\(group.name): CPU energy measured for \(group.measuredEnergyProcesses)/\(group.observedProcesses) observed processes. \(ownership)\(denied) Missing energy is unavailable, not zero."
    }
    private func heading(_ title:String,color:Color)->some View {
        HStack(spacing:5) {Circle().fill(color).frame(width:4,height:4);Text(title).font(.system(size:8,weight:.semibold)).tracking(0.8).lineLimit(1)}.foregroundStyle(.secondary)
    }
}

func popupDiskRate(_ frame:Frame,read:Bool)->Double? {
    guard let elapsed=frame.elapsed,elapsed.isFinite,elapsed>0 else {return nil}
    let deltas=frame.processes.compactMap {read ? $0.read : $0.written}
    guard !deltas.isEmpty else {return nil}
    return deltas.reduce(0.0) {$0+Double($1)}/elapsed
}

private struct PopupSpark:View {
    let frames:[Frame]
    let color:Color
    let ceiling:Double?
    let value:(Frame)->Double?
    private struct Point:Identifiable {let id:Date;let value:Double;let segment:String}
    private var points:[Point] {
        var run=0
        return frames.compactMap {frame in
            guard let value=value(frame),value.isFinite else {run+=1;return nil}
            return Point(id:frame.time,value:value,segment:(frame.segment ?? "legacy")+"-\(run)"+((frame.power?.externalPower == true) ? "-ac" : "-battery"))
        }
    }
    private var range:ClosedRange<Double> {
        let values=points.map(\.value)
        let low=min(0,values.min() ?? 0)
        let high=ceiling ?? max(1,values.max() ?? 1)
        return low...max(low+1,high)
    }
    var body:some View {
        Chart(points) {point in
            AreaMark(x:.value("Time",point.id),yStart:.value("Baseline",0),yEnd:.value("Value",point.value),series:.value("Segment",point.segment))
                .foregroundStyle(LinearGradient(colors:[color.opacity(0.27),color.opacity(0.025)],startPoint:.top,endPoint:.bottom))
            LineMark(x:.value("Time",point.id),y:.value("Value",point.value),series:.value("Segment",point.segment))
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth:1.6,lineCap:.round,lineJoin:.round))
        }.chartYScale(domain:range).chartXAxis(.hidden).chartYAxis(.hidden)
            .overlay(alignment:.bottom) {Rectangle().fill(.primary.opacity(0.08)).frame(height:0.5)}
            .accessibilityLabel("Recent metric history; discontinuities indicate missing samples")
    }
}
