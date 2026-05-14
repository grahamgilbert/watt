import Foundation

public let WattHelperMachServiceName = "com.grahamgilbert.watt.helper"

/// Bumped every time the helper's wire protocol changes. The app refuses to
/// run if the installed helper reports a version different from this — the
/// user is told to reinstall.
public let WattHelperProtocolVersion = 2

/// Plain-data envelope the helper returns for every visible pid. Mirrors
/// what `proc_pid_rusage_v6` would have given us, but the helper has root
/// privilege so it sees pids that an unprivileged client cannot
/// (CrowdStrike Falcon, Cyberhaven, etc.).
public struct HelperProcessInfo: Codable, Sendable {
    public var pid: Int32
    public var name: String
    public var executablePath: String?
    public var bundleID: String?
    public var startAbsTime: UInt64
    public var userTimeNs: UInt64
    public var systemTimeNs: UInt64
    public var energyNanojoules: UInt64
    public var billedEnergyNanojoules: UInt64
    public var diskReadBytes: UInt64
    public var diskWriteBytes: UInt64
    public var pageins: UInt64
    public var residentBytes: UInt64
    public var euid: UInt32
    /// Apple's composite energy impact score for this process (same metric
    /// Activity Monitor uses). Populated from powermetrics when available;
    /// zero if powermetrics is unavailable or the process wasn't in its output.
    public var energyImpact: Double

    public init(
        pid: Int32,
        name: String,
        executablePath: String?,
        bundleID: String?,
        startAbsTime: UInt64,
        userTimeNs: UInt64,
        systemTimeNs: UInt64,
        energyNanojoules: UInt64,
        billedEnergyNanojoules: UInt64,
        diskReadBytes: UInt64,
        diskWriteBytes: UInt64,
        pageins: UInt64,
        residentBytes: UInt64,
        euid: UInt32,
        energyImpact: Double = 0
    ) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.startAbsTime = startAbsTime
        self.userTimeNs = userTimeNs
        self.systemTimeNs = systemTimeNs
        self.energyNanojoules = energyNanojoules
        self.billedEnergyNanojoules = billedEnergyNanojoules
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.pageins = pageins
        self.residentBytes = residentBytes
        self.euid = euid
        self.energyImpact = energyImpact
    }
}

public struct HelperHelloResponse: Codable, Sendable {
    public var protocolVersion: Int
    public var helperVersion: String
    public init(protocolVersion: Int, helperVersion: String) {
        self.protocolVersion = protocolVersion
        self.helperVersion = helperVersion
    }
}

@objc public protocol WattHelperXPC {
    /// Returns `HelperHelloResponse` JSON-encoded so the protocol survives
    /// future field additions without breaking older app builds.
    func hello(reply: @escaping (Data?, Error?) -> Void)

    /// Returns `[HelperProcessInfo]` JSON-encoded.
    func listProcesses(reply: @escaping (Data?, Error?) -> Void)
}
