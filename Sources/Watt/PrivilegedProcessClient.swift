import Foundation
import WattEnergyProtocol

// Native counters are requested on the recorder queue, once per sample. There is
// no extra timer and no cached response masquerading as a new measurement.
final class PrivilegedProcessClient:@unchecked Sendable {
    static let shared=PrivilegedProcessClient()
    private let lock=NSLock()
    private var connection:NSXPCConnection?
    private var generation=UUID()
    private var failure:String?
    private var inFlight=false
    private var reconnect=ProcessTelemetryReconnectPolicy()
    var lastError:String? {lock.lock();defer {lock.unlock()};return failure}

    func start(team:String) {
        lock.lock()
        let old=reconnect.desiredTeam==team ? nil : connection
        if old != nil {connection=nil;generation=UUID()}
        reconnect.start(team:team);failure=nil
        connectIfNeeded()
        lock.unlock()
        old?.invalidate()
    }
    // Called only while holding the lock. Resume before unlocking so a concurrent
    // stop cannot invalidate an unresumed connection and then have it revived.
    private func connectIfNeeded() {
        guard connection == nil,let team=reconnect.teamForAttempt(at:ProcessInfo.processInfo.systemUptime) else {return}
        let value=NSXPCConnection(machServiceName:EnergyServiceConfiguration.serviceName,options:.privileged)
        let id=UUID();generation=id
        value.remoteObjectInterface=NSXPCInterface(with:WattEnergyServiceProtocol.self)
        value.setCodeSigningRequirement(EnergyServiceIdentity.requirementString(identifier:EnergyServiceConfiguration.helperIdentifier,team:team))
        value.invalidationHandler={ [weak self] in self?.failed(id) }
        value.interruptionHandler={ [weak self] in self?.failed(id) }
        connection=value
        value.resume()
    }
    func stop() {
        lock.lock();let old=connection;connection=nil;generation=UUID();failure=nil;reconnect.stop();lock.unlock()
        old?.invalidate()
    }
    private func failed(_ id:UUID) {
        lock.lock()
        guard generation==id else {lock.unlock();return}
        let old=connection;connection=nil;generation=UUID()
        reconnect.transportFailed(at:ProcessInfo.processInfo.systemUptime)
        failure="Protected process metrics are unavailable. Watt will retry; reinstall the collector in Preferences if it needs updating."
        lock.unlock();old?.invalidate()
    }
    private func temporarilyUnavailable(_ id:UUID,timedOut:Bool) {
        lock.lock();defer {lock.unlock()}
        guard generation==id else {return}
        failure=timedOut ? "Protected process capture timed out. The next sample will retry; local metrics remain available."
            : "Protected process capture is temporarily unavailable. The next sample will retry; local metrics remain available."
    }
    func sample()->ProcessTelemetrySample? {
        lock.lock()
        guard !inFlight else {lock.unlock();return nil}
        connectIfNeeded()
        guard let connection else {lock.unlock();return nil}
        let id=generation;inFlight=true;lock.unlock()
        defer {lock.lock();inFlight=false;lock.unlock()}
        let response=ProcessTelemetryReply()
        guard let proxy=connection.remoteObjectProxyWithErrorHandler({ _ in response.complete(.transportFailure) }) as? WattEnergyServiceProtocol else {
            failed(id);return nil
        }
        let requestedAt=Date(),requestedUptime=ProcessInfo.processInfo.systemUptime
        proxy.captureProcesses {data,error in response.complete(.reply(data,error))}
        // A missing/old helper must not stall recording or the main thread.
        let data:Data
        switch response.wait(timeout:0.75) {
        case .reply(let value,let error):
            guard let value,error==nil else {temporarilyUnavailable(id,timedOut:false);return nil}
            data=value
        case .timedOut:temporarilyUnavailable(id,timedOut:true);return nil
        case .transportFailure:failed(id);return nil
        }
        do {
            let sample=try ProcessTelemetrySample.decode(data)
            let receivedAt=Date(),receivedUptime=ProcessInfo.processInfo.systemUptime
            guard ProcessTelemetryFreshness.accepts(sample,requestedAt:requestedAt,receivedAt:receivedAt,
                    requestedUptime:requestedUptime,receivedUptime:receivedUptime) else {failed(id);return nil}
            lock.lock();let active=generation==id && self.connection === connection
            if active {failure=nil}
            lock.unlock()
            return active ? sample : nil
        } catch {failed(id);return nil}
    }
}

// Replies can arrive after timeout, stop or connection replacement. A detached
// rendezvous owns those bytes and never changes recorder state on its own.
enum ProcessTelemetryReplyOutcome {
    case reply(Data?,String?)
    case transportFailure
    case timedOut
}
final class ProcessTelemetryReply:@unchecked Sendable {
    private let lock=NSLock()
    private let ready=DispatchSemaphore(value:0)
    private var outcome:ProcessTelemetryReplyOutcome?
    func complete(_ value:ProcessTelemetryReplyOutcome) {
        lock.lock()
        guard outcome==nil else {lock.unlock();return}
        outcome=value;lock.unlock();ready.signal()
    }
    func wait(timeout:TimeInterval)->ProcessTelemetryReplyOutcome {
        _=ready.wait(timeout:.now()+max(0,timeout))
        lock.lock();defer {lock.unlock()}
        if let outcome {return outcome}
        outcome = .timedOut
        return .timedOut
    }
}

// Reconnect on an existing recorder tick after a transport failure. Keeping the
// desired team separate from the connection prevents a transient failure from
// disabling collection, and stop removes permission to reconnect altogether.
struct ProcessTelemetryReconnectPolicy {
    static let retryDelay:TimeInterval=30
    private(set) var desiredTeam:String?
    private var retryAfter:TimeInterval?
    mutating func start(team:String) {desiredTeam=team;retryAfter=nil}
    mutating func stop() {desiredTeam=nil;retryAfter=nil}
    mutating func transportFailed(at uptime:TimeInterval) {
        guard desiredTeam != nil else {return}
        retryAfter=uptime+Self.retryDelay
    }
    func teamForAttempt(at uptime:TimeInterval)->String? {
        guard uptime.isFinite,let desiredTeam,retryAfter.map({uptime >= $0}) ?? true else {return nil}
        return desiredTeam
    }
}

enum ProcessTelemetryFreshness {
    static func accepts(_ sample:ProcessTelemetrySample,requestedAt:Date,receivedAt:Date,
                        requestedUptime:TimeInterval,receivedUptime:TimeInterval)->Bool {
        // Both clocks come from this Mac; the helper must have collected during
        // this request. Small scheduling/clock-read tolerance is not a cache age.
        let tolerance=0.05
        return sample.sampledAt>=requestedAt.addingTimeInterval(-tolerance)
            && sample.sampledAt<=receivedAt.addingTimeInterval(tolerance)
            && sample.uptime>=requestedUptime-tolerance && sample.uptime<=receivedUptime+tolerance
    }
}
