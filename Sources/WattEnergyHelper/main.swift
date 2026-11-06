import Foundation
import WattEnergyProtocol

final class EnergySession:NSObject,WattEnergyServiceProtocol {
    private weak var controller:EnergyHelper?
    private let id:UUID
    init(controller:EnergyHelper,id:UUID) {self.controller=controller;self.id=id}
    func capture(withReply reply:@escaping (Data?,String?)->Void) {
        // Admission validates the peer once; setCodeSigningRequirement below validates
        // every XPC message. Avoid an additional full SecCode walk per sample.
        guard let controller,NSXPCConnection.current() != nil else {
            reply(nil,"The energy client is not an authorized Watt release.");return
        }
        controller.capture.capture(owner:id,reply:reply)
    }
}
final class EnergyHelper:NSObject,NSXPCListenerDelegate {
    let team:String
    let capture=PowermetricsCapture()
    private let lock=NSLock()
    private var connections:[UUID:NSXPCConnection]=[:]
    private var idleGeneration=0
    init(team:String) {self.team=team;super.init();scheduleIdleExit()}
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection)->Bool {
        guard EnergyServiceIdentity.validate(pid:connection.processIdentifier,identifier:EnergyServiceConfiguration.appIdentifier,team:team) else {return false}
        let id=UUID()
        // Public macOS 13+ API validates every message, not only a potentially reusable PID.
        connection.setCodeSigningRequirement(EnergyServiceIdentity.requirementString(identifier:EnergyServiceConfiguration.appIdentifier,team:team))
        connection.exportedInterface=NSXPCInterface(with:WattEnergyServiceProtocol.self)
        connection.exportedObject=EnergySession(controller:self,id:id)
        connection.invalidationHandler={ [weak self] in self?.disconnected(id) }
        lock.lock();connections[id]=connection;idleGeneration+=1;lock.unlock()
        capture.connected(owner:id)
        connection.resume();return true
    }
    private func disconnected(_ id:UUID) {
        lock.lock();connections.removeValue(forKey:id);lock.unlock()
        capture.cancel(owner:id);scheduleIdleExit()
    }
    private func scheduleIdleExit() {
        lock.lock();idleGeneration+=1;let generation=idleGeneration;lock.unlock()
        DispatchQueue.global().asyncAfter(deadline:.now()+30) { [weak self] in
            guard let self else {return}
            self.lock.lock();let idle=self.connections.isEmpty && self.idleGeneration==generation;self.lock.unlock()
            if idle {exit(0)}
        }
    }
}

guard geteuid()==0,let team=EnergyServiceIdentity.currentTeam(identifier:EnergyServiceConfiguration.helperIdentifier) else {
    FileHandle.standardError.write(Data("Watt energy helper requires its Developer ID signature and launchd root context.\n".utf8));exit(1)
}
let delegate=EnergyHelper(team:team)
let listener=NSXPCListener(machServiceName:EnergyServiceConfiguration.serviceName)
listener.delegate=delegate
withExtendedLifetime(delegate) {listener.resume();dispatchMain()}
