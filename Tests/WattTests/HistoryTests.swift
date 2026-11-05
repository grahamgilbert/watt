import XCTest
@testable import Watt
final class HistoryTests:XCTestCase {
    func testCounterResetIsNotARate() { XCTAssertNil(delta(4,10));XCTAssertEqual(delta(15,10),5) }
    func testPIDReuseHasDifferentIdentity() {
        let a=ProcessRow(pid:42,parent:1,start:1,name:"first",cpu:nil,memory:100,growth:nil,read:nil,written:nil)
        var b=a;b.start=2
        XCTAssertNotEqual(a.id,b.id)
    }
    func testHistoryRoundTripPreservesUnavailableCounters() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { for suffix in ["","-wal","-shm"] {try? FileManager.default.removeItem(atPath:path.path+suffix)} }
        let store=try HistoryStore(path:path.path)
        let row=ProcessRow(pid:42,parent:1,start:3,name:"build",cpu:nil,memory:1024,growth:nil,read:nil,written:nil)
        let frame=Frame(time:Date(),cpu:20,memory:1024,compressed:0,swap:0,download:0,upload:0,processes:[row],denied:2)
        try store.append(frame)
        let restored=try XCTUnwrap(store.recent().first)
        XCTAssertEqual(restored.processes.first?.id,row.id);XCTAssertNil(restored.processes.first?.cpu);XCTAssertEqual(restored.denied,2)
    }
}
