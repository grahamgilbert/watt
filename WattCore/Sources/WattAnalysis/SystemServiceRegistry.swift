import Foundation

/// Builds a set of "system-managed" process names by reading all installed
/// LaunchDaemons and System Extensions on the host. Any process whose name
/// matches one of these is almost certainly a privileged background service
/// — and on a corporate-managed Mac, the overwhelming majority of such
/// services are security/observability/MDM agents.
///
/// This complements the curated `SecurityAgents` registry: the registry
/// gives us friendly display names and descriptions for known-popular
/// vendors, this gives us full coverage of whatever IT happens to ship on a
/// given laptop (including in-house tools that wouldn't be in any list).
public enum SystemServiceKind: String, Sendable {
    case launchDaemon
    case systemExtension
    case endpointSecurityExtension
}

public enum SystemServiceRegistry {

    public struct Service: Sendable, Hashable {
        /// Either the launchd Label (when discovered from a daemon plist) or
        /// the System Extension bundle identifier.
        public let label: String
        /// The executable path or display name we'll match against running
        /// process names / bundle IDs.
        public let matchTokens: [String]
        /// Source of the entry — useful for the rationale string.
        public let kind: SystemServiceKind
    }

    /// Loaded once and cached. Callers should treat this as immutable for
    /// the lifetime of the process; the underlying file system rarely
    /// changes within a single Watt session.
    private static let cache = Cache()

    public static func services() -> [Service] { cache.services }

    public static func match(name: String, bundleID: String?) -> Service? {
        cache.match(name: name, bundleID: bundleID)
    }

    public static func isSystemManaged(name: String, bundleID: String? = nil) -> Bool {
        match(name: name, bundleID: bundleID) != nil
    }

    private final class Cache: @unchecked Sendable {
        let services: [Service]
        private let nameIndex: [String: Service]
        private let bundleIndex: [String: Service]

        init() {
            var found: [Service] = []
            found.append(contentsOf: Self.loadLaunchDaemons())
            found.append(contentsOf: Self.loadSystemExtensions())

            self.services = found
            var nameIdx: [String: Service] = [:]
            var bundleIdx: [String: Service] = [:]
            for svc in found {
                for token in svc.matchTokens {
                    let lower = token.lowercased()
                    if !lower.isEmpty {
                        nameIdx[lower] = svc
                    }
                }
                let lower = svc.label.lowercased()
                if !lower.isEmpty {
                    bundleIdx[lower] = svc
                }
            }
            self.nameIndex = nameIdx
            self.bundleIndex = bundleIdx
        }

        func match(name: String, bundleID: String?) -> Service? {
            if let bundleID, let svc = bundleIndex[bundleID.lowercased()] { return svc }
            let lower = name.lowercased()
            if let svc = nameIndex[lower] { return svc }
            // Fallback: substring match against the executable basename. Many
            // helper processes ship with names like "com.example.agentHelper"
            // that won't exact-match a launchd Label but contain it.
            for (token, svc) in nameIndex where lower.contains(token) || token.contains(lower) {
                return svc
            }
            return nil
        }

        // MARK: - Loaders

        /// Read every plist in /Library/LaunchDaemons (system-wide) and
        /// /Library/LaunchAgents (user-wide). Per-user agents are skipped —
        /// security tooling lives in /Library, not ~/Library.
        static func loadLaunchDaemons() -> [Service] {
            let dirs = ["/Library/LaunchDaemons"]
            var services: [Service] = []
            for dir in dirs {
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where entry.hasSuffix(".plist") {
                    let path = "\(dir)/\(entry)"
                    guard let data = FileManager.default.contents(atPath: path),
                          let plist = (try? PropertyListSerialization.propertyList(
                              from: data, options: [], format: nil
                          )) as? [String: Any]
                    else { continue }

                    let label = (plist["Label"] as? String) ?? entry.replacingOccurrences(of: ".plist", with: "")
                    var tokens: [String] = [label]
                    if let program = plist["Program"] as? String {
                        tokens.append((program as NSString).lastPathComponent)
                    }
                    if let args = plist["ProgramArguments"] as? [String], let first = args.first {
                        tokens.append((first as NSString).lastPathComponent)
                    }
                    if let bin = plist["BundleIdentifier"] as? String {
                        tokens.append(bin)
                    }
                    services.append(Service(
                        label: label,
                        matchTokens: tokens.filter { !$0.isEmpty },
                        kind: .launchDaemon
                    ))
                }
            }
            return services
        }

        /// Walk /Library/SystemExtensions and extract every installed
        /// extension, flagging EndpointSecurity ones explicitly.
        static func loadSystemExtensions() -> [Service] {
            // /Library/SystemExtensions/<UUID>/<bundle.id>.systemextension/Contents/Info.plist
            let root = "/Library/SystemExtensions"
            guard FileManager.default.fileExists(atPath: root),
                  let containers = try? FileManager.default.contentsOfDirectory(atPath: root)
            else { return [] }
            var services: [Service] = []
            for container in containers {
                let containerPath = "\(root)/\(container)"
                guard let bundles = try? FileManager.default.contentsOfDirectory(atPath: containerPath) else { continue }
                for bundle in bundles where bundle.hasSuffix(".systemextension") {
                    let bundlePath = "\(containerPath)/\(bundle)"
                    let infoPath = "\(bundlePath)/Contents/Info.plist"
                    guard let data = FileManager.default.contents(atPath: infoPath),
                          let plist = (try? PropertyListSerialization.propertyList(
                              from: data, options: [], format: nil
                          )) as? [String: Any]
                    else { continue }

                    let bundleID = (plist["CFBundleIdentifier"] as? String)
                        ?? bundle.replacingOccurrences(of: ".systemextension", with: "")
                    let executableName = (plist["CFBundleExecutable"] as? String) ?? bundleID

                    let kind: SystemServiceKind = isEndpointSecurityExtension(plist) ? .endpointSecurityExtension : .systemExtension
                    services.append(Service(
                        label: bundleID,
                        matchTokens: [bundleID, executableName],
                        kind: kind
                    ))
                }
            }
            return services
        }

        private static func isEndpointSecurityExtension(_ plist: [String: Any]) -> Bool {
            // Endpoint Security extensions declare:
            //   NSExtension.NSExtensionPointIdentifier == "com.apple.security.endpoint-security.client"
            // OR they list the EndpointSecurity entitlement.
            if let nsExt = plist["NSExtension"] as? [String: Any],
               let pointID = nsExt["NSExtensionPointIdentifier"] as? String,
               pointID.contains("endpoint-security") {
                return true
            }
            return false
        }
    }
}
