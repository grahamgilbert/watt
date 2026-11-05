import XCTest
import CTelemetry
@testable import Watt

final class RecorderHardeningTests: XCTestCase {
    private func path() -> String { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path }
    private func remove(_ path: String) { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath:path+suffix) } }
    private func frame(_ date: Date, name: String = "build") -> Frame {
        Frame(time:date,cpu:20,memory:1024,compressed:0,swap:0,download:0,upload:0,processes:[ProcessRow(pid:42,parent:1,start:3,name:name,cpu:nil,memory:1024,growth:nil,read:nil,written:nil)],denied:2)
    }
    func testRetentionPrunesExpiredDataButKeepsBoundary() throws {
        let p=path(); defer {remove(p)}
        let store=try HistoryStore(path:p,policy:HistoryPolicy(retention:60,minimumFreeBytes:0))
        let now=Date()
        try store.append(frame(now.addingTimeInterval(-61)),now:now.addingTimeInterval(-61))
        try store.append(frame(now.addingTimeInterval(-60)),now:now)
        try store.append(frame(now),now:now)
        XCTAssertEqual(try store.recent().map(\.time),[now.addingTimeInterval(-60),now])
    }
    func testBudgetPrunesOldestAndBoundsWALAcrossReopen() throws {
        let p=path(); defer {remove(p)}
        let policy=HistoryPolicy(payloadBytes:16_000,databaseBytes:2_000_000,minimumFreeBytes:0)
        let now=Date()
        do {
            let store=try HistoryStore(path:p,policy:policy)
            for i in 0..<100 { try store.append(frame(now.addingTimeInterval(Double(i)),name:String(repeating:"x",count:900)),now:now) }
            XCTAssertLessThanOrEqual(store.payloadBytes,policy.payloadBytes)
            XCTAssertLessThan(try store.recent().count,100)
            XCTAssertEqual(try store.recent().last?.time,now.addingTimeInterval(99))
            try store.checkpoint(); XCTAssertLessThanOrEqual(store.diskBytes,policy.databaseBytes)
        }
        let reopened=try HistoryStore(path:p,policy:policy)
        XCTAssertLessThanOrEqual(reopened.payloadBytes,policy.payloadBytes)
        XCTAssertEqual(try reopened.recent().last?.time,now.addingTimeInterval(99))
    }
    func testDiskReserveFailurePreservesHistoryAndRecovers() throws {
        let p=path(); defer {remove(p)}
        var available:Int64=10_000_000
        let store=try HistoryStore(path:p,policy:HistoryPolicy(minimumFreeBytes:1000),freeBytes:{available})
        let now=Date();try store.append(frame(now))
        available=0
        XCTAssertThrowsError(try store.append(frame(now.addingTimeInterval(1))))
        XCTAssertEqual(try store.recent().count,1)
        available=10_000_000
        try store.append(frame(now.addingTimeInterval(2)))
        XCTAssertEqual(try store.recent().count,2)
    }
    func testGapPersistsAcrossRestartAndDoesNotContainEndpoints() throws {
        let p=path(); defer {remove(p)};let start=Date();var id=""
        do {let store=try HistoryStore(path:p);id=try store.beginGap(at:start,reason:"Device asleep")}
        let store=try HistoryStore(path:p)
        XCTAssertNil(try store.gaps().first?.end)
        try store.closeGap(id,at:start.addingTimeInterval(30))
        let gap=try XCTUnwrap(store.gaps().first)
        XCTAssertTrue(gap.contains(start.addingTimeInterval(15)))
        XCTAssertFalse(gap.contains(start));XCTAssertFalse(gap.contains(start.addingTimeInterval(30)))
    }
    func testOldSchemaMigratesWithoutLosingSamples() throws {
        let p=path();defer {remove(p)};var db:OpaquePointer?
        XCTAssertEqual(sqlite3_open(p,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE frames(time REAL PRIMARY KEY,data BLOB NOT NULL); PRAGMA user_version=1",nil,nil,nil),SQLITE_OK)
        let data=try JSONEncoder().encode(frame(Date()))
        let hex=data.map {String(format:"%02x",$0)}.joined()
        XCTAssertEqual(sqlite3_exec(db,"INSERT INTO frames VALUES(1,x'\(hex)')",nil,nil,nil),SQLITE_OK);sqlite3_close(db)
        let store=try HistoryStore(path:p)
        XCTAssertEqual(try store.recent().count,1);XCTAssertEqual(store.payloadBytes,Int64(data.count))
    }
    func testContinuityDetectsDelayAndClockChangeButAllowsJitter() {
        var continuity=RecordingContinuity();let now=Date()
        XCTAssertNil(continuity.observe(wall:now,elapsed:10,cadence:5))
        XCTAssertNil(continuity.observe(wall:now.addingTimeInterval(5.4),elapsed:15.4,cadence:5))
        XCTAssertEqual(continuity.observe(wall:now.addingTimeInterval(40),elapsed:50,cadence:5),"Sampling delayed")
        XCTAssertEqual(continuity.observe(wall:now.addingTimeInterval(-3600),elapsed:55,cadence:5),"Clock changed or sleep was not observed")
        continuity.reset();XCTAssertNil(continuity.observe(wall:now,elapsed:80,cadence:5))
    }
    func testBatteryWattsAndDirectionRemainDistinctFromACPower() {
        let battery=PowerReading(volts:12.067,amps:-0.509,externalPower:false,sampledAt:Date())
        XCTAssertEqual(battery.watts,-6.142103,accuracy:0.000001)
        XCTAssertEqual(battery.formatted,"6.1 W")
        XCTAssertTrue(battery.label.contains("discharge"))
        let charging=PowerReading(volts:12,amps:1,externalPower:true,sampledAt:Date())
        XCTAssertEqual(charging.watts,12);XCTAssertTrue(charging.label.contains("charging"))
    }
    func testDiskRatesUseMeasuredIntervalAndKeepMissingDistinctFromZero() {
        XCTAssertEqual(diskRate(2048,elapsed:2),"1 KB/s")
        XCTAssertEqual(diskRate(nil,elapsed:2),"—")
        XCTAssertEqual(diskRate(2048,elapsed:nil),"—")
        XCTAssertEqual(diskRate(2048,elapsed:0),"—")
        XCTAssertNotEqual(diskRate(0,elapsed:2),"—")
    }
    func testZeroCurrentOnBatteryIsUnavailableAndInstantCurrentCanRecoverIt() throws {
        var raw:[String:Any]=["Voltage":11928,"Amperage":0,"ExternalConnected":false]
        let missing=try XCTUnwrap(PowerReading.decode(raw))
        XCTAssertEqual(missing.formatted,"Unavailable")
        XCTAssertTrue(missing.sourceDescription.contains("On battery"))
        raw["InstantAmperage"] = -495
        let recovered=try XCTUnwrap(PowerReading.decode(raw))
        XCTAssertEqual(recovered.watts,-5.90436,accuracy:0.00001)
        XCTAssertEqual(recovered.formatted,"5.9 W")
        raw["ExternalConnected"] = true;raw["InstantAmperage"] = 0
        XCTAssertEqual(PowerReading.decode(raw)?.formatted,"0.0 W")
    }
    func testOversizedFrameDoesNotDiscardExistingData() throws {
        let p=path();defer {remove(p)}
        let store=try HistoryStore(path:p,policy:HistoryPolicy(payloadBytes:4000,minimumFreeBytes:0,maximumFrameBytes:2000))
        let now=Date();try store.append(frame(now))
        XCTAssertThrowsError(try store.append(frame(now.addingTimeInterval(1),name:String(repeating:"x",count:5000))))
        XCTAssertEqual(try store.recent().count,1)
    }
}
