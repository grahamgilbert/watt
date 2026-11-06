import Foundation
import Combine
import ServiceManagement
import WattEnergyProtocol

// Registration happens only after an explicit Preferences action. Starting a collector never installs it.
@MainActor final class EnergyImpactCollector:ObservableObject {
    @Published private(set) var status="Apple Energy Impact collector is not installed."
    @Published private(set) var isInstalled=false
    @Published private(set) var needsApproval=false
    @Published private(set) var isRunning=false
    @Published private(set) var lastSampleDate:Date?
    @Published private(set) var lastError:String?
    @Published private(set) var isSignedBuild=false
    private let service=SMAppService.daemon(plistName:EnergyServiceConfiguration.plistName)
    private var team:String?
    private var timer:Timer?
    private var connection:NSXPCConnection?
    private var connectionID=UUID()
    private var activeCapture:UUID?
    private var requestedInterval:TimeInterval=5
    init() {refreshStatus()}
    func refreshStatus() {
        team=EnergyServiceIdentity.currentTeam(identifier:EnergyServiceConfiguration.appIdentifier)
        isSignedBuild=team != nil
        let value=service.status
        isInstalled=value == .enabled;needsApproval=value == .requiresApproval
        guard isSignedBuild else {status="Apple Energy Impact requires a Developer ID-signed Watt release.";return}
        switch value {
        case .enabled:if !isRunning {status="Apple Energy Impact collector is installed; collection is stopped."}
        case .requiresApproval:status="Approve the Watt energy collector in Login Items & Extensions."
        case .notRegistered:status="Apple Energy Impact collector is not installed."
        case .notFound:status="The energy helper is missing from this app bundle."
        @unknown default:status="Apple Energy Impact collector status is unavailable."
        }
    }
    func install() {
        refreshStatus()
        guard isSignedBuild else {return}
        let plist=Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/"+EnergyServiceConfiguration.plistName)
        guard FileManager.default.fileExists(atPath:plist.path) else {status="The energy helper is missing from this app bundle.";return}
        do {
            try service.register();lastError=nil;refreshStatus()
            if isInstalled {start(interval:requestedInterval)}
        } catch {lastError=error.localizedDescription;refreshStatus();status=error.localizedDescription}
    }
    func requestApproval() {SMAppService.openSystemSettingsLoginItems()}
    func unregister() {
        stop()
        do {try service.unregister();lastError=nil;refreshStatus()}
        catch {lastError=error.localizedDescription;refreshStatus();status=error.localizedDescription}
    }
    func start(interval:TimeInterval=5) {
        guard interval.isFinite else {return}
        requestedInterval=min(60,max(2,interval))
        refreshStatus()
        guard isInstalled,isSignedBuild,let team else {return}
        timer?.invalidate()
        if connection == nil {
            let value=NSXPCConnection(machServiceName:EnergyServiceConfiguration.serviceName,options:.privileged)
            value.remoteObjectInterface=NSXPCInterface(with:WattEnergyServiceProtocol.self)
            value.setCodeSigningRequirement(EnergyServiceIdentity.requirementString(identifier:EnergyServiceConfiguration.helperIdentifier,team:team))
            let id=UUID();connectionID=id
            value.invalidationHandler={ [weak self] in Task { @MainActor in self?.connectionEnded(id) } }
            value.interruptionHandler={ [weak self] in Task { @MainActor in self?.connectionEnded(id) } }
            connection=value;value.resume()
        }
        isRunning=true
        let timer=Timer(timeInterval:requestedInterval,repeats:true) { [weak self] _ in Task { @MainActor in self?.capture() } }
        self.timer=timer;RunLoop.main.add(timer,forMode:.common)
        capture()
    }
    func stop() {
        timer?.invalidate();timer=nil
        isRunning=false;activeCapture=nil;connectionID=UUID()
        let old=connection;connection=nil;old?.invalidate()
        EnergyImpactCache.shared.clear()
        status="Apple Energy Impact collection is stopped."
    }
    private func connectionEnded(_ id:UUID) {
        guard connectionID==id else {return}
        timer?.invalidate();timer=nil;activeCapture=nil;isRunning=false
        let old=connection;connection=nil;connectionID=UUID();old?.invalidate()
        EnergyImpactCache.shared.clear();status="Energy collector connection ended. Enable collection to reconnect."
    }
    private func capture() {
        guard isRunning,activeCapture == nil,let connection else {return}
        let token=UUID();activeCapture=token
        guard let proxy=connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor in self?.received(nil,error:error.localizedDescription,token:token) }
        }) as? WattEnergyServiceProtocol else {
            received(nil,error:"Could not connect to the energy helper.",token:token);return
        }
        proxy.capture { [weak self] data,error in
            Task { @MainActor in self?.received(data,error:error,token:token) }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+11) { [weak self] in
            guard let self,self.activeCapture==token else {return}
            self.connectionEnded(self.connectionID)
            self.status="Energy collector reply timed out. Enable collection to reconnect."
        }
    }
    private func received(_ data:Data?,error:String?,token:UUID) {
        guard isRunning,activeCapture==token else {return}
        activeCapture=nil
        guard let data,error == nil,data.count<=EnergyServiceConfiguration.maximumOutputBytes else {
            lastError=error ?? "Energy collector returned no sample.";status=lastError!;EnergyImpactCache.shared.clear();return
        }
        do {
            let sample=try JSONDecoder().decode(EnergyImpactSample.self,from:data)
            try sample.validate()
            guard sample.endedAt<=Date(),Date().timeIntervalSince(sample.endedAt)<=15 else {throw EnergyImpactParseError.invalidSample}
            EnergyImpactCache.shared.store(sample);lastSampleDate=sample.endedAt;lastError=nil
            status=sample.hasEnergyValues ? "Recording Apple's process Energy Impact estimates." : "Apple Energy Impact was unavailable in this sample."
        } catch {lastError=error.localizedDescription;status=error.localizedDescription;EnergyImpactCache.shared.clear()}
    }
}
