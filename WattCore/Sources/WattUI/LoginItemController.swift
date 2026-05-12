import AppKit
import Foundation
import Observation
import os.log
import ServiceManagement

private let logger = Logger(subsystem: "com.grahamgilbert.watt", category: "login-item")

/// Manages the "launch at login" toggle for the main app via
/// `SMAppService.mainApp`. On first launch the app opts in by default; once
/// the user has made an explicit choice (either via our UI or by toggling the
/// item off in System Settings → General → Login Items), that choice is
/// remembered and the default-on behaviour does not re-enable it.
@MainActor
@Observable
public final class LoginItemController {
    public enum LoginItemStatus: Equatable, Sendable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unknown

        init(_ raw: SMAppService.Status) {
            switch raw {
            case .notRegistered:    self = .notRegistered
            case .enabled:          self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notFound:         self = .notFound
            @unknown default:       self = .unknown
            }
        }
    }

    private let service: SMAppService
    private let defaults: UserDefaults
    private let userChoiceKey = "watt.loginItem.userHasMadeChoice"

    public private(set) var status: LoginItemStatus

    public init(
        service: SMAppService = .mainApp,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
        self.status = LoginItemStatus(service.status)
    }

    public var isEnabled: Bool { status == .enabled }

    public var userHasMadeExplicitChoice: Bool {
        defaults.bool(forKey: userChoiceKey)
    }

    /// Call once on app launch. Opts the user into launch-at-login if they
    /// have not yet made an explicit choice. If they have already toggled it
    /// off, this is a no-op so we don't override their preference.
    public func registerDefaultIfNeeded() {
        refreshStatus()
        guard !userHasMadeExplicitChoice else { return }
        do {
            try service.register()
            logger.info("Registered Watt as a login item by default.")
        } catch {
            logger.error("Default login-item registration failed: \(error.localizedDescription)")
        }
        // We deliberately do NOT mark this as an explicit choice — the user
        // hasn't done anything yet. If they now disable the toggle, that
        // becomes the explicit choice we'll honour next time.
        refreshStatus()
    }

    /// Toggle launch-at-login from the UI. Always records that the user has
    /// made an explicit choice, so subsequent launches respect it — even if
    /// the underlying SMAppService call fails (e.g. in tests, or when the
    /// item is already in the requested state).
    public func setEnabled(_ enabled: Bool) {
        defaults.set(true, forKey: userChoiceKey)
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            logger.error("Login-item toggle failed: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    public func refreshStatus() {
        status = LoginItemStatus(service.status)
    }

    /// Open System Settings → General → Login Items so the user can fix a
    /// `.requiresApproval` state.
    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
