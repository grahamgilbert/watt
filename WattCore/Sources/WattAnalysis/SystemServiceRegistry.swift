import Foundation

public enum SystemServiceKind: String, Sendable {
    case launchDaemon
    case systemExtension
    case endpointSecurityExtension
}

/// Builds a registry of "system-managed" services on the host: every
/// LaunchDaemon plist in `/Library/LaunchDaemons` and every System Extension
/// in `/Library/SystemExtensions`.
///
/// Matching against a running process is **strict**:
///   1. The process's absolute executable path (from `proc_pidpath`) is
///      compared against the daemon's `Program` / `ProgramArguments[0]` and
///      the system extension bundle's `Contents/MacOS/<exec>` path.
///   2. Failing that, the bundle ID is compared exact-prefix against the
///      daemon Label / extension CFBundleIdentifier.
///
/// We deliberately do NOT do substring matches on process names. The earlier
/// version of this matcher would flag e.g. `OfficeLicensingHelper` as a
/// security agent because the substring "office" appeared somewhere — that's
/// noise. Path-based matching is precise and matches what `systemextensionsctl
/// list` or `launchctl print system/<label>` would tell you.
public enum SystemServiceRegistry {

    public struct Service: Sendable, Hashable {
        public let label: String
        /// Absolute executable paths the kernel might run for this service.
        public let executablePaths: [String]
        /// Bundle-id prefixes (used as a secondary signal when path matching
        /// fails). Empty for daemons whose plist doesn't declare one.
        public let bundleIDPrefixes: [String]
        public let kind: SystemServiceKind
    }

    private static let cache = Cache()

    public static func services() -> [Service] { cache.services }

    public static func match(executablePath: String?, bundleID: String?) -> Service? {
        cache.match(executablePath: executablePath, bundleID: bundleID)
    }

    public static func isSystemManaged(executablePath: String?, bundleID: String? = nil) -> Bool {
        match(executablePath: executablePath, bundleID: bundleID) != nil
    }

    private final class Cache: @unchecked Sendable {
        let services: [Service]
        private let pathIndex: [String: Service]
        private let bundleIndex: [String: Service]

        init() {
            var found: [Service] = []
            found.append(contentsOf: Self.loadLaunchDaemons())
            found.append(contentsOf: Self.loadSystemExtensions())

            self.services = found
            var pIdx: [String: Service] = [:]
            var bIdx: [String: Service] = [:]
            for svc in found {
                for p in svc.executablePaths {
                    pIdx[p] = svc
                }
                for prefix in svc.bundleIDPrefixes {
                    bIdx[prefix.lowercased()] = svc
                }
                bIdx[svc.label.lowercased()] = svc
            }
            self.pathIndex = pIdx
            self.bundleIndex = bIdx
        }

        func match(executablePath: String?, bundleID: String?) -> Service? {
            // 1. Exact executable-path match: the strongest signal. If the
            //    OS is running this exact binary, and the binary is what the
            //    LaunchDaemon plist or SystemExtension bundle declares, we
            //    are looking at that service.
            if let path = executablePath, let svc = pathIndex[path] {
                return svc
            }
            // 2. Bundle-ID prefix match. We only treat this as authoritative
            //    when the bundle ID is non-empty and starts with one of the
            //    declared prefixes (no fuzzy substring).
            if let lower = bundleID?.lowercased() {
                for (prefix, svc) in bundleIndex where lower == prefix || lower.hasPrefix(prefix + ".") {
                    return svc
                }
            }
            return nil
        }

        // MARK: - Loaders

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
                    var paths: [String] = []
                    if let program = plist["Program"] as? String {
                        paths.append(program)
                    }
                    if let args = plist["ProgramArguments"] as? [String], let first = args.first {
                        paths.append(first)
                    }
                    let bundleIDPrefixes: [String] = {
                        var out: [String] = [label]
                        if let bin = plist["BundleIdentifier"] as? String {
                            out.append(bin)
                        }
                        return out
                    }()
                    services.append(Service(
                        label: label,
                        executablePaths: paths,
                        bundleIDPrefixes: bundleIDPrefixes,
                        kind: .launchDaemon
                    ))
                }
            }
            return services
        }

        static func loadSystemExtensions() -> [Service] {
            let root = "/Library/SystemExtensions"
            guard FileManager.default.fileExists(atPath: root),
                  let containers = try? FileManager.default.contentsOfDirectory(atPath: root)
            else { return [] }
            var services: [Service] = []
            for container in containers where container != ".staging" {
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
                    let executablePath = "\(bundlePath)/Contents/MacOS/\(executableName)"

                    let kind: SystemServiceKind = isEndpointSecurityExtension(plist)
                        ? .endpointSecurityExtension
                        : .systemExtension
                    services.append(Service(
                        label: bundleID,
                        executablePaths: [executablePath],
                        bundleIDPrefixes: [bundleID],
                        kind: kind
                    ))
                }
            }
            return services
        }

        private static func isEndpointSecurityExtension(_ plist: [String: Any]) -> Bool {
            if let nsExt = plist["NSExtension"] as? [String: Any],
               let pointID = nsExt["NSExtensionPointIdentifier"] as? String,
               pointID.contains("endpoint-security") {
                return true
            }
            return false
        }
    }
}
