import Foundation
import Combine

enum PopupItemID:String,CaseIterable,Codable,Identifiable {
    case cpu,memory,download,upload,batteryFlow,cpuProcesses,processCPUPower,applicationCPUPower,energyImpact,diskRead,diskWrite,memoryDetail
    var id:String {rawValue}
    var title:String {
        switch self {
        case .cpu:return "CPU"
        case .memory:return "Memory"
        case .download:return "Download"
        case .upload:return "Upload"
        case .batteryFlow:return "Battery flow"
        case .cpuProcesses:return "CPU processes"
        case .processCPUPower:return "Process CPU power"
        case .applicationCPUPower:return "Applications CPU power"
        case .energyImpact:return "Process Energy Impact"
        case .diskRead:return "Process disk reads"
        case .diskWrite:return "Process disk writes"
        case .memoryDetail:return "Memory details"
        }
    }
    var detail:String {
        switch self {
        case .cpu:return "Machine capacity and recent history"
        case .memory:return "Used RAM with reclaimable cache excluded"
        case .download:return "Incoming traffic · shared network scale"
        case .upload:return "Outgoing traffic · shared network scale"
        case .batteryFlow:return "Estimated electrical flow at the battery"
        case .cpuProcesses:return "Processes ranked by CPU, per core"
        case .processCPUPower:return "Estimated CPU watts for individual processes"
        case .applicationCPUPower:return "CPU watts grouped across observed app helpers"
        case .energyImpact:return "Apple’s relative process energy score"
        case .diskRead:return "Observed process reads, not total disk I/O"
        case .diskWrite:return "Observed process writes, not total disk I/O"
        case .memoryDetail:return "Compressed memory and swap history"
        }
    }
}

enum PopupTileSpan:String,Codable,CaseIterable {case square,fullWidth}
struct PopupLayoutEntry:Codable,Equatable,Identifiable {
    var id:PopupItemID
    var visible:Bool
    var span:PopupTileSpan
}
struct PopupLayoutRow:Identifiable,Equatable {
    var entries:[PopupLayoutEntry]
    var id:String {entries.map(\.id.rawValue).joined(separator:"+")}
}

@MainActor final class PopupLayoutSettings:ObservableObject {
    static let storageKey="popup.layout.v1"
    private let defaults:UserDefaults
    @Published private(set) var entries:[PopupLayoutEntry]
    @Published var columnCount:Int {
        didSet {
            let bounded=min(6,max(2,columnCount))
            if columnCount != bounded {columnCount=bounded;return}
            persist()
        }
    }
    private struct StoredEntry:Codable {var id:String;var visible:Bool;var span:String}
    private struct StoredLayout:Codable {var version:Int;var entries:[StoredEntry];var columnCount:Int?}
    static var defaultEntries:[PopupLayoutEntry] {
        let visible:Set<PopupItemID>=[.cpu,.memory,.download,.upload,.batteryFlow,.processCPUPower,.energyImpact]
        let order:[PopupItemID]=[.cpu,.memory,.download,.upload,.batteryFlow,.processCPUPower,.energyImpact,.cpuProcesses,.diskRead,.diskWrite,.memoryDetail,.applicationCPUPower]
        return order.map {PopupLayoutEntry(id:$0,visible:visible.contains($0),span:.square)}
    }
    init(defaults suppliedDefaults:UserDefaults? = nil) {
        if let suppliedDefaults {defaults=suppliedDefaults}
        else if Bundle.main.bundleIdentifier == MenuBarSettings.preferencesDomain {defaults = .standard}
        else {defaults=UserDefaults(suiteName:MenuBarSettings.preferencesDomain)!}
        if let data=defaults.data(forKey:Self.storageKey),let stored=try? JSONDecoder().decode(StoredLayout.self,from:data),stored.version==1 {
            var seen=Set<PopupItemID>()
            let restored=stored.entries.compactMap {entry->PopupLayoutEntry? in
                guard let id=PopupItemID(rawValue:entry.id),seen.insert(id).inserted else {return nil}
                return PopupLayoutEntry(id:id,visible:entry.visible,span:PopupTileSpan(rawValue:entry.span) ?? .square)
            }
            // Newly introduced tiles stay in the palette for an existing saved layout.
            entries=restored+Self.defaultEntries.filter {!seen.contains($0.id)}.map {PopupLayoutEntry(id:$0.id,visible:false,span:$0.span)}
            columnCount=min(6,max(2,stored.columnCount ?? 2))
        } else {entries=Self.defaultEntries;columnCount=2}
    }
    var visibleEntries:[PopupLayoutEntry] {entries.filter(\.visible)}
    // The palette is a catalog of available sources, never a second ordering surface.
    var availableEntries:[PopupLayoutEntry] {PopupItemID.allCases.compactMap {id in entries.first(where:{$0.id==id && !$0.visible})}}
    var rows:[PopupLayoutRow] {Self.pack(visibleEntries,columnCount:columnCount)}
    func contentWidth(tileSide:CGFloat=160,spacing:CGFloat=12)->CGFloat {
        CGFloat(columnCount)*tileSide+CGFloat(columnCount-1)*spacing
    }
    func contentHeight(tileSide:CGFloat=160,spacing:CGFloat=12)->CGFloat {
        rows.isEmpty ? 80 : CGFloat(rows.count)*tileSide+CGFloat(max(0,rows.count-1))*spacing
    }
    // A full-width tile starts its own row; hidden entries consume no cells.
    static func pack(_ entries:[PopupLayoutEntry],columnCount:Int=2)->[PopupLayoutRow] {
        let columns=min(6,max(2,columnCount))
        var result:[PopupLayoutRow]=[],pending:[PopupLayoutEntry]=[]
        for entry in entries where entry.visible {
            if entry.span == .fullWidth {
                if !pending.isEmpty {result.append(PopupLayoutRow(entries:pending));pending=[]}
                result.append(PopupLayoutRow(entries:[entry]))
            } else {
                pending.append(entry)
                if pending.count==columns {result.append(PopupLayoutRow(entries:pending));pending=[]}
            }
        }
        if !pending.isEmpty {result.append(PopupLayoutRow(entries:pending))}
        return result
    }
    func setVisible(_ visible:Bool,for id:PopupItemID) {
        guard let index=entries.firstIndex(where:{$0.id==id}) else {return}
        entries[index].visible=visible;persist()
    }
    func setSpan(_ span:PopupTileSpan,for id:PopupItemID) {
        guard let index=entries.firstIndex(where:{$0.id==id}) else {return}
        entries[index].span=span;persist()
    }
    func move(_ id:PopupItemID,before target:PopupItemID?) {
        guard id != target,let source=entries.firstIndex(where:{$0.id==id}) else {return}
        if let target,!entries.contains(where:{$0.id==target}) {return}
        let entry=entries.remove(at:source)
        let destination=target.flatMap {target in entries.firstIndex(where:{$0.id==target})} ?? entries.endIndex
        entries.insert(entry,at:destination);persist()
    }
    func move(_ id:PopupItemID,by offset:Int) {
        guard let source=entries.firstIndex(where:{$0.id==id}) else {return}
        let destination=min(entries.count-1,max(0,source+offset))
        guard source != destination else {return}
        let entry=entries.remove(at:source);entries.insert(entry,at:destination);persist()
    }
    func move(_ id:PopupItemID,toPositionOf target:PopupItemID) {
        guard let source=entries.firstIndex(where:{$0.id==id}),let destination=entries.firstIndex(where:{$0.id==target}) else {return}
        move(id,by:destination-source)
    }
    func place(_ id:PopupItemID,atVisibleIndex index:Int) {
        guard let source=entries.firstIndex(where:{$0.id==id}) else {return}
        var entry=entries.remove(at:source)
        entry.visible=true
        let visible=entries.filter(\.visible)
        let destination=min(visible.count,max(0,index))
        let insertion:Int
        if destination<visible.count {insertion=entries.firstIndex(where:{$0.id==visible[destination].id})!}
        else if let last=visible.last,let lastIndex=entries.firstIndex(where:{$0.id==last.id}) {insertion=lastIndex+1}
        else {insertion=entries.endIndex}
        entries.insert(entry,at:insertion);persist()
    }
    func place(_ id:PopupItemID,atPositionOf target:PopupItemID) {
        guard id != target,let index=visibleEntries.firstIndex(where:{$0.id==target}) else {return}
        place(id,atVisibleIndex:index)
    }
    func moveVisible(_ id:PopupItemID,by offset:Int) {
        guard let index=visibleEntries.firstIndex(where:{$0.id==id}) else {return}
        place(id,atVisibleIndex:min(visibleEntries.count-1,max(0,index+offset)))
    }
    func reset() {entries=Self.defaultEntries;columnCount=2;persist()}
    private func persist() {
        let stored=StoredLayout(version:1,entries:entries.map {StoredEntry(id:$0.id.rawValue,visible:$0.visible,span:$0.span.rawValue)},columnCount:columnCount)
        if let data=try? JSONEncoder().encode(stored) {defaults.set(data,forKey:Self.storageKey)}
    }
}
