import XCTest
@testable import Watt

final class LiveFrameRetentionTests:XCTestCase {
    private func frame(_ offset:Double,processes:Int)->Frame {
        let row=ProcessRow(pid:1,parent:0,start:1,name:"fixture",cpu:1,memory:1024,growth:nil,read:nil,written:nil)
        return Frame(time:Date(timeIntervalSince1970:1_800_000_000+offset),cpu:10,memory:1024,compressed:0,swap:0,download:0,upload:0,processes:Array(repeating:row,count:processes),denied:0)
    }
    func testLongRunningLiveCacheBoundsInventoryAndKeepsNewestWholeSamples() {
        var frames:[Frame]=[]
        for index in 0..<720 {frames=LiveFrameRetention.appending(frame(Double(index),processes:1000),to:frames)}
        XCTAssertEqual(frames.count,50)
        XCTAssertEqual(frames.first?.time,frame(670,processes:0).time)
        XCTAssertEqual(frames.last?.processes.count,1000)
        var small:[Frame]=[]
        for index in 0..<720 {small=LiveFrameRetention.appending(frame(Double(index),processes:1),to:small)}
        XCTAssertEqual(small.count,120)
    }
    func testSingleLargeSnapshotIsRetainedIntact() {
        let latest=frame(2,processes:50_001)
        let frames=LiveFrameRetention.appending(latest,to:[frame(1,processes:1)])
        XCTAssertEqual(frames.count,1)
        XCTAssertEqual(frames[0].processes.count,50_001)
    }
}
