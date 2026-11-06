import Combine
import Foundation
import ServiceManagement

@MainActor protocol LoginItemService {
    var status:SMAppService.Status {get}
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor struct SystemLoginItemService:LoginItemService {
    private let service=SMAppService.mainApp
    var status:SMAppService.Status {service.status}
    func register() throws {try service.register()}
    func unregister() throws {try service.unregister()}
    func openSettings() {SMAppService.openSystemSettingsLoginItems()}
}

@MainActor final class LoginItemManager:ObservableObject {
    static let setupKey="loginItem.initialSetupCompleted"
    @Published private(set) var status:SMAppService.Status
    @Published private(set) var lastError:String?
    let isAvailable:Bool
    private let defaults:UserDefaults
    private let service:any LoginItemService

    var isEnabled:Bool {status == .enabled}
    var needsApproval:Bool {status == .requiresApproval}

    // Reading settings never registers anything. Only the real app's launch path
    // applies the default; tests, previews and benchmarks have no login side effects.
    init(isAvailable:Bool,defaults:UserDefaults?=nil,service:(any LoginItemService)?=nil) {
        self.isAvailable=isAvailable
        self.defaults=defaults ?? (Bundle.main.bundleIdentifier == MenuBarSettings.preferencesDomain
            ? .standard : UserDefaults(suiteName:MenuBarSettings.preferencesDomain)!)
        let service=service ?? SystemLoginItemService()
        self.service=service
        status=service.status
    }

    func applyDefaultIfNeeded() {
        refreshStatus()
        guard isAvailable,!defaults.bool(forKey:Self.setupKey) else {return}
        // Record the attempt before calling macOS. Failed registration and later
        // System Settings opt-outs must never cause automatic retries on launch.
        defaults.set(true,forKey:Self.setupKey)
        guard status == .notRegistered else {return}
        setEnabled(true)
    }

    func refreshStatus() {status=service.status}

    func setEnabled(_ enabled:Bool) {
        guard isAvailable else {return}
        defaults.set(true,forKey:Self.setupKey)
        lastError=nil
        refreshStatus()
        do {
            if enabled {
                switch status {
                case .enabled:return
                case .requiresApproval:service.openSettings();return
                case .notFound:
                    lastError="macOS could not find this copy of Watt. Move it to Applications and reopen it."
                    return
                case .notRegistered:try service.register()
                @unknown default:
                    lastError="macOS could not determine Watt’s login item status."
                    return
                }
            } else if status != .notRegistered {
                try service.unregister()
            }
        } catch {
            lastError="Could not \(enabled ? "enable" : "disable") Open at login: \(error.localizedDescription)"
        }
        refreshStatus()
    }

    func openSettings() {service.openSettings()}
}
