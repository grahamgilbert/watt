import CTelemetry
import Darwin
import Foundation
import XCTest
@testable import Watt

// XCTest runs this synchronous case serially in its runner process. Measure the
// child usage delta, not Watt/UI fixture cost. No process names, PIDs, endpoint
// addresses, or traffic values are emitted into the CI log.
final class ProcessNetworkLiveTests:XCTestCase {
    func testLiveAdapterProducesCapturesWithoutSpinningAndStopsItsChild()throws {
        var inventory=[WattProcess](repeating:WattProcess(),count:16_384)
        var denied:Int32=0
        let count=Int(watt_processes(&inventory,Int32(inventory.count),&denied))
        XCTAssertGreaterThan(count,0,"Native process inventory is unavailable on this runner; process-network integration cannot be validated.")
        guard count>0 else {return}
        let processes=inventory.prefix(count).map {ProcessMeasurements.row(current:$0,previous:nil,elapsed:nil,source:"network-integration-test")}
        let collector=ProcessNetworkCollector()
        defer {collector.stop()}
        let before=try childUsage()
        let began=ProcessInfo.processInfo.systemUptime
        var hasFreshCounters=false
        var childPID:Int32?
        var lastStatus:ProcessNetworkStatus = .waiting
        var lastError:String?
        while ProcessInfo.processInfo.systemUptime-began<6 {
            let sample=collector.sample(processes:processes,cadence:2)
            if childPID==nil {childPID=collector.childProcessIdentifier}
            lastStatus=sample.status;lastError=sample.error
            if sample.isFresh(at:Date()),sample.tasks.contains(where:{$0.receivedBytes != nil || $0.sentBytes != nil}) {
                hasFreshCounters=true
            }
            Thread.sleep(forTimeInterval:0.2)
        }
        collector.stop()
        // Foundation reaps Process asynchronously. Give termination/kill a
        // bounded chance to complete before reading RUSAGE_CHILDREN; otherwise
        // zero usage could incorrectly make a still-running child pass.
        let cleanupDeadline=ProcessInfo.processInfo.systemUptime+2
        while childPID.map(childExists) == true && ProcessInfo.processInfo.systemUptime<cleanupDeadline {
            Thread.sleep(forTimeInterval:0.02)
        }
        XCTAssertNotNil(childPID,"The adapter did not start its fixed sampler child on this runner.")
        XCTAssertFalse(childPID.map(childExists) ?? true,"The sampler child remains after stop; refusing to trust incomplete child CPU accounting.")
        // Give Foundation's waiter one short scheduling turn after the kernel
        // reports the exact child gone, then obtain its accumulated usage.
        Thread.sleep(forTimeInterval:0.05)
        let after=try childUsage()
        let cpu=childCPU(after)-childCPU(before)
        XCTAssertTrue(hasFreshCounters,"No fresh complete process-network capture with counters was produced. Status: \(lastStatus.rawValue). \(lastError ?? "Check nettop availability and process-network access on this runner.")")
        XCTAssertGreaterThan(cpu,0,"The sampler child was not accounted for after stop; verify child termination and reaping before trusting its CPU result.")
        XCTAssertLessThanOrEqual(cpu,1,"Process-network child used \(String(format:"%.3f",cpu)) CPU seconds in a six-second capture. Check for an EOF/readiness loop: nettop logging requires idle raw-terminal stdin as well as line-buffered stdout.")
        XCTAssertEqual(collector.sample(processes:processes,cadence:2).status,.unavailable,"A stopped adapter must not revive from a late recorder sample.")
    }

    private func childUsage()throws->rusage {
        var result=rusage()
        guard getrusage(RUSAGE_CHILDREN,&result)==0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        return result
    }
    private func childCPU(_ value:rusage)->Double {
        Double(value.ru_utime.tv_sec)+Double(value.ru_utime.tv_usec)/1e6
            + Double(value.ru_stime.tv_sec)+Double(value.ru_stime.tv_usec)/1e6
    }
    private func childExists(_ pid:Int32)->Bool {
        if kill(pid,0)==0 {return true}
        return errno != ESRCH
    }
}
