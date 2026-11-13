import Foundation
import Combine

// This working set belongs to an open Explorer, not the background recorder.
// Fill it once from SQLite, then follow incoming samples without querying again.
@MainActor final class ExplorerLiveHistory:ObservableObject {
    typealias Loader=(DateInterval,PopupHistoryRequest,@escaping(Result<PopupHistorySnapshot,Error>)->Void)->Void
    nonisolated static let maximumFrames=1500
    nonisolated static let maximumBytes:Int64=96*1024*1024
    // Includes process, Energy Impact and network rows. A quarter-hour at the
    // observed ~1,000-process workload fits without enlarging the recorder cache.
    nonisolated static let maximumRows=250_000
    @Published private(set) var frames:[Frame]=[]
    @Published private(set) var gaps:[RecordingGap]=[]
    @Published private(set) var range:DateInterval?
    @Published private(set) var isLoading=false
    @Published private(set) var error:String?
    private(set) var isVisible=false
    private(set) var isComplete=false
    private var duration=900.0
    private var loader:Loader?
    private var work:PopupHistoryRequest?
    private var request=UUID()

    func show(duration:Double,liveFrames:[Frame],gaps:[RecordingGap],loader:@escaping Loader) {
        guard duration.isFinite,duration>0 else {return}
        self.loader=loader
        if isVisible {
            changeDuration(duration,liveFrames:liveFrames,gaps:gaps)
            return
        }
        isVisible=true;self.duration=duration;self.gaps=gaps
        if let end=liveFrames.last?.time {
            let range=DateInterval(start:end.addingTimeInterval(-duration),end:end)
            self.range=range;self.gaps=Self.mergedGaps([],gaps,in:range)
            frames=Self.merged([],liveFrames,in:range)
            load()
        }
    }
    func hide() {
        work?.cancel();work=nil;request=UUID();loader=nil
        isVisible=false;isComplete=false;frames=[];gaps=[];range=nil;isLoading=false;error=nil
    }
    func changeDuration(_ value:Double,liveFrames:[Frame],gaps:[RecordingGap]) {
        guard isVisible,value.isFinite,value>0,value != duration else {return}
        let previous=duration;duration=value
        guard let end=liveFrames.last?.time ?? range?.end else {return}
        let range=DateInterval(start:end.addingTimeInterval(-value),end:end)
        self.range=range;self.gaps=Self.mergedGaps(self.gaps,gaps,in:range)
        frames=Self.merged(frames,liveFrames,in:range)
        // Shrinking a fully loaded interval needs no second disk read.
        if value<previous,isComplete,error==nil {return}
        load()
    }
    func observe(_ frame:Frame,gaps:[RecordingGap]) {
        guard isVisible else {return}
        let first=range==nil
        let range=DateInterval(start:frame.time.addingTimeInterval(-duration),end:frame.time)
        self.range=range;self.gaps=Self.mergedGaps(self.gaps,gaps,in:range)
        // A failed wide request must remain visibly unavailable, rather than
        // slowly turning back into an apparently complete trailing suffix.
        guard error==nil else {return}
        let merged=Self.merged(frames,[frame],in:range)
        guard Self.fits(merged) else {fail(HistoryQueryError.tooBroad);return}
        frames=merged
        if first {load()}
    }
    private func load() {
        work?.cancel();work=nil;request=UUID();isComplete=false;error=nil
        guard let range,let loader else {isLoading=false;return}
        let request=self.request,work=PopupHistoryRequest();self.work=work;isLoading=true
        loader(range,work) { [weak self] result in
            guard !work.isCancelled,let self,self.isVisible,self.request==request,let range=self.range else {return}
            self.work=nil;self.isLoading=false
            switch result {
            case .success(let snapshot):
                let merged=Self.merged(snapshot.frames,self.frames,in:range)
                guard Self.fits(merged) else {self.fail(HistoryQueryError.tooBroad);return}
                self.frames=merged
                self.gaps=Self.mergedGaps(snapshot.gaps,self.gaps,in:range)
                self.isComplete=true
            case .failure(let error):self.fail(error)
            }
        }
    }
    private func fail(_ error:Error) {
        work?.cancel();work=nil;request=UUID();isLoading=false;isComplete=false;frames=[]
        self.error="Live history: \(error.localizedDescription)"
    }
    private static func merged(_ older:[Frame],_ newer:[Frame],in range:DateInterval)->[Frame] {
        var keyed=Dictionary(older.filter {$0.time>=range.start && $0.time<=range.end}.map {($0.time,$0)},uniquingKeysWith:{$1})
        for frame in newer where frame.time>=range.start && frame.time<=range.end {keyed[frame.time]=frame}
        return keyed.values.sorted {$0.time<$1.time}
    }
    private static func mergedGaps(_ older:[RecordingGap],_ newer:[RecordingGap],in range:DateInterval)->[RecordingGap] {
        var keyed=Dictionary(older.map {($0.id,$0)},uniquingKeysWith:{$1})
        for gap in newer {keyed[gap.id]=gap}
        return keyed.values.filter {$0.start<range.end && ($0.end ?? .distantFuture)>range.start}.sorted {$0.start<$1.start}
    }
    nonisolated static func fits(_ frames:[Frame])->Bool {
        guard frames.count<=maximumFrames else {return false}
        var rows=0
        for frame in frames {
            rows+=PopupDetailSession.rowCost(frame)
            if rows>maximumRows {return false}
        }
        return true
    }
}
