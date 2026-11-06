import Foundation
import XCTest
@testable import Watt

final class ProcessTelemetryRecoveryTests:XCTestCase {
    func testTransportFailureDefersReconnectThenAllowsExistingRecorderTick() {
        var policy=ProcessTelemetryReconnectPolicy()
        XCTAssertNil(policy.teamForAttempt(at:100))
        policy.start(team:"ABCDEFGHIJ")
        XCTAssertEqual(policy.teamForAttempt(at:100),"ABCDEFGHIJ")
        policy.transportFailed(at:100)
        XCTAssertNil(policy.teamForAttempt(at:129.999))
        XCTAssertEqual(policy.teamForAttempt(at:130),"ABCDEFGHIJ")
        policy.transportFailed(at:130)
        XCTAssertNil(policy.teamForAttempt(at:159.999))
        XCTAssertEqual(policy.teamForAttempt(at:160),"ABCDEFGHIJ")
    }

    func testStopPreventsReconnectAndExplicitStartCanRetryImmediately() {
        var policy=ProcessTelemetryReconnectPolicy()
        policy.start(team:"ABCDEFGHIJ")
        policy.transportFailed(at:100)
        policy.stop()
        XCTAssertNil(policy.teamForAttempt(at:1_000))
        policy.transportFailed(at:1_001)
        XCTAssertNil(policy.teamForAttempt(at:2_000))
        policy.start(team:"ABCDEFGHIJ")
        policy.transportFailed(at:2_000)
        policy.start(team:"ABCDEFGHIJ")
        XCTAssertEqual(policy.teamForAttempt(at:2_001),"ABCDEFGHIJ")
    }

    func testTimeoutRejectsLateReplyBytesAndLateTransportErrors() {
        let reply=ProcessTelemetryReply()
        guard case .timedOut=reply.wait(timeout:0) else {return XCTFail("Expected the current frame to time out")}
        reply.complete(.reply(Data([1,2,3]),nil))
        reply.complete(.transportFailure)
        guard case .timedOut=reply.wait(timeout:0) else {return XCTFail("A late reply must not replace a timed-out frame")}
    }

    func testSampleRejectionIsDistinctFromTransportFailure() {
        let rejection=ProcessTelemetryReply()
        rejection.complete(.reply(nil,"Capture requested too recently"))
        guard case .reply(let data,let error)=rejection.wait(timeout:0) else {return XCTFail("Expected a sample-level rejection")}
        XCTAssertNil(data);XCTAssertEqual(error,"Capture requested too recently")
        let transport=ProcessTelemetryReply()
        transport.complete(.transportFailure)
        guard case .transportFailure=transport.wait(timeout:0) else {return XCTFail("Expected a transport failure")}
    }

    func testFirstCompletedResponseWins() {
        let reply=ProcessTelemetryReply()
        reply.complete(.reply(Data([7]),nil))
        reply.complete(.reply(Data([9]),nil))
        guard case .reply(let data,let error)=reply.wait(timeout:0) else {return XCTFail("Expected the first reply")}
        XCTAssertEqual(data,Data([7]));XCTAssertNil(error)
    }
}
