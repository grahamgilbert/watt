import Foundation
import XCTest
@testable import Watt

final class ProcessNetworkTests:XCTestCase {
    private let base=Date(timeIntervalSince1970:1_800_000_000)
    private let header=",bytes_in,bytes_out,\n"
    private func input(_ value:String)->Data {Data(value.utf8)}
    private func process(pid:Int32=42,start:Date?=nil,name:String="build")->ProcessRow {
        var row=ProcessRow(pid:pid,parent:1,start:UInt64((start ?? base.addingTimeInterval(-100)).timeIntervalSince1970*1e6),
                           name:name,cpu:nil,memory:nil,growth:nil,read:nil,written:nil)
        row.userID=501;row.applicationID="test.app";row.applicationName="Test App"
        return row
    }
    private func raw(id:String="session:3",start:Date?=nil,end:Date?=nil,tasks:[ProcessNetworkRawTask]?=nil)->ProcessNetworkRawCapture {
        ProcessNetworkRawCapture(id:id,startedAt:start ?? base,endedAt:end ?? base.addingTimeInterval(5),elapsed:5,
                                 tasks:tasks ?? [ProcessNetworkRawTask(pid:42,receivedBytes:500,sentBytes:100)])
    }

    func testDiscardsInitialCumulativeCountersAndPublishesOnlyCompleteDeltaBatch()throws {
        var parser=ProcessNetworkCSVParser(sessionID:"test")
        XCTAssertTrue(try parser.consume(input(header+"app.42,9000,8000,\n"),at:base,uptime:100,cadence:5).isEmpty)
        XCTAssertTrue(try parser.consume(input(header+"app.42,500,100,\n"),at:base.addingTimeInterval(5),uptime:105,cadence:5).isEmpty)
        let samples=try parser.consume(input(header),at:base.addingTimeInterval(10),uptime:110,cadence:5)
        let sample=try XCTUnwrap(samples.first)
        XCTAssertEqual(samples.count,1);XCTAssertEqual(sample.id,"test:2")
        XCTAssertEqual(sample.startedAt,base);XCTAssertEqual(sample.endedAt,base.addingTimeInterval(5))
        XCTAssertEqual(sample.elapsed,5);XCTAssertEqual(sample.tasks,[ProcessNetworkRawTask(pid:42,receivedBytes:500,sentBytes:100)])
    }

    func testPreservesPartialCSVLinesAcrossReadsAndQuotedProcessNames()throws {
        var parser=ProcessNetworkCSVParser()
        _=try parser.consume(input(header+"first.42,1,2,\n"),at:base,uptime:100,cadence:5)
        _=try parser.consume(input(header+"\"comma,quoted.42\",50"),at:base.addingTimeInterval(5),uptime:105,cadence:5)
        _=try parser.consume(input("0,100,\r\n"),at:base.addingTimeInterval(5.01),uptime:105.01,cadence:5)
        let samples=try parser.consume(input(header),at:base.addingTimeInterval(10),uptime:110,cadence:5)
        XCTAssertEqual(samples.first?.tasks.first?.receivedBytes,500)
        XCTAssertEqual(samples.first?.tasks.first?.pid,42)
    }

    func testMeasuredZeroAndUnavailableCountersAreDistinct()throws {
        var parser=ProcessNetworkCSVParser()
        _=try parser.consume(input(header),at:base,uptime:100,cadence:5)
        _=try parser.consume(input(header+"app.42,0,?,\n"),at:base.addingTimeInterval(5),uptime:105,cadence:5)
        let sample=try XCTUnwrap(parser.consume(input(header),at:base.addingTimeInterval(10),uptime:110,cadence:5).first)
        XCTAssertEqual(sample.tasks.first?.receivedBytes,0)
        XCTAssertNil(sample.tasks.first?.sentBytes)
    }

    func testRejectsUnexpectedColumnsRowsAndNegativeOrOverflowedCounters()throws {
        for text in [",bytes_out,bytes_in,\n",",bytes_in,bytes_out,endpoints,\n","app.42,-1,4,\n","app.42,18446744073709551616,4,\n","app.no-pid,1,2,\n"] {
            var parser=ProcessNetworkCSVParser()
            _=try parser.consume(input(header),at:base,uptime:100,cadence:5)
            XCTAssertThrowsError(try parser.consume(input(text),at:base.addingTimeInterval(5),uptime:105,cadence:5))
        }
    }

    func testRejectsDuplicatePIDAndOversizedOutputInsteadOfPublishingPartialTotals()throws {
        var parser=ProcessNetworkCSVParser()
        _=try parser.consume(input(header),at:base,uptime:100,cadence:5)
        XCTAssertThrowsError(try parser.consume(input("app.42,1,2,\nother.42,3,4,\n"),at:base,uptime:100,cadence:5))
        var other=ProcessNetworkCSVParser()
        XCTAssertThrowsError(try other.consume(Data(repeating:65,count:ProcessNetworkCSVParser.maximumBufferedBytes+1),at:base,uptime:100,cadence:5))
        var line=ProcessNetworkCSVParser()
        XCTAssertThrowsError(try line.consume(Data(repeating:65,count:ProcessNetworkCSVParser.maximumLineBytes+1),at:base,uptime:100,cadence:5))
    }

    func testRejectsBufferedHeaderBurstsSleepAndClockJumps()throws {
        for (wall,uptime) in [(0.0,0.0),(40.0,40.0),(40.0,5.0)] {
            var parser=ProcessNetworkCSVParser()
            _=try parser.consume(input(header),at:base,uptime:100,cadence:5)
            XCTAssertThrowsError(try parser.consume(input(header),at:base.addingTimeInterval(wall),uptime:100+uptime,cadence:5))
        }
    }

    func testUsesMeasuredHeaderIntervalRatherThanConfiguredCadence()throws {
        var parser=ProcessNetworkCSVParser()
        _=try parser.consume(input(header),at:base,uptime:100,cadence:5)
        _=try parser.consume(input(header+"app.42,500,100,\n"),at:base.addingTimeInterval(6),uptime:106,cadence:5)
        let sample=try XCTUnwrap(parser.consume(input(header),at:base.addingTimeInterval(12),uptime:112,cadence:5).first)
        XCTAssertEqual(sample.elapsed,6)
        XCTAssertEqual(sample.endedAt,base.addingTimeInterval(6))
    }

    func testResolvesInventoryIdentityAndRetainsRecentExitWithoutBorrowingMetrics() {
        var cache=ProcessNetworkIdentityCache()
        let row=process(name:"full-security-agent-name")
        cache.observe([row],at:base,cadence:5)
        cache.observe([],at:base.addingTimeInterval(10),cadence:5)
        let sample=cache.resolve(raw())
        XCTAssertEqual(sample.tasks.first?.id,row.id);XCTAssertEqual(sample.tasks.first?.name,row.name)
        XCTAssertEqual(sample.tasks.first?.userID,501);XCTAssertEqual(sample.tasks.first?.applicationName,"Test App")
        XCTAssertEqual(sample.tasks.first?.downloadRate(elapsed:sample.elapsed),100)
        XCTAssertEqual(sample.unmatchedProcesses,0)
    }

    func testPIDReuseOrNewlyBornTaskCannotInheritEarlierCaptureBytes() {
        var cache=ProcessNetworkIdentityCache()
        cache.observe([process()],at:base,cadence:5)
        cache.observe([process(start:base.addingTimeInterval(2),name:"new lifetime")],at:base.addingTimeInterval(5),cadence:5)
        let sample=cache.resolve(raw())
        XCTAssertTrue(sample.tasks.isEmpty);XCTAssertEqual(sample.unmatchedProcesses,1)
    }

    func testUnknownAndExpiredIdentitiesRemainUnattributedRatherThanZero() {
        var cache=ProcessNetworkIdentityCache()
        XCTAssertEqual(cache.resolve(raw()).unmatchedProcesses,1)
        cache.observe([process()],at:base,cadence:5)
        cache.observe([],at:base.addingTimeInterval(31),cadence:5)
        XCTAssertTrue(cache.resolve(raw()).tasks.isEmpty)
        cache.observe([process()],at:base,cadence:5);cache.reset()
        XCTAssertTrue(cache.resolve(raw()).tasks.isEmpty)
    }

    func testFreshnessRejectsFutureStaleAndStatusSamples() {
        var cache=ProcessNetworkIdentityCache();cache.observe([process()],at:base,cadence:5)
        var sample=cache.resolve(raw())
        XCTAssertTrue(sample.isFresh(at:base.addingTimeInterval(10)))
        XCTAssertFalse(sample.isFresh(at:base))
        XCTAssertFalse(sample.isFresh(at:base.addingTimeInterval(21)))
        sample.status = .unavailable
        XCTAssertFalse(sample.isFresh(at:base.addingTimeInterval(10)))
    }

    func testNetworkCaptureRoundTripKeepsUniqueIDOwnIntervalAndMissingCounters()throws {
        var cache=ProcessNetworkIdentityCache();cache.observe([process()],at:base,cadence:5)
        var sample=cache.resolve(raw());sample.tasks[0].sentBytes=nil
        let data=try JSONEncoder().encode(sample)
        let restored=try JSONDecoder().decode(ProcessNetworkSample.self,from:data)
        XCTAssertEqual(restored,sample);XCTAssertNil(restored.tasks[0].sentBytes)
        XCTAssertNil(restored.tasks[0].downloadRate(elapsed:0))
        XCTAssertNil(restored.tasks[0].downloadRate(elapsed:.infinity))
        XCTAssertNil(restored.tasks[0].uploadRate(elapsed:5))
    }

    func testStoppedCollectorCannotBeRestartedByALateRecorderSample() {
        let collector=ProcessNetworkCollector();collector.stop()
        let sample=collector.sample(processes:[process()],cadence:5)
        XCTAssertEqual(sample.status,.unavailable);XCTAssertTrue(sample.tasks.isEmpty)
        XCTAssertEqual(sample.error,"Process network collection is stopped.")
    }
}
