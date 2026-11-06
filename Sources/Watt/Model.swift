import Foundation
import Combine
import AppKit
import CTelemetry

struct ProcessRow: Identifiable, Codable {
    var pid: Int32; var parent: Int32; var start: UInt64; var name: String
    var cpu: Double?; var memory: UInt64; var growth: Int64?
    var read: UInt64?; var written: UInt64?
    var id: String { "\(pid):\(start)" }
}
struct Frame: Codable, Identifiable {
    var time: Date; var cpu: Double; var memory: UInt64; var compressed: UInt64; var swap: UInt64
    var download: Double; var upload: Double; var processes: [ProcessRow]; var denied: Int
    var power: PowerReading? = nil
    var segment: String? = nil
    var elapsed: Double? = nil
    var cadence: Double? = nil
    var memoryAccounting: String? = nil
    var id: Date { time }
}
func delta(_ value: UInt64, _ previous: UInt64) -> UInt64? { value >= previous ? value - previous : nil }

final class Collector {
    private(set) var failed = false
    private var previous: WattSystem?
    private var processes: [String: WattProcess] = [:]
    private var last: TimeInterval?
    func sample() -> Frame? {
        failed = false
        var system = WattSystem()
        guard watt_system(&system) != 0 else { failed = true; return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = last.map { now - $0 }
        var buffer = [WattProcess](repeating: WattProcess(), count: 16384)
        var denied: Int32 = 0
        let count = watt_processes(&buffer, Int32(buffer.count), &denied)
        var next: [String: WattProcess] = [:]
        let rows = buffer.prefix(max(0, Int(count))).map { p -> ProcessRow in
            let key = "\(p.pid):\(p.start)"; next[key] = p
            let old = processes[key]
            let cpu = old.flatMap { delta(p.cpu, $0.cpu) }.flatMap { value in elapsed.map { Double(value) / 1e9 / max($0, 0.001) * 100 } }
            var name = p.name
            let label = withUnsafePointer(to: &name) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            return ProcessRow(pid:p.pid,parent:p.parent,start:p.start,name:label,cpu:cpu,memory:p.footprint,
                              growth:old.map { Int64(p.footprint)-Int64($0.footprint) },
                              read:old.flatMap { delta(p.read,$0.read) },written:old.flatMap { delta(p.written,$0.written) })
        }
        var cpu = 0.0, rx = 0.0, tx = 0.0
        if let old = previous, let elapsed, elapsed > 0 {
            let active = Double(delta(system.user, old.user) ?? 0) + Double(delta(system.system, old.system) ?? 0)
            let idle = Double(delta(system.idle, old.idle) ?? 0)
            cpu = active / max(1, active + idle) * 100
            rx = Double(delta(system.rx,old.rx) ?? 0)/elapsed; tx = Double(delta(system.tx,old.tx) ?? 0)/elapsed
        }
        let baseline = previous != nil
        previous=system; processes=next; last=now
        guard baseline else { return nil }
        return Frame(time:Date(),cpu:cpu,memory:system.memory,compressed:system.compressed,swap:system.swap,
                     download:rx,upload:tx,processes:rows,denied:count < 0 ? -1 : Int(denied),power:PowerReading.read(),elapsed:elapsed,memoryAccounting:"app-wired-compressed")
    }
    func reset() { previous=nil; processes=[:]; last=nil }
}

@MainActor final class Monitor: ObservableObject {
    @Published var frames:[Frame]=[]
    @Published var liveFrame:Frame?
    @Published var historyFrames:[Frame]=[]
    @Published var historyRange:DateInterval?
    @Published var historyBounds:DateInterval?
    @Published var historySummaries:[ProcessSummary]=[]
    @Published var historyLoading=false
    @Published var historyError:String?
    private var historyRequest=UUID()
    var visibleFrames:[Frame] {historyRange == nil ? frames : historyFrames}
    @Published var paused=false
    @Published var error:String?
    @Published var interval=5.0
    @Published var selected:Date?
    @Published var gaps:[RecordingGap]=[]
    @Published var storageBytes:Int64=0
    private var sleeping=false
    private var observers:[NSObjectProtocol]=[]
    private let queue=DispatchQueue(label:"app.watt.recorder",qos:.utility)
    private var timer:Timer?
    private var collecting=false
    private nonisolated let backend=RecorderBackend()
    var current:Frame? {
        if let selected {return HistoryAnalysis.snapshot(at:selected,frames:visibleFrames,gaps:gaps)}
        return historyRange == nil ? liveFrame : nil
    }
    func returnToLive() {historyRequest=UUID();historyRange=nil;historyFrames=[];historySummaries=[];selected=nil;historyLoading=false;historyError=nil}
    func loadHistory(center:Date,duration:TimeInterval) {
        let range=DateInterval(start:center.addingTimeInterval(-duration/2),duration:duration)
        let request=UUID();historyRequest=request;historyRange=range;selected=center
        historyFrames=[];historySummaries=[];historyLoading=true;historyError=nil
        queue.async { [self] in
            do {
                guard let store=backend.store else {throw NSError(domain:"Watt",code:1,userInfo:[NSLocalizedDescriptionKey:"History database is unavailable"])}
                let frames=try store.frames(in:range)
                let gaps=try store.gaps()
                let summaries=HistoryAnalysis.summarize(frames,range:range,gaps:gaps)
                let bounds=try store.bounds()
                DispatchQueue.main.async {
                    guard self.historyRequest==request else {return}
                    self.historyFrames=frames;self.historySummaries=summaries;self.historyBounds=bounds
                    self.gaps=gaps;self.historyLoading=false
                }
            } catch {
                DispatchQueue.main.async {guard self.historyRequest==request else {return};self.historyLoading=false;self.historyError=error.localizedDescription}
            }
        }
    }
    init(previewFrames:[Frame]?=nil) {
        if let previewFrames {frames=previewFrames;liveFrame=previewFrames.last;return}
        do {
            let dir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Watt",isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            backend.store=try HistoryStore(path:dir.appendingPathComponent("history.sqlite").path)
            let restored=try backend.restore(); frames=restored.0; gaps=restored.1;historyBounds=try backend.store?.bounds()
        } catch { self.error="History unavailable: \(error.localizedDescription)"; backend.initializationError=self.error }
        let center=NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.setSleeping(true) } })
        observers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.setSleeping(false) } })
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    private var nextSample=Date.distantPast
    private func tick() {
        guard !paused, !sleeping, !collecting, Date() >= nextSample else { return }
        collecting=true; nextSample=Date().addingTimeInterval(interval)
        let cadence=interval
        queue.async { [self] in
            let (frame,failure)=backend.sample(cadence:cadence)
            let gaps=(try? backend.store?.gaps()) ?? []
            let size=backend.store?.diskBytes ?? 0
            DispatchQueue.main.async {
                self.collecting=false
                if let frame { self.liveFrame=frame; self.frames.append(frame); if self.frames.count>720 { self.frames.removeFirst(self.frames.count-720) } }
                self.error=failure; self.gaps=gaps; self.storageBytes=size
            }
        }
    }
    func setPaused(_ value:Bool) {
        guard paused != value else {return}; paused=value
        if value { queue.async { self.backend.interrupt(reason:"Recording paused") } }
        nextSample = .distantPast
    }
    private func setSleeping(_ value:Bool) {
        sleeping=value
        queue.async { self.backend.interrupt(reason:"Device asleep") }
        nextSample = .distantPast
    }
    var visibleGaps:[RecordingGap] {
        let range:DateInterval
        if let historyRange {range=historyRange}
        else if let first=frames.first?.time,let last=frames.last?.time {range=DateInterval(start:first,end:max(first,last))}
        else {return []}
        return gaps.compactMap { gap in
            let start=max(range.start,gap.start),end=min(range.end,gap.end ?? Date())
            guard start<end else {return nil}
            return RecordingGap(id:gap.id,start:start,end:end,reason:gap.reason)
        }
    }
    func selectionGap() -> RecordingGap? { selected.flatMap { time in gaps.first { $0.contains(time) } } }

}

func bytes(_ value:UInt64) -> String { ByteCountFormatter.string(fromByteCount:Int64(clamping:value),countStyle:.binary) }

func diskRate(_ value:UInt64?,elapsed:Double?) -> String {
    guard let value,let elapsed,elapsed>0 else {return "—"}
    return bytes(UInt64(Double(value)/elapsed)) + "/s"
}
