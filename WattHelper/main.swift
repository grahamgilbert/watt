import Foundation
import os.log
import WattHelperProtocol

let logger = Logger(subsystem: "com.grahamgilbert.watt.helper", category: "main")

final class WattHelper: NSObject, NSXPCListenerDelegate, WattHelperXPC {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let exported = NSXPCInterface(with: WattHelperXPC.self)
        newConnection.exportedInterface = exported
        newConnection.exportedObject = self

        // Enforce that the peer is signed by our team — prevents arbitrary
        // unprivileged processes from binding our Mach service.
        if #available(macOS 13.0, *) {
            do {
                try newConnection.setCodeSigningRequirement(
                    "anchor apple generic and certificate leaf[subject.OU] = \"$(WATT_TEAM_ID)\""
                )
            } catch {
                logger.error("setCodeSigningRequirement failed: \(error.localizedDescription)")
            }
        }

        newConnection.invalidationHandler = {
            logger.debug("XPC connection invalidated")
        }
        newConnection.resume()
        return true
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("pong")
    }

    func samplePower(durationMillis: Int, reply: @escaping (Data?, Error?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = [
            "--samplers", "cpu_power,gpu_power,tasks",
            "--format", "plist",
            "-i", String(max(100, durationMillis)),
            "-n", "1"
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = nil

        do {
            try process.run()
        } catch {
            reply(nil, error)
            return
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            reply(nil, NSError(domain: "WattHelper", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "powermetrics exited with status \(process.terminationStatus)"
            ]))
            return
        }
        reply(data, nil)
    }
}

let listener = NSXPCListener(machServiceName: WattHelperMachServiceName)
let helper = WattHelper()
listener.delegate = helper
listener.resume()
logger.info("WattHelper started, listening on \(WattHelperMachServiceName)")
RunLoop.main.run()
