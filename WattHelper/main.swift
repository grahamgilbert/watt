import Darwin
import Foundation
import os.log
import WattHelperProtocol

private let logger = Logger(subsystem: "com.grahamgilbert.watt.helper", category: "main")

private let helperVersion: String = {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
}()

private final class HelperImpl: NSObject, NSXPCListenerDelegate, WattHelperXPC {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let exported = NSXPCInterface(with: WattHelperXPC.self)
        newConnection.exportedInterface = exported
        newConnection.exportedObject = self
        // Restrict peers to processes signed with our team ID. The helper
        // runs as root and absolutely must not respond to arbitrary callers.
        if #available(macOS 13.0, *) {
            do {
                try newConnection.setCodeSigningRequirement(
                    "anchor apple generic and certificate leaf[subject.OU] = \"9D8XP85393\""
                )
            } catch {
                logger.error("setCodeSigningRequirement failed: \(error.localizedDescription)")
                return false
            }
        }
        newConnection.invalidationHandler = {
            logger.debug("XPC connection invalidated")
        }
        newConnection.resume()
        return true
    }

    func hello(reply: @escaping (Data?, Error?) -> Void) {
        let payload = HelperHelloResponse(
            protocolVersion: WattHelperProtocolVersion,
            helperVersion: helperVersion
        )
        do {
            let data = try JSONEncoder().encode(payload)
            reply(data, nil)
        } catch {
            reply(nil, error)
        }
    }

    func listProcesses(reply: @escaping (Data?, Error?) -> Void) {
        let snapshots = enumerateProcesses()
        do {
            let data = try JSONEncoder().encode(snapshots)
            reply(data, nil)
        } catch {
            reply(nil, error)
        }
    }
}

/// Reads every visible pid via libproc. Unlike unprivileged callers, the
/// helper (running as root via launchd) sees Endpoint Security-protected
/// processes like CrowdStrike Falcon and Cyberhaven.
private func enumerateProcesses() -> [HelperProcessInfo] {
    let byteCount = proc_listallpids(nil, 0)
    guard byteCount > 0 else { return [] }
    let capacity = Int(byteCount) * 2
    var pids = [Int32](repeating: 0, count: capacity / MemoryLayout<Int32>.size)
    let actualBytes = pids.withUnsafeMutableBufferPointer { ptr -> Int32 in
        proc_listallpids(ptr.baseAddress, Int32(ptr.count) * Int32(MemoryLayout<Int32>.size))
    }
    let actualCount = Int(max(actualBytes, 0)) / MemoryLayout<Int32>.size
    guard actualCount > 0 else { return [] }
    let validPids = Array(pids.prefix(actualCount))

    var out: [HelperProcessInfo] = []
    out.reserveCapacity(actualCount)

    for pid in validPids where pid > 0 {
        var info = rusage_info_v6()
        let rusagePtr = withUnsafeMutablePointer(to: &info) { UnsafeMutableRawPointer($0) }
        let ok = proc_pid_rusage(pid, RUSAGE_INFO_V6, rusagePtr.assumingMemoryBound(to: rusage_info_t?.self))
        guard ok == 0 else { continue }

        var nameBuf = [CChar](repeating: 0, count: 256)
        let nameLen = nameBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_name(pid, buf.baseAddress, UInt32(buf.count))
        }
        let name = nameLen > 0 ? String(cString: nameBuf) : "pid \(pid)"

        var pathBuf = [CChar](repeating: 0, count: 4096)
        let pathLen = pathBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_pidpath(pid, buf.baseAddress, UInt32(buf.count))
        }
        let path = pathLen > 0 ? String(cString: pathBuf) : nil

        var bsd = proc_bsdinfo()
        let bsdPtr = withUnsafeMutablePointer(to: &bsd) { UnsafeMutableRawPointer($0) }
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bsdLen = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, bsdPtr, bsdSize)
        let euid: UInt32 = bsdLen == bsdSize ? bsd.pbi_uid : 0

        out.append(HelperProcessInfo(
            pid: pid,
            name: name,
            executablePath: path,
            bundleID: nil,
            startAbsTime: info.ri_proc_start_abstime,
            userTimeNs: info.ri_user_time,
            systemTimeNs: info.ri_system_time,
            energyNanojoules: info.ri_energy_nj,
            billedEnergyNanojoules: info.ri_billed_energy,
            diskReadBytes: info.ri_diskio_bytesread,
            diskWriteBytes: info.ri_diskio_byteswritten,
            pageins: info.ri_pageins,
            residentBytes: info.ri_resident_size,
            euid: euid
        ))
    }
    return out
}

private let listener = NSXPCListener(machServiceName: WattHelperMachServiceName)
private let helper = HelperImpl()
listener.delegate = helper
listener.resume()
logger.info("WattHelper \(helperVersion) listening on \(WattHelperMachServiceName)")
RunLoop.main.run()
