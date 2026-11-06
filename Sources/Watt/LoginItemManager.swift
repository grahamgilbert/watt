import Combine
import Foundation
import Security
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
    // Main-app login items accept ordinary Apple-signed app builds. The energy
    // helper has a separate Developer ID policy which does not apply here.
    static var isSignedApp:Bool {
        let bundle=Bundle.main
        guard bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL",
              bundle.bundleURL.pathExtension.lowercased()=="app",
              bundle.bundleIdentifier==MenuBarSettings.preferencesDomain else {return false}
        var code:SecCode?
        guard SecCodeCopySelf([], &code)==errSecSuccess,let code else {return false}
        var staticCode:SecStaticCode?
        guard SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode else {return false}
        var information:CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&information)==errSecSuccess,
              let info=information as? [String:Any],
              let requirement=signingRequirement(bundleURL:bundle.bundleURL,bundleIdentifier:bundle.bundleIdentifier,
                    signingIdentifier:info[kSecCodeInfoIdentifier as String] as? String,
                    team:info[kSecCodeInfoTeamIdentifier as String] as? String) else {return false}
        return SecCodeCheckValidity(code,[],requirement)==errSecSuccess
    }
    static func signingRequirement(bundleURL:URL,bundleIdentifier:String?,signingIdentifier:String?,team:String?)->SecRequirement? {
        guard bundleURL.pathExtension.lowercased()=="app",
              bundleIdentifier==MenuBarSettings.preferencesDomain,
              signingIdentifier==MenuBarSettings.preferencesDomain,
              let team,team.range(of:"^[A-Z0-9]{10}$",options:.regularExpression) != nil else {return nil}
        // Both Apple Development and Developer ID chains satisfy this requirement;
        // ad hoc signatures do not have an Apple anchor or certificate team.
        let text=#"anchor apple generic and identifier "com.grahamgilbert.Watt" and certificate leaf[subject.OU] = "\#(team)""#
        var requirement:SecRequirement?
        guard SecRequirementCreateWithString(text as CFString,[],&requirement)==errSecSuccess else {return nil}
        return requirement
    }
    @Published private(set) var status:SMAppService.Status
    @Published private(set) var lastError:String?
    let isAvailable:Bool
    private let defaults:UserDefaults
    private let service:any LoginItemService

    var isEnabled:Bool {status == .enabled}
    var needsApproval:Bool {status == .requiresApproval}
    var initialSetupCompleted:Bool {defaults.bool(forKey:Self.setupKey)}

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
