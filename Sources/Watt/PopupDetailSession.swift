import Foundation
import Combine

struct PopupHistorySnapshot {
    var frames:[Frame]
    var gaps:[RecordingGap]
}

final class PopupHistoryRequest:@unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    var isCancelled:Bool {lock.lock();defer {lock.unlock()};return cancelled}
    func cancel() {lock.lock();cancelled=true;lock.unlock()}
}

// A detail owns its cursor and bounded working set. It must not move Explorer's
// cursor or leave a history query retaining rows after the popover has closed.
@MainActor final class PopupDetailSession:ObservableObject {
    typealias Loader=(DateInterval,PopupHistoryRequest,@escaping(Result<PopupHistorySnapshot,Error>)->Void)->Void
    nonisolated static let maximumFrames=450
    nonisolated static let maximumProcessRows=120_000
    @Published private(set) var item:PopupItemID?
    @Published private(set) var selectedTime:Date?
    @Published private(set) var duration=60.0
    @Published private(set) var frames:[Frame]=[]
    @Published private(set) var gaps:[RecordingGap]=[]
    @Published private(set) var isLoading=false
    @Published private(set) var error:String?
    private var request=UUID()
    private var loader:Loader?
    private var work:PopupHistoryRequest?
    private var end:Date?

    func open(_ item:PopupItemID,liveFrames:[Frame],gaps:[RecordingGap],loader:@escaping Loader) {
        reset()
        self.item=item;self.loader=loader;self.gaps=gaps
        end=liveFrames.last?.time
        load(liveFrames:liveFrames)
    }
    func reset() {
        work?.cancel();work=nil
        request=UUID();loader=nil;item=nil;selectedTime=nil;duration=60
        frames=[];gaps=[];end=nil;isLoading=false;error=nil
    }
    func changeDuration(_ value:Double,liveFrames:[Frame],gaps:[RecordingGap]) {
        guard [60.0,300,900].contains(value),value != duration,item != nil else {return}
        duration=value;self.gaps=gaps
        if selectedTime == nil {end=liveFrames.last?.time}
        load(liveFrames:liveFrames)
    }
    func select(_ time:Date?,liveFrames:[Frame],gaps:[RecordingGap]) {
        guard item != nil else {return}
        if let time {
            selectedTime=time
            // Keep the graph's right edge and rows at the same captured window.
            // A pending read still belongs to this anchored window. Pinning
            // must not discard its older samples when that read completes.
        } else {
            selectedTime=nil;self.gaps=gaps;end=liveFrames.last?.time
            load(liveFrames:liveFrames)
        }
    }
    func observe(_ frame:Frame,gaps:[RecordingGap]) {
        guard item != nil,selectedTime == nil else {return}
        end=frame.time;self.gaps=gaps
        frames=Self.retaining(Self.merged(frames,[frame]),endingAt:frame.time,duration:duration)
    }
    private func load(liveFrames:[Frame]) {
        work?.cancel();work=nil
        let token=UUID();request=token;error=nil
        guard let end,let loader else {frames=[];isLoading=false;return}
        let range=DateInterval(start:end.addingTimeInterval(-duration),end:end)
        let available=Self.retaining(Self.merged(frames,liveFrames),endingAt:end,duration:duration)
        frames=available
        let first=available.first
        let tolerance=max(1,first?.cadence ?? first?.elapsed ?? 5)
        // The live buffer often contains the entire minute already. Opening a
        // tile then needs neither a database read nor another collector request.
        if let first,first.time.timeIntervalSince(range.start)<=tolerance {isLoading=false;return}
        isLoading=true
        let work=PopupHistoryRequest();self.work=work
        loader(range,work) { [weak self] result in
            guard !work.isCancelled,let self,self.request==token,self.item != nil else {return}
            self.work=nil
            self.isLoading=false
            switch result {
            case .success(let snapshot):
                guard let latestEnd=self.end else {return}
                self.frames=Self.retaining(Self.merged(snapshot.frames,self.frames),endingAt:latestEnd,duration:self.duration)
                var gaps=Dictionary(snapshot.gaps.map {($0.id,$0)},uniquingKeysWith:{$1})
                for gap in self.gaps {
                    if let previous=gaps[gap.id] {
                        var merged=gap
                        merged.end=[previous.end,gap.end].compactMap {$0}.max()
                        gaps[gap.id]=merged
                    } else {gaps[gap.id]=gap}
                }
                self.gaps=gaps.values.sorted {$0.start<$1.start}
            case .failure(let error):self.error=error.localizedDescription
            }
        }
    }
    private static func merged(_ older:[Frame],_ newer:[Frame])->[Frame] {
        var keyed=Dictionary(older.map {($0.time,$0)},uniquingKeysWith:{$1})
        for frame in newer {keyed[frame.time]=frame}
        return keyed.values.sorted {$0.time<$1.time}
    }
    private static func retaining(_ frames:[Frame],endingAt end:Date,duration:Double)->[Frame] {
        var result=frames.filter {$0.time>=end.addingTimeInterval(-duration) && $0.time<=end}
        var rows=result.reduce(0) {$0+rowCost($1)},remove=0
        while result.count-remove>1 && (result.count-remove>maximumFrames || rows>maximumProcessRows) {
            rows-=rowCost(result[remove]);remove+=1
        }
        if remove>0 {result.removeFirst(remove)}
        return result
    }
    nonisolated static func rowCost(_ frame:Frame)->Int {
        frame.processes.count+(frame.processNetwork?.tasks.count ?? 0)+(frame.energyImpact?.tasks.count ?? 0)
    }
}
