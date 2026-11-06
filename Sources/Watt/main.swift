import AppKit
import SwiftUI
import Charts
import Combine
import CoreText

@MainActor final class Ribbon:NSView {
    var frames:[Frame]=[] {didSet{needsDisplay=true}}
    var settings:MenuBarSettings?
    var action:(()->Void)?
    override func mouseDown(with event:NSEvent) {action?()}
    private func fraction(_ f:Frame,_ metric:String)->Double? {
        switch metric {
        case "Memory":return min(1,Double(f.memory)/Double(ProcessInfo.processInfo.physicalMemory))
        case "Network":return min(1,log10(max(1,f.download+f.upload))/9)
        case "Battery power":return f.power.flatMap {$0.hasUsableCurrent ? min(1,abs($0.watts)/30) : nil}
        default:return f.cpu/100
        }
    }
    private func number(_ metric:String)->String {
        guard let f=frames.last else {return "—"}
        switch metric {
        case "Memory":return String(format:"%.0f%%",Double(f.memory)/Double(ProcessInfo.processInfo.physicalMemory)*100)
        case "Network":let rate=f.download+f.upload;return rate>=1048576 ? String(format:"%.1fM",rate/1048576) : rate>=1024 ? String(format:"%.0fK",rate/1024) : String(format:"%.0fB",rate)
        case "Battery power":return f.power?.formatted ?? "—"
        default:return String(format:"%.0f%%",f.cpu)
        }
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let settings,let context=NSGraphicsContext.current?.cgContext else {return}
        let foreground=(NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .white)
        let accent=(settings.color ? NSColor.systemMint : foreground).usingColorSpace(.deviceRGB) ?? foreground
        let showNetwork=settings.network && settings.layout == "Ribbon"
        let networkWidth=showNetwork ? (settings.networkNumbers ? 27.0 : 13.0) : 0
        let metricWidth=max(10,bounds.width-4-networkWidth-(showNetwork ? 1 : 0))
        func label(_ string:String,in rect:NSRect,alignment:NSTextAlignment = .center) {
            var size:CGFloat=8.5
            func line(_ size:CGFloat)->CTLine {
                CTLineCreateWithAttributedString(NSAttributedString(string:string,attributes:[
                    NSAttributedString.Key(kCTFontAttributeName as String):NSFont.monospacedDigitSystemFont(ofSize:size,weight:.medium) as CTFont,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):foreground.cgColor
                ]))
            }
            var text=line(size)
            let measured=CTLineGetTypographicBounds(text,nil,nil,nil)
            if measured>rect.width {size=max(7.5,size*rect.width/measured);text=line(size)}
            let width=CTLineGetTypographicBounds(text,nil,nil,nil)
            let x=alignment == .right ? rect.maxX-width : alignment == .left ? rect.minX : rect.midX-width/2
            context.saveGState();context.clip(to:rect);context.textMatrix = .identity
            context.textPosition=CGPoint(x:x,y:rect.minY+3.5)
            CTLineDraw(text,context);context.restoreGState()
        }
        func meter(_ value:Double?,in rect:NSRect,tint:NSColor) {
            tint.withAlphaComponent(0.18).setFill();rect.fill()
            guard let value,value>0 else {return}
            tint.withAlphaComponent(0.95).setFill()
            NSRect(x:rect.minX,y:rect.minY,width:max(1,rect.width*min(1,value)),height:rect.height).fill()
        }
        for (base,metric) in [(12.0,settings.primary),(1.0,settings.secondary)] {
            var row=NSRect(x:2,y:base,width:settings.layout == "Numeric" ? bounds.width-4 : metricWidth,height:11)
            let prefix=metric == "CPU" ? "C" : metric == "Memory" ? "M" : ""
            let rowColor=settings.color && metric == "Memory" ? (NSColor.systemPurple.usingColorSpace(.deviceRGB) ?? accent) : accent
            if settings.layout == "Numeric" {label((metric == "CPU" ? "CPU " : metric == "Memory" ? "MEM " : "")+number(metric),in:row,alignment:.left);continue}
            let numbers=settings.metricNumbers && ["CPU","Memory"].contains(metric)
            if !numbers && !prefix.isEmpty {
                label(prefix,in:NSRect(x:row.minX,y:base,width:7,height:11),alignment:.left)
                row.origin.x+=8;row.size.width=max(1,row.width-8)
            }
            let graphHeight=numbers ? 2.0 : 9.0
            if settings.graphStyle == "Meter" {
                meter(frames.last.flatMap {fraction($0,metric)},in:NSRect(x:row.minX,y:base,width:row.width,height:graphHeight),tint:rowColor)
            } else if settings.graphStyle == "Bars" {
                let samples=Array(frames.suffix(max(1,Int(row.width/3))))
                let step=row.width/Double(max(1,samples.count))
                for (index,frame) in samples.enumerated() {
                    guard let value=fraction(frame,metric),value>0 else {continue}
                    rowColor.withAlphaComponent(0.9).setFill()
                    NSRect(x:row.minX+Double(index)*step,y:base,width:max(1,step-1),height:max(1,min(1,value)*graphHeight)).fill()
                }
            } else {
                let samples=Array(frames.suffix(20));let path=NSBezierPath();var connected=false
                for (index,frame) in samples.enumerated() {
                    guard let value=fraction(frame,metric) else {connected=false;continue}
                    let point=NSPoint(x:row.minX+Double(index)*row.width/Double(max(1,samples.count-1)),y:base+value*graphHeight)
                    if connected {path.line(to:point)}else{path.move(to:point);connected=true}
                }
                rowColor.setStroke();path.lineWidth=numbers ? 1 : 2;path.stroke()
            }
            if numbers {label(prefix+number(metric).replacingOccurrences(of:"%",with:""),in:row,alignment:.left)}
            else if frames.last.flatMap({fraction($0,metric)}) == nil {label("—",in:row)}
        }
        if showNetwork {
            let x=bounds.width-networkWidth-1
            if settings.networkNumbers {
                for (base,rate,arrow) in [(12.0,frames.last?.download,"↓"),(1.0,frames.last?.upload,"↑")] {
                    let row=NSRect(x:x,y:base,width:networkWidth,height:11)
                    meter(rate.map {min(1,log10(max(1,$0))/9)},in:NSRect(x:x,y:base,width:networkWidth,height:2),tint:accent)
                    label(arrow+(rate.map(compactNetworkRate) ?? "—"),in:row,alignment:.right)
                }
            } else {
                for (offset,rate) in [(0.0,frames.last?.download),(7.0,frames.last?.upload)] {
                    meter(rate.map {min(1,log10(max(1,$0))/9)},in:NSRect(x:x+offset,y:1,width:4,height:20),tint:accent)
                }
            }
        }
    }
}

struct LiveView:View {
    @ObservedObject var monitor:Monitor
    var open:()->Void
    var configure:()->Void
    @ObservedObject var layout:PopupLayoutSettings
    private var popupWidth:CGFloat {min(max(380,layout.contentWidth()+44),max(380,(NSScreen.main?.visibleFrame.width ?? 1440)-40))}
    private var maximumDashboardHeight:CGFloat {max(160,(NSScreen.main?.visibleFrame.height ?? 900)-240)}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text("Watt").font(.title2.weight(.semibold));Spacer()}
            if let f=monitor.liveFrame {
                ScrollView([.vertical,.horizontal]) {
                    PopupDashboard(frame:f,frames:Array(monitor.frames.suffix(36)),layout:layout).frame(maxWidth:.infinity)
                }.scrollIndicators(.hidden).frame(height:min(layout.contentHeight(),maximumDashboardHeight))
            } else {Text("Measuring the first complete interval…").foregroundStyle(.secondary)}
            if let error=monitor.error {Text(error).font(.caption).foregroundStyle(.orange)}
            Divider()
            VStack(spacing:12) {
                Button(action:open) {
                    HStack(spacing:8) {
                        Image(systemName:"chart.xyaxis.line").foregroundStyle(.secondary)
                        Text("Open Process Explorer").fontWeight(.medium)
                        Spacer()
                        Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)).foregroundStyle(.tertiary)
                    }.font(.system(size:12)).padding(.horizontal,12).padding(.vertical,10)
                        .frame(maxWidth:.infinity)
                        .background(.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:8))
                }.buttonStyle(.plain)
                HStack(spacing:8) {
                    PopupAction(title:"Preferences…",symbol:"slider.horizontal.3",action:configure)
                    PopupAction(title:"Quit",symbol:"power") {NSApp.terminate(nil)}
                }

            }
        }.padding(22).frame(width:popupWidth)
    }
}

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate,NSPopoverDelegate {
    let menuSettings:MenuBarSettings
    let popupLayout:PopupLayoutSettings
    private let explorerControls=ProcessExplorerControls()
    private let layoutPresenter=PopupLayoutEditorPresenter()
    lazy var updater=AppUpdater()
    let energyCollector=EnergyImpactCollector()
    private var energyIntervalSubscription:AnyCancellable?
    private var energySleepObservers:[NSObjectProtocol]=[]
    var ribbon:Ribbon?
    var appearanceSubscription:AnyCancellable?
    let monitor:Monitor
    init(monitor:Monitor?=nil,menuSettings:MenuBarSettings?=nil,popupLayout:PopupLayoutSettings?=nil) {
        self.monitor=monitor ?? Monitor();self.menuSettings=menuSettings ?? MenuBarSettings();self.popupLayout=popupLayout ?? PopupLayoutSettings()
        super.init()
    }
    var item:NSStatusItem!;let popover=NSPopover();var window:NSWindow?;var preferencesWindow:NSWindow?;var subscription:AnyCancellable?
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        let mainMenu=NSMenu()
        let applicationItem=NSMenuItem()
        let applicationMenu=NSMenu(title:"Watt")
        let showItem=NSMenuItem(title:"Show Watt",action:#selector(statusPressed(_:)),keyEquivalent:"")
        showItem.target=self;applicationMenu.addItem(showItem)
        let preferencesItem=NSMenuItem(title:"Preferences…",action:#selector(showPreferences),keyEquivalent:",")
        preferencesItem.target=self;applicationMenu.addItem(preferencesItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title:"Quit Watt",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
        applicationItem.submenu=applicationMenu;mainMenu.addItem(applicationItem);NSApp.mainMenu=mainMenu
        item=NSStatusBar.system.statusItem(withLength:menuSettings.width)
        item.button?.setAccessibilityLabel("Watt")
        item.button?.target=self;item.button?.action=#selector(statusPressed(_:))
        let ribbon=Ribbon(frame:NSRect(x:0,y:0,width:menuSettings.width,height:24));self.ribbon=ribbon;ribbon.settings=menuSettings;item.button?.addSubview(ribbon)
        appearanceSubscription=menuSettings.objectWillChange.sink { [weak self] in DispatchQueue.main.async {guard let self else{return};self.item.length=self.menuSettings.width;self.ribbon?.frame.size.width=self.menuSettings.width;self.ribbon?.needsDisplay=true} }
        ribbon.action={ [weak self] in self?.toggle() }
        subscription=monitor.$liveFrame.sink { [weak ribbon] frame in
            guard let ribbon,let frame else {return}
            var gauge=frame;gauge.processes=[];gauge.energyImpact=nil
            ribbon.frames=Array((ribbon.frames+[gauge]).suffix(36))
            ribbon.toolTip="CPU \(Int(frame.cpu))% · Memory \(bytes(frame.memory)) · ↓ \(bytes(UInt64(frame.download)))/s ↑ \(bytes(UInt64(frame.upload)))/s · Click to inspect"
            ribbon.setAccessibilityLabel(ribbon.toolTip)
        }
        installDismissalMonitors()
        popover.delegate=self
        popover.behavior = .transient
        _ = updater
        energyIntervalSubscription=monitor.$interval.removeDuplicates().sink { [weak self] interval in
            DispatchQueue.main.async {self?.energyCollector.start(interval:interval)}
        }
        let workspace=NSWorkspace.shared.notificationCenter
        energySleepObservers.append(workspace.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {self?.energyCollector.stop()}
        })
        energySleepObservers.append(workspace.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {guard let self else {return};self.energyCollector.start(interval:self.monitor.interval)}
        })
        publishWindowState()
        // Launch as a menu bar recorder. Build expensive views only while shown.
    }
    private func showLiveContent() {
        popover.contentViewController=NSHostingController(rootView:LiveView(monitor:monitor,open:{[weak self] in self?.showExplorer()},configure:{[weak self] in self?.showPreferences()},layout:popupLayout))
    }
    @objc private func showPreferences() {
        popover.performClose(nil)
        if preferencesWindow == nil {
            let preferences=NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:680),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            preferences.title="Watt Preferences"
            preferences.delegate=self;preferences.contentView=nil
            preferences.isReleasedWhenClosed=false
            preferences.center();preferencesWindow=preferences
        }
        if preferencesWindow?.contentView == nil {
            preferencesWindow?.contentView=NSHostingView(rootView:PreferencesView(settings:menuSettings,monitor:monitor,updater:updater,popupLayout:popupLayout,energyCollector:energyCollector,layoutPresenter:layoutPresenter))
        }
        NSApp.activate();preferencesWindow?.makeKeyAndOrderFront(nil)
    }
    private var outsideMonitor:Any?
    private var localMonitor:Any?
    private func dismissSurfaces() {
        if popover.isShown { popover.performClose(nil) }
        hideExplorer()
        publishWindowState()
    }
    private func installDismissalMonitors() {
        // Global monitors see clicks delivered to other apps; local monitors cover our own windows/status item.
        outsideMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { guard let self,self.popover.isShown || self.window?.isVisible == true else {return};self.dismissSurfaces() }
        }
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in
            guard let self else {return event}
            let isStatus=event.window === self.item.button?.window
            let isPopover=event.window === self.popover.contentViewController?.view.window
            let isExplorer=event.window === self.window
            if event.window == nil {self.dismissSurfaces()}
            else if isExplorer && self.popover.isShown {self.popover.performClose(nil)}
            else if isPopover && !isStatus {self.hideExplorer()}
            return event
        }
    }
    func applicationDidBecomeActive(_ notification:Notification) {
        energyCollector.refreshStatus()
        if energyCollector.isInstalled && !energyCollector.isRunning {energyCollector.start(interval:monitor.interval)}
    }
    func applicationDidResignActive(_ notification:Notification) {dismissSurfaces()}
    func applicationWillTerminate(_ notification:Notification) {
        energyCollector.stop()
        for observer in energySleepObservers {NSWorkspace.shared.notificationCenter.removeObserver(observer)}
        if let outsideMonitor {NSEvent.removeMonitor(outsideMonitor)}
        if let localMonitor {NSEvent.removeMonitor(localMonitor)}
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {showExplorer();return true}
    private func hideExplorer() {
        window?.orderOut(nil)
        window?.contentView=nil
        explorerControls.releaseDerivedData()
        monitor.releaseHistoryDetails()
    }
    func windowDidResignKey(_ notification:Notification) {
        guard let changed=notification.object as? NSWindow,changed === window else {return}
        hideExplorer();publishWindowState()
    }
    func windowWillClose(_ notification:Notification) {
        guard let changed=notification.object as? NSWindow else {return}
        if changed === window {hideExplorer()}
        else if changed === preferencesWindow {changed.contentView=nil}
    }
    func popoverDidShow(_ notification:Notification) {publishWindowState()}
    func popoverDidClose(_ notification:Notification) {popover.contentViewController=nil;publishWindowState()}
    private func publishWindowState() {
        #if DEBUG
        guard item != nil else {return}
        // Development-only visibility probe for real outside-click checks. No input events are logged.
        let state:[String:Any] = ["popupContentAttached":popover.contentViewController != nil,"explorerContentAttached":window?.contentView != nil,"preferencesContentAttached":preferencesWindow?.contentView != nil,"liveFrameCount":monitor.frames.count,"liveProcessRows":monitor.frames.reduce(0) {$0+$1.processes.count},"menuColor":menuSettings.color,"paused":monitor.paused,"preferencesVisible":preferencesWindow?.isVisible ?? false,"explorerVisible":window?.isVisible ?? false,"popoverVisible":popover.isShown,"statusWidth":item?.length ?? 0,"appActive":NSApp.isActive,"keyWindow":window?.isKeyWindow ?? false,"globalMonitorInstalled":outsideMonitor != nil,"localMonitorInstalled":localMonitor != nil,"updatedAt":Date().timeIntervalSince1970]
        let path=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Watt/window-state.json")
        if let data=try? JSONSerialization.data(withJSONObject:state,options:.sortedKeys) {try? data.write(to:path,options:.atomic)}
        #endif
    }
    @objc private func statusPressed(_ sender:Any?) {toggle()}
    func toggle() {if popover.isShown{popover.performClose(nil)}else if let button=item.button{showLiveContent();NSApp.activate();popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY);popover.contentViewController?.view.window?.makeKey()}}
    func showExplorer() {
        popover.performClose(nil)
        if window==nil {explorerControls.center=(monitor.liveFrame?.time ?? monitor.historyBounds?.end ?? Date()).addingTimeInterval(-explorerControls.duration/2);let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);w.title="Watt · Process Explorer";w.delegate=self;w.contentView=nil;w.isReleasedWhenClosed=false;w.center();window=w}
        monitor.restoreHistoryDetailsIfNeeded()
        window?.title="Watt · Process Explorer"
        if window?.contentView == nil {window?.contentView=NSHostingView(rootView:ProcessExplorerView(monitor:monitor,controls:explorerControls))}
        NSApp.activate();DispatchQueue.main.async { [weak self] in self?.window?.makeKeyAndOrderFront(nil);self?.publishWindowState() }
    }
}

if CommandLine.arguments.contains("--benchmark-ui") {
    MainActor.assumeIsolated {runUIPerformanceBenchmark()}
    exit(0)
}
if CommandLine.arguments.contains("--diagnose-settings") {
    MainActor.assumeIsolated {
        let settings=MenuBarSettings()
        print("Bundle: \(Bundle.main.bundleIdentifier ?? "unbundled") · preferences: \(MenuBarSettings.preferencesDomain) · color: \(settings.color) · width: \(settings.width)")
    }
    exit(0)
}
if CommandLine.arguments.contains("--smoke-test") {
    let collector=Collector();_ = collector.sample();Thread.sleep(forTimeInterval:1)
    if let frame=collector.sample() {print("CPU \(frame.cpu), memory \(bytes(frame.memory)), processes \(frame.processes.count), unavailable \(frame.denied), battery \(frame.power?.formatted ?? "unavailable")");exit(frame.processes.isEmpty ? 1 : 0)}
    exit(1)
}
if let index=CommandLine.arguments.firstIndex(of:"--render-preferences-preview"),CommandLine.arguments.count>index+1 {
    MainActor.assumeIsolated {do {try renderPreferencesPreview(to:CommandLine.arguments[index+1])}catch {fputs("Preferences preview failed: \(error)\n",stderr);exit(1)}}
    exit(0)
}
if let index=CommandLine.arguments.firstIndex(of:"--render-layout-preview"),CommandLine.arguments.count>index+1 {
    MainActor.assumeIsolated {do {try renderPreferencesPreview(to:CommandLine.arguments[index+1],editor:true)}catch {fputs("Layout preview failed: \(error)\n",stderr);exit(1)}}
    exit(0)
}
if let index=CommandLine.arguments.firstIndex(of:"--render-explorer-preview"),CommandLine.arguments.count>index+1 {
    MainActor.assumeIsolated {
        do {try renderExplorerPreview(to:CommandLine.arguments[index+1],applications:CommandLine.arguments.contains("--applications"))}
        catch {fputs("Explorer preview failed: \(error)\n",stderr);exit(1)}
    }
    exit(0)
}
if let index=CommandLine.arguments.firstIndex(of:"--render-popup-preview"),CommandLine.arguments.count>index+1 {MainActor.assumeIsolated {renderPopupPreview(to:CommandLine.arguments[index+1])};exit(0)}
if let index=CommandLine.arguments.firstIndex(of:"--render-menu-preview"),CommandLine.arguments.count>index+1 {MainActor.assumeIsolated {renderMenuPreview(to:CommandLine.arguments[index+1])};exit(0)}
if CommandLine.arguments.contains("--benchmark") { runBenchmark(); exit(0) }
let app=NSApplication.shared
MainActor.assumeIsolated {
    let delegate=AppDelegate();app.delegate=delegate;withExtendedLifetime(delegate) {app.run()}
}
