import SwiftUI
import AppKit
import WattEnergyProtocol

@MainActor final class PopupLayoutEditorWindowController:NSWindowController {
    init(layout:PopupLayoutSettings,monitor:Monitor) {
        let availableWidth=NSScreen.main?.visibleFrame.width ?? 1440
        let initialWidth=min(availableWidth-40,max(900,layout.contentWidth()+412))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:initialWidth,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Popup layout"
        window.minSize=NSSize(width:760,height:650)
        window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:PopupLayoutEditorView(layout:layout,monitor:monitor))
        super.init(window:window)
        window.center()
        window.setFrameAutosaveName("WattPopupLayoutEditor")
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
}

@MainActor final class PopupLayoutEditorPresenter:ObservableObject {
    private var controller:PopupLayoutEditorWindowController?
    func show(layout:PopupLayoutSettings,monitor:Monitor) {
        if controller == nil {controller=PopupLayoutEditorWindowController(layout:layout,monitor:monitor)}
        NSApp.activate(ignoringOtherApps:true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}

struct PopupLayoutEditorView:View {
    @ObservedObject var layout:PopupLayoutSettings
    @ObservedObject var monitor:Monitor
    var isExample:Bool=false
    @State private var paletteTargeted=false
    var body:some View {
        VStack(spacing:0) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:5) {
                    Text("Make the popup yours").font(.system(size:22,weight:.semibold,design:.rounded))
                }
                Spacer()
                Picker("Columns",selection:$layout.columnCount) {
                    ForEach(2...6,id:\.self) {Text("\($0)").tag($0)}
                }.pickerStyle(.menu).frame(width:112).accessibilityIdentifier("popup.layout.columns")
                Button("Reset layout") {layout.reset()}.help("Restore the default tiles, order, and two-column layout").accessibilityIdentifier("popup.layout.reset")
            }.padding(24)
            Divider()
            HStack(alignment:.top,spacing:0) {
                VStack(alignment:.leading,spacing:0) {
                    HStack {
                        Text("AVAILABLE").font(.system(size:10,weight:.semibold)).tracking(1.5)
                        Spacer()
                        Text("\(layout.availableEntries.count)").font(.system(size:11))
                    }.foregroundStyle(.secondary).padding(.horizontal,24).padding(.vertical,15)
                    ScrollView {
                        LazyVStack(spacing:10) {
                            ForEach(layout.availableEntries) {entry in
                                PopupAvailableTile(entry:entry,layout:layout)
                            }
                            if layout.availableEntries.isEmpty {
                                Text("All tiles are in your popup.").font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.vertical,30)
                            }
                        }.padding(.horizontal,20).padding(.bottom,20)
                    }

                }.frame(width:310)
                    .frame(maxHeight:.infinity)
                    .background(paletteTargeted ? Color.accentColor.opacity(0.07) : Color.clear)
                    .contentShape(Rectangle())
                    .dropDestination(for:String.self) {items,_ in
                        guard let raw=items.first,let id=PopupItemID(rawValue:raw),layout.visibleEntries.contains(where:{$0.id==id}) else {return false}
                        layout.setVisible(false,for:id);return true
                    } isTargeted:{paletteTargeted=$0}
                    .accessibilityIdentifier("popup.layout.available")
                Divider()
                VStack(alignment:.leading,spacing:0) {
                    HStack {
                        Text("YOUR POPUP").font(.system(size:10,weight:.semibold)).tracking(1.5)
                        Text("\(layout.visibleEntries.count) tiles").font(.system(size:10))
                        Spacer()
                        Text(isExample || monitor.liveFrame == nil ? "Example data" : "Current samples").font(.system(size:10))
                    }.foregroundStyle(.secondary).padding(.vertical,15)
                    ScrollView([.horizontal,.vertical]) {
                        let frames=monitor.frames.isEmpty ? PopupLayoutPreview.frames : Array(monitor.frames.suffix(36))
                        if let frame=monitor.liveFrame ?? frames.last {
                            PopupDashboard(frame:frame,frames:frames,layout:layout,editingLayout:true).padding(16)
                                .background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
                                .overlay {RoundedRectangle(cornerRadius:18).strokeBorder(.primary.opacity(0.08),lineWidth:0.5)}
                        }
                    }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                }.frame(minWidth:364,maxWidth:.infinity).padding(.horizontal,24)
            }
        }.background(Color(nsColor:.windowBackgroundColor))
    }
}

private struct PopupAvailableTile:View {
    let entry:PopupLayoutEntry
    @ObservedObject var layout:PopupLayoutSettings
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            Text(entry.id.title).font(.system(size:13,weight:.medium))
            Text(entry.id.detail).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(14)
            .background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:11))
            .overlay {RoundedRectangle(cornerRadius:11).strokeBorder(.primary.opacity(0.065),lineWidth:0.5)}
            .contentShape(RoundedRectangle(cornerRadius:11))
            .draggable(entry.id.rawValue)
            .contextMenu {Button("Add to popup") {layout.place(entry.id,atVisibleIndex:layout.visibleEntries.count)}}
            .accessibilityElement(children:.combine)
            .accessibilityLabel("\(entry.id.title), available tile")
            .accessibilityHint("Drag into the preview, or use the Add tile action")
            .accessibilityAction(named:Text("Add tile")) {layout.place(entry.id,atVisibleIndex:layout.visibleEntries.count)}
            .accessibilityIdentifier("popup.layout.available.\(entry.id.rawValue)")
    }
}

// Used only before the first real sample. The editor labels these readings as examples.
enum PopupLayoutPreview {
    static var frames:[Frame] {
        let now=Date(timeIntervalSince1970:1_800_000_000)
        return (0..<36).map {index in
            let wave=sin(Double(index)/4)
            let process=ProcessRow(pid:120,parent:1,start:1,name:"Build process",cpu:145+wave*30,memory:512*1024*1024,growth:nil,read:2*1024*1024,written:512*1024,energyNanojoules:2_000_000_000)
            let time=now.addingTimeInterval(Double(index)*5)
            let energy=EnergyImpactSample(startedAt:time.addingTimeInterval(-1),endedAt:time,tasks:[EnergyImpactTask(pid:process.pid,name:process.name,energyImpact:3+wave,energyImpactPerSecond:3+wave,processStartMicroseconds:process.start)])
            return Frame(time:time,cpu:42+wave*18,memory:UInt64(Double(ProcessInfo.processInfo.physicalMemory)*(0.55+wave*0.025)),compressed:2*1024*1024*1024,swap:512*1024*1024,download:450_000+wave*280_000,upload:90_000+wave*50_000,processes:[process],denied:0,power:PowerReading(volts:12.1,amps:-0.8-wave*0.2,externalPower:false,sampledAt:now),segment:"example",elapsed:5,energyImpact:energy)
        }
    }
}
