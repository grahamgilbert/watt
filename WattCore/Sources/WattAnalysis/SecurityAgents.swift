import Foundation

/// Classification of a running process against the host's installed system services.
/// Wraps `SystemServiceRegistry` and provides a convenience `isAgent` flag used by
/// `ProcessCorrelator` and `PeriodicTopProcesses` to always surface system-managed
/// processes in reports, regardless of their individual resource score.
///
/// No vendor-name guessing. Matching is purely path-based (against real
/// `/Library/LaunchDaemons` plists and `/Library/SystemExtensions` bundles on
/// the host) via `SystemServiceRegistry`.
public enum SecurityAgents {

    /// Returns the `SystemServiceRegistry.Service` for this process, if any.
    public static func classify(
        name: String,
        bundleID: String? = nil,
        executablePath: String? = nil
    ) -> Classification {
        if let svc = SystemServiceRegistry.match(executablePath: executablePath, bundleID: bundleID) {
            return .systemManaged(svc)
        }
        return .unknown
    }

    public static func isSecurityAgent(name: String, bundleID: String? = nil, executablePath: String? = nil) -> Bool {
        classify(name: name, bundleID: bundleID, executablePath: executablePath).isAgent
    }

    public enum Classification: Sendable {
        case systemManaged(SystemServiceRegistry.Service)
        case unknown

        public var isAgent: Bool {
            switch self {
            case .systemManaged: return true
            case .unknown: return false
            }
        }

        public var displayName: String? {
            switch self {
            case .systemManaged(let svc): return svc.label
            case .unknown: return nil
            }
        }

        public var vendor: String? {
            switch self {
            case .systemManaged(let svc):
                switch svc.kind {
                case .endpointSecurityExtension: return "EndpointSecurity extension"
                case .systemExtension:           return "System extension"
                case .launchDaemon:              return "LaunchDaemon"
                }
            case .unknown: return nil
            }
        }

        public var rationale: String? {
            switch self {
            case .systemManaged(let svc):
                switch svc.kind {
                case .endpointSecurityExtension:
                    return "\(svc.label) is registered as an EndpointSecurity system extension. EndpointSecurity is the macOS framework used to monitor process exec, file events, and network — its presence almost always indicates an EDR/DLP product."
                case .systemExtension:
                    return "\(svc.label) is an installed macOS system extension. System extensions run with elevated privileges and are typically deployed by security or VPN products."
                case .launchDaemon:
                    return "\(svc.label) is registered as a system-wide LaunchDaemon (runs as root). System LaunchDaemons on a corporate-managed Mac are overwhelmingly security, MDM, or telemetry tools."
                }
            case .unknown:
                return nil
            }
        }
    }
}
