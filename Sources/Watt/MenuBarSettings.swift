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
    init(defaults:UserDefaults = .standard) {
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

struct MenuBarSettingsView:View {
    @ObservedObject var settings:MenuBarSettings
    @ObservedObject var monitor:Monitor
    var back:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Button(action:back){Image(systemName:"chevron.left")};Text("Menu bar appearance").font(.title3.weight(.semibold))}
            HStack {
                Text("Live preview · 2×").font(.caption).foregroundStyle(.secondary)
                Spacer()
                MenuBarPreview(settings:settings,frames:monitor.frames).frame(width:settings.width,height:24).scaleEffect(2).frame(width:settings.width*2,height:48)
            }.padding(.vertical,6)
            Picker("Layout",selection:$settings.layout) {Text("Ribbon").tag("Ribbon");Text("Two-line numbers").tag("Numeric")}
            Picker("Graphs",selection:$settings.graphStyle) {Text("Simple meters").tag("Meter");Text("History bars").tag("Bars");Text("History lines").tag("Lines")}.disabled(settings.layout == "Numeric")
            Picker("Width",selection:$settings.width) {ForEach([40.0,48,52,64,80],id:\.self){Text("\(Int($0)) pt").tag($0).disabled($0<52 && settings.metricNumbers && settings.networkNumbers && settings.network && settings.layout == "Ribbon")}}
            metricPicker("Upper row",$settings.primary)
            metricPicker("Lower row",$settings.secondary)
            Toggle("Show network direction lanes",isOn:$settings.network).disabled(settings.layout == "Numeric")
            Toggle("Show upload/download rates",isOn:$settings.networkNumbers).disabled(!settings.network || settings.layout == "Numeric")
            Toggle("Show CPU / memory percentages",isOn:$settings.metricNumbers).disabled(settings.layout == "Numeric")
            Toggle("Use color",isOn:$settings.color)
            Text("Changes apply immediately and persist across launches. Memory shows estimated used RAM. Network graphs use a logarithmic scale; battery graphs span 0–30 W. Unsupported readings use a dash.").font(.caption).foregroundStyle(.secondary)
            Text("GPU and temperature channels will become available with their collectors.").font(.caption).foregroundStyle(.secondary)
            Text("Network overlay: ↓ download, ↑ upload. K/M/G mean KiB/s, MiB/s and GiB/s. Values update at the recording cadence.").font(.caption).foregroundStyle(.secondary)
            Text("Numbers keep a steady color, with graphs beneath them. Hide values for full-height graphs. C identifies CPU and M identifies memory; both show percentages. Color uses mint for CPU and purple for memory. All three numeric channels require at least 52 pt; 64 pt gives the graphs more room.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width:380)
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

struct MenuBarPreview:NSViewRepresentable {
    @ObservedObject var settings:MenuBarSettings
    var frames:[Frame]
    func makeNSView(context:Context)->Ribbon {let view=Ribbon(frame:NSRect(x:0,y:0,width:settings.width,height:24));view.settings=settings;view.frames=frames;return view}
    func updateNSView(_ view:Ribbon,context:Context) {view.settings=settings;view.frames=frames;view.needsDisplay=true}
}
