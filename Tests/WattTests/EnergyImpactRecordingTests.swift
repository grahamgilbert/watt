import XCTest
import WattEnergyProtocol
@testable import Watt

final class EnergyImpactRecordingTests:XCTestCase {
    func testCaptureIdentityAndTimingSurviveSQLiteAndOldFramesRemainReadable() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let now=Date()
        let process=ProcessRow(pid:42,parent:1,start:UInt64((now.timeIntervalSince1970-100)*1e6),name:"build",cpu:75,memory:1024,growth:nil,read:nil,written:nil)
        let sample=EnergyImpactSample(id:"capture-1",startedAt:now.addingTimeInterval(-2),endedAt:now.addingTimeInterval(-1),tasks:[EnergyImpactTask(pid:42,name:"build",energyImpact:12,energyImpactPerSecond:12,processStartMicroseconds:process.start)])
        var frame=Frame(time:now,cpu:25,memory:1024,compressed:0,swap:0,download:0,upload:0,processes:[process],denied:0,elapsed:5,energyImpact:sample)
        let store=try HistoryStore(path:root.appendingPathComponent("history.sqlite").path,freeBytes:{Int64.max})
        try store.append(frame,now:now)
        frame.time=now.addingTimeInterval(2)
        try store.append(frame,now:frame.time)
        let restored=try store.recent()
        XCTAssertEqual(restored.count,2)
        XCTAssertEqual(Set(restored.compactMap {$0.energyImpact?.id}),["capture-1"])
        let captured=try XCTUnwrap(restored.last?.energyImpact)
        XCTAssertEqual(captured.startedAt.timeIntervalSince1970,sample.startedAt.timeIntervalSince1970,accuracy:0.000001)
        XCTAssertEqual(captured.task(forPID:42,processStart:Date(timeIntervalSince1970:Double(process.start)/1e6),at:frame.time,maximumAge:15)?.energyImpactPerSecond,12)
        XCTAssertNil(captured.task(forPID:42,processStart:now,at:frame.time,maximumAge:15))
        var old=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(frame)) as? [String:Any])
        old.removeValue(forKey:"energyImpact")
        XCTAssertNil(try JSONDecoder().decode(Frame.self,from:JSONSerialization.data(withJSONObject:old)).energyImpact)
    }
}
