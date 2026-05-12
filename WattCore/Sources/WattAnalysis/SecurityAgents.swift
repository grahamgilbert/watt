import Foundation

/// Curated registry of well-known endpoint security, MDM, and observability
/// agents that corporate IT teams typically deploy on developer laptops.
///
/// The point of Watt is to make these tools' impact on a developer's machine
/// visible. They often run with privileged scheduling and split their work
/// across multiple short-lived helper processes, so they can fall below
/// per-process energy/CPU thresholds individually while still degrading the
/// system meaningfully in aggregate. This registry lets us **always** call
/// them out in a report when they're observed, regardless of whether their
/// score would otherwise put them in the Prime Suspects list.
public enum SecurityAgents {

    public struct Definition: Sendable, Hashable {
        /// Display name shown in reports.
        public let displayName: String
        /// Vendor / category, used in the rationale string.
        public let vendor: String
        /// One-line description shown next to the process.
        public let description: String
        /// Lower-cased process-name fragments. A process matches if any of
        /// these is a substring of the lower-cased process name.
        public let nameFragments: [String]
        /// Optional bundle-ID prefixes (matched against ProcessSample.bundleID).
        public let bundleIDPrefixes: [String]

        public init(
            displayName: String,
            vendor: String,
            description: String,
            nameFragments: [String],
            bundleIDPrefixes: [String] = []
        ) {
            self.displayName = displayName
            self.vendor = vendor
            self.description = description
            self.nameFragments = nameFragments
            self.bundleIDPrefixes = bundleIDPrefixes
        }
    }

    /// Every entry's match patterns are intentionally broad enough to catch
    /// helper processes (e.g. `falconctl` AND `Falcon`). Keep entries
    /// sorted by vendor for diff readability.
    public static let registry: [Definition] = [
        Definition(
            displayName: "Carbon Black",
            vendor: "VMware",
            description: "Endpoint detection & response — scans process activity and file access.",
            nameFragments: ["cbsystemd", "cbdaemon", "cbosxsensorservice", "carbonblack"],
            bundleIDPrefixes: ["com.carbonblack."]
        ),
        Definition(
            displayName: "CrowdStrike Falcon",
            vendor: "CrowdStrike",
            description: "Endpoint detection & response — real-time process and file scanning.",
            nameFragments: ["falconctl", "falcond", "com.crowdstrike", "falcon"],
            bundleIDPrefixes: ["com.crowdstrike."]
        ),
        Definition(
            displayName: "Cyberhaven",
            vendor: "Cyberhaven",
            description: "Data lineage / DLP — tracks what your processes do with files and network.",
            nameFragments: ["cyberhaven"],
            bundleIDPrefixes: ["com.cyberhaven."]
        ),
        Definition(
            displayName: "Datadog Agent",
            vendor: "Datadog",
            description: "Telemetry agent — host metrics, process snapshots, network probes.",
            nameFragments: ["datadog-agent", "trace-agent", "process-agent", "system-probe"],
            bundleIDPrefixes: ["com.datadoghq."]
        ),
        Definition(
            displayName: "Jamf Protect",
            vendor: "Jamf",
            description: "macOS endpoint security suite — telemetry, threat detection, compliance.",
            nameFragments: ["jamf", "jamfprotect", "jamfdaemon"],
            bundleIDPrefixes: ["com.jamf."]
        ),
        Definition(
            displayName: "Microsoft Defender",
            vendor: "Microsoft",
            description: "Antivirus / EDR — real-time scanning of files and processes.",
            nameFragments: ["wdavdaemon", "mdatp", "microsoftdefender"],
            bundleIDPrefixes: ["com.microsoft.wdav.", "com.microsoft.dlp."]
        ),
        Definition(
            displayName: "Netskope",
            vendor: "Netskope",
            description: "SASE / web filter — proxies and inspects network traffic.",
            nameFragments: ["nsdiag", "netskope", "stagentsvc"],
            bundleIDPrefixes: ["com.netskope."]
        ),
        Definition(
            displayName: "Osquery",
            vendor: "Various",
            description: "SQL-style host inspection — used by many security teams to query device state.",
            nameFragments: ["osqueryd", "osqueryi"],
            bundleIDPrefixes: ["io.osquery."]
        ),
        Definition(
            displayName: "Rapid7 Insight",
            vendor: "Rapid7",
            description: "Endpoint visibility & vuln scanner.",
            nameFragments: ["ir_agent", "rapid7"],
            bundleIDPrefixes: ["com.rapid7."]
        ),
        Definition(
            displayName: "SentinelOne",
            vendor: "SentinelOne",
            description: "Endpoint detection & response — kernel + user-space monitoring.",
            nameFragments: ["sentinel", "sentineld", "sentinelagent"],
            bundleIDPrefixes: ["com.sentinelone."]
        ),
        Definition(
            displayName: "Tanium",
            vendor: "Tanium",
            description: "Real-time endpoint management & query — popular in large enterprises.",
            nameFragments: ["taniumclient"],
            bundleIDPrefixes: ["com.tanium."]
        ),
        Definition(
            displayName: "Tenable / Nessus",
            vendor: "Tenable",
            description: "Vulnerability scanner — periodic deep host inspection.",
            nameFragments: ["nessus", "nessusd", "tenable"],
            bundleIDPrefixes: ["com.tenable."]
        ),
        Definition(
            displayName: "Wazuh / OSSEC",
            vendor: "Wazuh",
            description: "Open-source HIDS — log + file integrity monitoring.",
            nameFragments: ["wazuh", "ossec"],
            bundleIDPrefixes: ["com.wazuh."]
        ),
        Definition(
            displayName: "Zscaler",
            vendor: "Zscaler",
            description: "Network security agent — proxies traffic through Zscaler's cloud.",
            nameFragments: ["zscaler", "zsadmin", "zsservice", "zstunnel"],
            bundleIDPrefixes: ["com.zscaler."]
        )
    ]

    /// Returns the definition matching this process, if any. Match priority:
    /// bundle ID prefix > name fragment.
    public static func match(name: String, bundleID: String?) -> Definition? {
        if let bundleID = bundleID?.lowercased() {
            for def in registry {
                for prefix in def.bundleIDPrefixes where bundleID.hasPrefix(prefix.lowercased()) {
                    return def
                }
            }
        }
        let lowerName = name.lowercased()
        for def in registry {
            for fragment in def.nameFragments where lowerName.contains(fragment.lowercased()) {
                return def
            }
        }
        return nil
    }

    public static func isSecurityAgent(name: String, bundleID: String? = nil) -> Bool {
        match(name: name, bundleID: bundleID) != nil
    }

    /// Combined classification: either an entry in the curated registry or
    /// a system-managed daemon/extension on the host. We rely on this
    /// rather than the curated list alone so reports flag in-house and
    /// less-common agents that wouldn't be in any hardcoded list.
    public static func classify(name: String, bundleID: String? = nil) -> Classification {
        if let curated = match(name: name, bundleID: bundleID) {
            return .curated(curated)
        }
        if let svc = SystemServiceRegistry.match(name: name, bundleID: bundleID) {
            return .systemManaged(svc)
        }
        return .unknown
    }

    public enum Classification: Sendable {
        case curated(Definition)
        case systemManaged(SystemServiceRegistry.Service)
        case unknown

        public var isAgent: Bool {
            switch self {
            case .curated, .systemManaged: return true
            case .unknown: return false
            }
        }

        public var displayName: String? {
            switch self {
            case .curated(let def): return def.displayName
            case .systemManaged(let svc): return svc.label
            case .unknown: return nil
            }
        }

        public var vendor: String? {
            switch self {
            case .curated(let def): return def.vendor
            case .systemManaged(let svc):
                switch svc.kind {
                case .endpointSecurityExtension: return "Endpoint Security extension"
                case .systemExtension:           return "System extension"
                case .launchDaemon:              return "LaunchDaemon"
                }
            case .unknown: return nil
            }
        }

        public var rationale: String? {
            switch self {
            case .curated(let def):
                return "\(def.displayName) — \(def.description)"
            case .systemManaged(let svc):
                switch svc.kind {
                case .endpointSecurityExtension:
                    return "\(svc.label) is registered as an EndpointSecurity system extension. EndpointSecurity is the macOS framework security tools use to monitor process exec, file events, and network — its presence almost always indicates an EDR/DLP product."
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
