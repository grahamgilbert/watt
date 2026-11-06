import XCTest
@testable import Watt

final class HistoryEfficiencyTests:XCTestCase {
    private func frame(_ date:Date)->Frame {
        Frame(time:date,cpu:20,memory:1024,compressed:0,swap:0,download:0,upload:0,processes:[ProcessRow(pid:42,parent:1,start:3,name:String(repeating:"build",count:300),cpu:nil,memory:1024,growth:nil,read:nil,written:nil)],denied:0)
    }
    private func withPath(_ body:(String)throws->Void) throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        try body(directory.appendingPathComponent("history.sqlite").path)
    }
    func testBoundedRecentReadsKeepFullTimelineAvailable() throws {
        try withPath {path in
            let store=try HistoryStore(path:path,freeBytes:{Int64.max}),now=Date(timeIntervalSince1970:1_800_000_000)
            let values=(0..<10).map {frame(now.addingTimeInterval(Double($0)))}
            for value in values {try store.append(value,now:now)}
            let budget=Int64(try JSONEncoder().encode(values[9]).count)
            XCTAssertEqual(try store.recent(maximumBytes:budget).map(\.time),[values[9].time])
            XCTAssertEqual(try store.recent(maximumBytes:0).count,0)
            XCTAssertEqual(try store.frames(in:DateInterval(start:now,end:now.addingTimeInterval(9))).count,10)
            let bounds=try XCTUnwrap(store.bounds())
            XCTAssertEqual(bounds.start.timeIntervalSince1970,now.timeIntervalSince1970,accuracy:0.000001)
            XCTAssertEqual(bounds.end.timeIntervalSince1970,now.addingTimeInterval(9).timeIntervalSince1970,accuracy:0.000001)
        }
    }
    func testGapCacheTracksCloseRetentionAndAnotherConnection() throws {
        try withPath {path in
            let store=try HistoryStore(path:path,policy:HistoryPolicy(retention:60,minimumFreeBytes:0)),now=Date(timeIntervalSince1970:1_800_000_000)
            XCTAssertTrue(try store.gaps().isEmpty)
            let id=try store.beginGap(at:now.addingTimeInterval(-100),reason:"sleep")
            XCTAssertNil(try store.gaps().first?.end)
            try store.closeGap(id,at:now.addingTimeInterval(-90))
            XCTAssertEqual(try store.gaps().first?.end,now.addingTimeInterval(-90))
            try store.append(frame(now),now:now)
            XCTAssertTrue(try store.gaps().isEmpty)
            let other=try HistoryStore(path:path)
            _=try other.beginGap(at:now,reason:"external writer")
            XCTAssertEqual(try store.gaps().first?.reason,"external writer")
        }
    }
    func testStartupRestoresOnlyRecentFramesWithoutDiscardingRecordedDetail() throws {
        try withPath {path in
            let store=try HistoryStore(path:path,freeBytes:{Int64.max}),now=Date(timeIntervalSince1970:1_800_000_000)
            for index in 0..<80 {try store.append(frame(now.addingTimeInterval(Double(index))),now:now)}
            let backend=RecorderBackend();backend.store=store
            let restored=try backend.restore()
            XCTAssertEqual(restored.0.count,36)
            XCTAssertEqual(restored.0.last?.time,now.addingTimeInterval(79))
            XCTAssertEqual(try store.frames(in:DateInterval(start:now,end:now.addingTimeInterval(79))).count,80)
        }
    }
}
