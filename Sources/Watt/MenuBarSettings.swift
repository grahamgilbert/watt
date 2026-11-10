import SwiftUI

@MainActor final class MenuBarSettings: ObservableObject {
    private let defaults:UserDefaults
    @Published var width:Double {didSet{defaults.set(width,forKey:"menu.width")}}
    @Published var layout:String {didSet{defaults.set(layout,forKey:"menu.layout")}}
    @Published var primary:String {didSet{defaults.set(primary,forKey:"menu.primary")}}
    @Published var secondary:String {didSet{defaults.set(secondary,forKey:"menu.secondary")}}
    @Published var network:Bool {didSet{defaults.set(network,forKey:"menu.network")}}
    @Published var metricNumbers:Bool {didSet{defaults.set(metricNumbers,forKey:"menu.metricNumbers")}}
    @Published var networkNumbers:Bool {didSet{defaults.set(networkNumbers,forKey:"menu.networkNumbers")}}
    @Published var graphStyle:String {didSet{defaults.set(graphStyle,forKey:"menu.graphStyle")}}
    @Published var color:Bool {didSet{defaults.set(color,forKey:"menu.color")}}
    static let preferencesDomain="com.grahamgilbert.Watt"
    static func migrateLegacyAppearance(_ legacy:[String:Any],to defaults:UserDefaults) {
        guard !defaults.bool(forKey:"migration.prototypeAppearance") else {return}
        for (key,value) in legacy where key.hasPrefix("menu.") {
            if defaults.object(forKey:key) == nil {defaults.set(value,forKey:key)}
        }
        defaults.set(true,forKey:"migration.prototypeAppearance")
    }
    init(defaults suppliedDefaults:UserDefaults? = nil) {
        let defaults:UserDefaults
        if let suppliedDefaults {defaults=suppliedDefaults}
        else if Bundle.main.bundleIdentifier == Self.preferencesDomain {defaults = .standard}
        else {defaults=UserDefaults(suiteName:Self.preferencesDomain)!}
        if suppliedDefaults == nil {
            Self.migrateLegacyAppearance(UserDefaults.standard.persistentDomain(forName:"dev.watt.local") ?? [:],to:defaults)
        }
        self.defaults=defaults
        let stored=defaults.double(forKey:"menu.width")
        width=[40.0,48,52,64,80].contains(stored) ? stored : 52
        let layouts=["Ribbon","Numeric"]
        let metrics=["CPU","Memory","Network","Battery power"]
        let layout=defaults.string(forKey:"menu.layout") ?? "Ribbon"
        let primary=defaults.string(forKey:"menu.primary") ?? "CPU"
        let secondary=defaults.string(forKey:"menu.secondary") ?? "Memory"
        self.layout=layouts.contains(layout) ? layout : "Ribbon"
        self.primary=metrics.contains(primary) ? primary : "CPU"
        self.secondary=metrics.contains(secondary) ? secondary : "Memory"
        network=defaults.object(forKey:"menu.network") as? Bool ?? true
        networkNumbers=defaults.object(forKey:"menu.networkNumbers") as? Bool ?? true
        color=defaults.bool(forKey:"menu.color")
        let storedStyle=defaults.string(forKey:"menu.graphStyle") ?? "Meter"
        graphStyle=["Meter","Bars","Lines"].contains(storedStyle) ? storedStyle : "Meter"
        metricNumbers=defaults.object(forKey:"menu.metricNumbers") as? Bool ?? true
        if width<52 && network && networkNumbers && metricNumbers && self.layout == "Ribbon" {width=52}
    }
}

struct PreferencesView:View {
    var viewportHeight:CGFloat=680
    @ObservedObject var settings:MenuBarSettings
    @ObservedObject var monitor:Monitor
    @ObservedObject var updater:AppUpdater
    @ObservedObject var popupLayout:PopupLayoutSettings
    var energyCollector:EnergyImpactCollector?=nil
    var layoutPresenter:PopupLayoutEditorPresenter?=nil
    var loginItems:LoginItemManager?=nil
    @StateObject private var layoutEditor=PopupLayoutEditorPresenter()
    var body:some View {
        Form {
            Section("General") {
                if let loginItems {LoginItemControls(manager:loginItems)}
                Picker("Sample interval",selection:$monitor.interval) {
                    Text("2 seconds").tag(2.0);Text("5 seconds").tag(5.0);Text("10 seconds").tag(10.0)
                }
                Text("Shorter intervals capture more detail and use more storage.").font(.caption).foregroundStyle(.secondary)
                Toggle("Record bandwidth per process",isOn:$monitor.recordsProcessNetwork)
                    .accessibilityIdentifier("recording.processNetwork")
                Text("Keep received and sent byte counts for later inspection. Connection addresses and payloads are not recorded.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar appearance") {
                HStack {
                    Text("Live preview · 2×").foregroundStyle(.secondary)
                    Spacer()
                    MenuBarPreview(settings:settings,frames:monitor.frames).frame(width:settings.width,height:24).scaleEffect(2).frame(width:settings.width*2,height:48)
                }.padding(.vertical,4)
                Picker("Layout",selection:$settings.layout) {Text("Ribbon").tag("Ribbon");Text("Two-line numbers").tag("Numeric")}
                Picker("Graphs",selection:$settings.graphStyle) {Text("Simple meters").tag("Meter");Text("History bars").tag("Bars");Text("History lines").tag("Lines")}.disabled(settings.layout == "Numeric")
                Picker("Width",selection:$settings.width) {ForEach([40.0,48,52,64,80],id:\.self){Text("\(Int($0)) pt").tag($0).disabled($0<52 && settings.metricNumbers && settings.networkNumbers && settings.network && settings.layout == "Ribbon")}}
                metricPicker("Upper row",$settings.primary)
                metricPicker("Lower row",$settings.secondary)
                Toggle("Network lanes",isOn:$settings.network).disabled(settings.layout == "Numeric")
                Toggle("Upload / download rates",isOn:$settings.networkNumbers).disabled(!settings.network || settings.layout == "Numeric")
                Toggle("CPU / memory percentages",isOn:$settings.metricNumbers).disabled(settings.layout == "Numeric")
                Toggle("Color",isOn:$settings.color)
                Text("C = CPU, M = memory. Used RAM excludes reclaimable cache. K/M/G mean KiB/s, MiB/s and GiB/s.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Popup layout") {
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text("\(popupLayout.visibleEntries.count) tiles · \(popupLayout.columnCount) columns")
                        Text("Reorder, show or hide tiles, and choose their width.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit layout…") {(layoutPresenter ?? layoutEditor).show(layout:popupLayout,monitor:monitor)}
                }
                Picker("Energy tile summary",selection:$popupLayout.energySummary) {
                    ForEach(PopupLayoutSettings.energySummaryOptions,id:\.self) {Text($0).tag($0)}
                }.accessibilityIdentifier("popup.layout.energy-summary")
            }
            if let energyCollector {
                Section("Energy Impact") {EnergyCollectorControls(collector:energyCollector,interval:monitor.interval)}
            }
            Section("Updates") {UpdateControls(updater:updater)}
        }.formStyle(.grouped).frame(width:520,height:viewportHeight)
        .onChange(of:settings.metricNumbers) {_,_ in enforceReadableWidth()}
        .onChange(of:settings.networkNumbers) {_,_ in enforceReadableWidth()}
        .onChange(of:settings.network) {_,_ in enforceReadableWidth()}
        .onChange(of:settings.layout) {_,_ in enforceReadableWidth()}
    }
    private func enforceReadableWidth() {if settings.width<52 && settings.layout == "Ribbon" && settings.network && settings.networkNumbers && settings.metricNumbers {settings.width=52}}
    private func metricPicker(_ title:String,_ binding:Binding<String>)->some View {
        Picker(title,selection:binding) {ForEach(["CPU","Memory","Network","Battery power"],id:\.self){Text($0).tag($0)}}
    }
}

private struct LoginItemControls:View {
    @ObservedObject var manager:LoginItemManager
    var body:some View {
        Toggle("Open at login",isOn:Binding(get:{manager.isEnabled},set:{manager.setEnabled($0)}))
            .disabled(!manager.isAvailable)
            .accessibilityIdentifier("preferences.openAtLogin")
        if !manager.isAvailable {
            Text("Available in signed app builds.").font(.caption).foregroundStyle(.secondary)
        } else if manager.needsApproval {
            HStack {
                Text("Allow Watt in macOS Login Items to open at login.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("System Settings…") {manager.openSettings()}.controlSize(.small)
            }
        }
        if let error=manager.lastError {
            Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
                .accessibilityIdentifier("preferences.openAtLogin.error")
        }
    }
}

private struct EnergyCollectorControls:View {
    @ObservedObject var collector:EnergyImpactCollector
    let interval:Double
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text(collector.status).font(.caption).foregroundStyle(collector.lastError == nil ? Color.secondary : .orange)
                .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("energy.collector.status")
            if let error=collector.processMetricsError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
                Button("Reinstall collector…") {collector.reinstall()}.controlSize(.small).disabled(!collector.isSignedBuild)
            }
            HStack {
                if collector.needsApproval {
                    Button("Approve in System Settings…") {collector.requestApproval()}.buttonStyle(.borderedProminent)
                        .disabled(!collector.isSignedBuild)
                        .accessibilityIdentifier("energy.collector.approve")
                } else if collector.isInstalled {
                    if !collector.isRunning {
                        Button("Start collection") {collector.start(interval:interval)}.disabled(!collector.isSignedBuild)
                            .accessibilityIdentifier("energy.collector.start")
                    }
                } else {
                    Button("Install collector…") {collector.install()}.disabled(!collector.isSignedBuild)
                        .accessibilityIdentifier("energy.collector.install")
                }
                if collector.isInstalled || collector.needsApproval {
                    Button("Remove collector",role:.destructive) {collector.unregister()}
                        .accessibilityIdentifier("energy.collector.remove")
                }
                Spacer(minLength:0)
                Button("Refresh") {collector.refreshStatus()}.accessibilityIdentifier("energy.collector.refresh")
            }.controlSize(.small)
            if let date=collector.lastSampleDate {
                HStack {Text("Last sample");Spacer();Text(date,style:.time).monospacedDigit()}.font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear {collector.refreshStatus()}
    }
}

struct MenuBarPreview:NSViewRepresentable {
    @ObservedObject var settings:MenuBarSettings
    var frames:[Frame]
    func makeNSView(context:Context)->Ribbon {let view=Ribbon(frame:NSRect(x:0,y:0,width:settings.width,height:24));view.settings=settings;view.frames=frames;return view}
    func updateNSView(_ view:Ribbon,context:Context) {view.settings=settings;view.frames=frames;view.needsDisplay=true}
}
