import AppKit
import SwiftUI
import Charts

struct PopupDetailView:View {
    let frame:Frame?
    let frames:[Frame]
    let gaps:[RecordingGap]
    let item:PopupItemID
    @Binding var selectedTime:Date?
    @Binding var duration:Double
    let isLoading:Bool
    let error:String?
    let onBack:()->Void
    let onOpenExplorer:(PopupExplorerContext)->Void
    @State private var mode:String?
    @State private var scope:String?
    @State private var selectedRowID:String?
    @State private var expandedGroups=Set<String>()
    @State private var preparedData=PopupDetailData()
    @State private var preparedKey:RefreshKey?
    @State private var isPreparing=true

    private var destination:PopupDetailDestination {PopupDetailDestination(item:item)}
    private var activeMode:String {mode ?? destination.initialMode(item:item)}
    private var activeScope:String {scope ?? (item == .applicationCPUPower || destination == .network ? "Applications" : "Processes")}
    private var effectiveScope:String {destination == .energy && activeMode == "Energy Impact" ? "Processes" : activeScope}
    private var contentHeight:CGFloat {min(690,max(450,(NSScreen.main?.visibleFrame.height ?? 900)-130))}
    private var colors:[Color] {
        switch destination {
        case .cpu:return [.mint,.purple]
        case .memory:return [.purple,.orange]
        case .network:return [.cyan,.orange]
        case .disk:return [.blue,.purple]
        case .energy:return [activeMode == "Energy Impact" ? .orange : .pink,.purple]
        case .battery:return [.yellow,.mint]
        }
    }
    private struct RefreshKey:Hashable {
        var item:String;var mode:String;var scope:String;var selection:String?;var time:Date?;var liveTime:Date?
        var first:Date?;var last:Date?;var count:Int;var gaps:Int;var duration:Double
        func hasSameSelection(as other:Self)->Bool {
            item==other.item && mode==other.mode && scope==other.scope && selection==other.selection && time==other.time && duration==other.duration
        }
    }
    private var refreshKey:RefreshKey {
        .init(item:item.rawValue,mode:activeMode,scope:effectiveScope,selection:selectedRowID,time:selectedTime,liveTime:frame?.time,
              first:frames.first?.time,last:frames.last?.time,count:frames.count,gaps:gaps.count,duration:duration)
    }
    private var data:PopupDetailData {preparedKey?.hasSameSelection(as:refreshKey) == true ? preparedData : .init()}

    var body:some View {
        VStack(spacing:0) {
            header
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    controls
                    if !data.readouts.isEmpty {readouts}
                    metricChart
                    if !data.facts.isEmpty {facts(data.facts)}
                    if let error {Label(error,systemImage:"exclamationmark.triangle").font(.system(size:11)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)}
                    if !data.rows.isEmpty {processTable}
                    else if !data.emptyTitle.isEmpty {emptyState}
                    if let selection=data.selection {selectionDetail(selection)}
                    if !data.coverage.isEmpty {Text(data.coverage).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                }.padding(.horizontal,22).padding(.vertical,18)
            }.scrollIndicators(.automatic)
            Divider()
            Button {openExplorer()} label:{
                HStack(spacing:8) {
                    Image(systemName:"chart.xyaxis.line").foregroundStyle(.secondary)
                    Text("Open in Process Explorer").fontWeight(.medium)
                    Spacer()
                    Image(systemName:"arrow.up.right").foregroundStyle(.secondary)
                }.font(.system(size:12)).padding(.horizontal,12).padding(.vertical,11)
                    .background(.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:8))
            }.buttonStyle(.plain).padding(.horizontal,22).padding(.vertical,14)
                .accessibilityIdentifier("popup.detail.explorer")
        }.frame(height:contentHeight)
            .task(id:refreshKey) {
                let key=refreshKey
                isPreparing=true
                let inputFrame=frame,inputFrames=frames,inputGaps=gaps,inputItem=item
                let time=selectedTime,window=duration,mode=activeMode,scope=effectiveScope,selection=selectedRowID
                let physical=ProcessInfo.processInfo.physicalMemory
                let result=await Task.detached(priority:.utility) {
                    PopupDetailData.make(frame:inputFrame,frames:inputFrames,gaps:inputGaps,item:inputItem,
                                         selectedTime:time,duration:window,mode:mode,scope:scope,selectedRowID:selection,physicalMemory:physical)
                }.value
                guard !Task.isCancelled,key==refreshKey else {return}
                preparedData=result;preparedKey=key;isPreparing=false
            }
            .onChange(of:item) {_,_ in mode=nil;scope=nil;selectedRowID=nil;expandedGroups=[]}
            .accessibilityElement(children:.contain)
            .accessibilityIdentifier("popup.detail.\(destination.rawValue)")
    }

    private var header:some View {
        HStack(spacing:10) {
            // Reserve the original label's space so the larger target does not
            // shift the centered title or change the header's height.
            Label("Watt",systemImage:"chevron.left").font(.system(size:12))
                .hidden().accessibilityHidden(true)
            Spacer(minLength:4)
            Text(destination.title).font(.system(size:17,weight:.semibold)).lineLimit(1)
            Spacer(minLength:4)
            if selectedTime != nil {
                Button {selectedTime=nil} label:{
                    HStack(spacing:5) {
                        Text((data.sampleTime ?? selectedTime)?.formatted(date:.omitted,time:.standard) ?? "—").monospacedDigit()
                        Text("Now").foregroundStyle(.secondary)
                        Image(systemName:"arrow.uturn.forward").font(.system(size:9))
                    }.font(.system(size:10))
                }.buttonStyle(.plain).padding(.horizontal,8).padding(.vertical,5)
                    .background(.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:6))
                    .help("Return this view to current readings; recording continues")
                    .accessibilityIdentifier("popup.detail.now")
            } else {
                HStack(spacing:5) {
                    if isLoading || isPreparing {ProgressView().controlSize(.mini)}
                    Text("Now").font(.system(size:11)).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal,22).padding(.vertical,17)
            .overlay(alignment:.leading) {
                PopupDetailBackButton(action:onBack).padding(.leading,10)
            }
    }
    private var modes:[String] {
        switch destination {
        case .cpu:return []
        case .memory:return ["Footprint","Growth","Compression / swap"]
        case .network:return ["Download","Upload"]
        case .disk:return ["Reads","Writes"]
        case .energy:return ["CPU power","Energy Impact"]
        case .battery:return []
        }
    }
    private var supportsGrouping:Bool {destination == .cpu || destination == .network || destination == .energy && activeMode != "Energy Impact"}
    private var controls:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:10) {
                if !modes.isEmpty {
                    Picker("Metric",selection:Binding(get:{activeMode},set:{mode=$0;selectedRowID=nil;expandedGroups=[]})) {
                        ForEach(modes,id:\.self) {Text($0).tag($0)}
                    }.pickerStyle(.segmented).labelsHidden()
                } else if supportsGrouping {groupingPicker}
                Spacer(minLength:0)
                Picker("Recent range",selection:$duration) {Text("1m").tag(60.0);Text("5m").tag(300.0);Text("15m").tag(900.0)}
                    .pickerStyle(.segmented).labelsHidden().frame(width:132)
                    .accessibilityIdentifier("popup.detail.range")
            }
            if supportsGrouping && !modes.isEmpty {
                HStack {groupingPicker;Spacer();if isLoading || isPreparing {ProgressView().controlSize(.mini)}}
            }
        }.controlSize(.small)
    }
    private var groupingPicker:some View {
        Picker("Group processes",selection:Binding(get:{effectiveScope},set:{scope=$0;selectedRowID=nil;expandedGroups=[]})) {
            Text("Processes").tag("Processes");Text("Applications").tag("Applications")
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth:220)
            .accessibilityIdentifier("popup.detail.grouping")
    }
    private var readouts:some View {
        HStack(alignment:.top,spacing:18) {
            ForEach(Array(data.readouts.enumerated()),id:\.element.id) {index,readout in
                VStack(alignment:.leading,spacing:5) {
                    HStack(spacing:5) {Circle().fill(colors[min(index,colors.count-1)]).frame(width:5,height:5);Text(readout.title).foregroundStyle(.secondary)}.font(.system(size:10))
                    HStack(alignment:.firstTextBaseline,spacing:3) {
                        Text(readout.value).font(.system(size:29,weight:.medium,design:.rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        if !readout.unit.isEmpty {Text(readout.unit).font(.system(size:12)).foregroundStyle(.secondary)}
                    }
                    Text(readout.context).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
    private var chartDomain:ClosedRange<Double> {
        let values=data.points.map(\.value)
        let high=data.chartCeiling ?? max(1,(values.max() ?? 1)*1.1)
        let low=data.signedChart ? min(-1,(values.min() ?? 0)*1.1) : 0
        return low...max(low+1,high)
    }
    private var metricChart:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text(data.chartTitle.isEmpty ? "Recent history" : data.chartTitle).lineLimit(2)
                Spacer(minLength:8)
                if let range=data.range {Text(coverageDuration(range.duration)).monospacedDigit().lineLimit(1)}
            }.font(.system(size:10)).foregroundStyle(.secondary)
            if data.points.isEmpty {
                RoundedRectangle(cornerRadius:6).fill(.primary.opacity(0.025)).frame(height:145)
                    .overlay {Text(isLoading || isPreparing ? "Loading recorded samples…" : "No measured history in this interval").font(.system(size:11)).foregroundStyle(.secondary)}
            } else {
                Chart {
                    ForEach(data.points) {point in
                        if !data.signedChart {
                            AreaMark(x:.value("Time",point.time),yStart:.value("Baseline",0),yEnd:.value("Value",point.value),series:.value("Segment",point.segment))
                                .foregroundStyle(by:.value("Series",point.series)).opacity(0.10)
                        }
                        LineMark(x:.value("Time",point.time),y:.value("Value",point.value),series:.value("Segment",point.segment))
                            .foregroundStyle(by:.value("Series",point.series))
                            .lineStyle(StrokeStyle(lineWidth:2,lineCap:.round,lineJoin:.round,dash:point.series==data.series.last && data.series.count>1 ? [5,3] : []))
                    }
                    if let selectedTime {
                        RuleMark(x:.value("Selected time",selectedTime))
                            .foregroundStyle(Color.primary.opacity(0.9)).lineStyle(StrokeStyle(lineWidth:2.5))
                    }
                    if data.signedChart {RuleMark(y:.value("Zero",0)).foregroundStyle(.secondary.opacity(0.45)).lineStyle(StrokeStyle(lineWidth:1))}
                }
                .chartForegroundStyleScale(domain:data.series,range:Array(colors.prefix(data.series.count)))
                .chartYScale(domain:chartDomain)
                .chartXAxis {AxisMarks(values:.automatic(desiredCount:3)) {_ in AxisValueLabel(format:.dateTime.hour().minute().second())}}
                .chartYAxis {AxisMarks(position:.leading,values:.automatic(desiredCount:3)) {value in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.07))
                    AxisValueLabel {if let value=value.as(Double.self) {Text(axisValue(value))}}
                }}
                .chartLegend(data.series.count>1 ? .visible : .hidden)
                .chartLegend(position:.bottom,alignment:.leading,spacing:6)
                .chartOverlay {proxy in
                    GeometryReader {geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture {location in
                            guard let plot=proxy.plotFrame else {return}
                            let x=location.x-geometry[plot].origin.x
                            guard x>=0,x<=geometry[plot].width,let time:Date=proxy.value(atX:x) else {return}
                            selectedTime=time
                        }
                    }
                }
                .frame(height:165)
                .accessibilityLabel("\(destination.title) recorded history. Missing samples remain gaps.")
                .accessibilityIdentifier("popup.detail.chart")
            }
        }
    }
    private var processTable:some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                Text(data.columns.first ?? "Process").frame(maxWidth:.infinity,alignment:.leading)
                Text(data.columns.count>1 ? data.columns[1] : "Value").frame(width:82,alignment:.trailing)
                Text(data.columns.count>2 ? data.columns[2] : "").frame(width:86,alignment:.trailing)
            }.font(.system(size:10)).foregroundStyle(.secondary).padding(.bottom,9)
            Divider()
            ForEach(data.rows) {row in
                tableRow(row,indented:false)
                if expandedGroups.contains(row.id) {
                    ForEach(Array(row.children.prefix(8))) {child in tableRow(child,indented:true)}
                    if row.children.count>8 {Text("\(row.children.count-8) more observed processes in Explorer").font(.system(size:10)).foregroundStyle(.secondary).padding(.vertical,7)}
                }
            }
        }
    }
    private func tableRow(_ row:PopupDetailRow,indented:Bool)->some View {
        HStack(spacing:0) {
            if !row.children.isEmpty {
                Button {if expandedGroups.contains(row.id) {expandedGroups.remove(row.id)} else {expandedGroups.insert(row.id)}} label:{
                    Image(systemName:expandedGroups.contains(row.id) ? "chevron.down" : "chevron.right").font(.system(size:9)).frame(width:17,height:30)
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("\(expandedGroups.contains(row.id) ? "Collapse" : "Expand") \(row.name)")
            } else if indented {Color.clear.frame(width:17,height:1)}
            Button {selectedRowID=selectedRowID == row.id ? nil : row.id} label:{
                HStack(spacing:10) {
                    VStack(alignment:.leading,spacing:5) {
                        HStack(spacing:4) {
                            Text(row.name).lineLimit(1).truncationMode(.middle)
                            if row.partial {Image(systemName:"circle.lefthalf.filled").font(.system(size:8)).foregroundStyle(.secondary).help("Partial measurement coverage")}
                            if row.primary == nil {Image(systemName:"lock.fill").font(.system(size:8)).foregroundStyle(.tertiary)}
                        }
                        if let primary=row.primary,primary>0 {
                            GeometryReader {geometry in Capsule().fill(colors[0].opacity(0.65)).frame(width:max(2,geometry.size.width*min(1,primary/max(data.rows.compactMap(\.primary).max() ?? 1,0.001))))}.frame(height:3)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).help(row.name)
                    Text(row.primaryText).monospacedDigit().frame(width:82,alignment:.trailing)
                    Text(row.secondaryText).monospacedDigit().frame(width:86,alignment:.trailing)
                }.font(.system(size:11)).padding(.vertical,10).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Inspect \(row.name), \(row.primaryText), \(row.secondaryText)")
                .accessibilityIdentifier("popup.detail.row.\(row.id)")
        }.padding(.horizontal,5)
            .background(selectedRowID == row.id ? Color.primary.opacity(0.055) : .clear,in:RoundedRectangle(cornerRadius:5))
            .overlay(alignment:.bottom) {Rectangle().fill(.primary.opacity(0.07)).frame(height:0.5)}
    }
    private var emptyState:some View {
        VStack(alignment:.leading,spacing:6) {
            Label(data.emptyTitle,systemImage:destination == .network ? "network" : "chart.xyaxis.line").font(.system(size:12,weight:.medium))
            Text(data.emptyDetail).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,12)
    }
    private func selectionDetail(_ selection:PopupDetailSelection)->some View {
        VStack(alignment:.leading,spacing:12) {
            Divider()
            HStack(alignment:.top,spacing:12) {
                Text(selection.row.name).font(.system(size:12,weight:.medium)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                Button(selection.row.process == nil ? "Inspect group ↗" : "Inspect process ↗") {openExplorer()}.controlSize(.small)
                    .accessibilityIdentifier("popup.detail.inspectProcess")
            }
            facts(selection.facts)
            Text(selection.coverage).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func facts(_ values:[PopupDetailFact])->some View {
        LazyVGrid(columns:[GridItem(.flexible(),alignment:.leading),GridItem(.flexible(),alignment:.leading)],alignment:.leading,spacing:12) {
            ForEach(values) {fact in
                VStack(alignment:.leading,spacing:4) {
                    Text(fact.title).font(.system(size:9)).foregroundStyle(.secondary)
                    Text(fact.value).font(.system(size:11)).monospacedDigit().textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                }
            }
        }
    }
    private func openExplorer() {
        let end=data.range?.end ?? frames.last?.time
        let range=end.map {DateInterval(start:$0.addingTimeInterval(-duration),end:$0)}
        onOpenExplorer(.detail(item:item,duration:duration,selectedTime:selectedTime,sampleTime:data.sampleTime,graphRange:range,
                               selection:data.selection?.row,scope:effectiveScope,mode:activeMode))
    }
    private func axisValue(_ value:Double)->String {
        switch data.chartUnit {
        case "bytes":return bytes(UInt64(max(0,value)))
        case "bytes/s":return PopupDetailData.fullRate(max(0,value))
        case "%":return String(format:"%.0f%%",value)
        case "W":return String(format:"%.1f W",value)
        default:return String(format:"%.0f",value)
        }
    }
    private func coverageDuration(_ seconds:Double)->String {
        seconds>=60 ? "\(Int(seconds/60))m \(Int(seconds.truncatingRemainder(dividingBy:60)))s covered" : "\(Int(max(0,seconds)))s covered"
    }
}

private struct PopupDetailBackButton:View {
    let action:()->Void
    @State private var hovered=false
    @FocusState private var focused:Bool

    var body:some View {
        Button(action:action) {
            Label("Watt",systemImage:"chevron.left").font(.system(size:12))
                .padding(.horizontal,12)
                .frame(width:112,height:44,alignment:.leading)
                .contentShape(Rectangle())
                .background(hovered || focused ? Color.primary.opacity(0.065) : .clear,in:RoundedRectangle(cornerRadius:8))
                .overlay {
                    if focused {RoundedRectangle(cornerRadius:8).strokeBorder(Color.accentColor.opacity(0.65),lineWidth:1)}
                }
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .focused($focused)
            .onHover {hovered=$0}
            .help("Back to tiles")
            .accessibilityLabel("Back to tiles")
            .accessibilityIdentifier("popup.detail.back")
    }
}
