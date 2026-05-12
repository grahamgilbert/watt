import Foundation
import os.log
import ServiceManagement
import WattHelperProtocol

private let logger = Logger(subsystem: "com.grahamgilbert.watt", category: "helper-client")

public actor HelperClient {
    public enum HelperError: Error {
        case notInstalled
        case xpcFailed(Error)
        case timeout
    }

    public init() {}

    public func registerIfNeeded() throws {
        let service = SMAppService.daemon(plistName: "com.grahamgilbert.watt.helper.plist")
        switch service.status {
        case .enabled:
            return
        case .requiresApproval, .notRegistered, .notFound:
            do {
                try service.register()
            } catch {
                logger.error("SMAppService register failed: \(error.localizedDescription)")
                throw error
            }
        @unknown default:
            try? service.register()
        }
    }

    public func unregister() throws {
        let service = SMAppService.daemon(plistName: "com.grahamgilbert.watt.helper.plist")
        try service.unregister()
    }

    public func status() -> SMAppService.Status {
        SMAppService.daemon(plistName: "com.grahamgilbert.watt.helper.plist").status
    }

    public func ping(timeout: TimeInterval = 2) async throws -> String {
        try await withConnection(timeout: timeout) { proxy, continuation in
            proxy.ping { reply in
                continuation.resume(returning: reply)
            }
        }
    }

    public func samplePower(durationMillis: Int = 500, timeout: TimeInterval = 5) async throws -> Data {
        try await withConnection(timeout: timeout) { proxy, continuation in
            proxy.samplePower(durationMillis: durationMillis) { data, error in
                if let error {
                    continuation.resume(throwing: HelperError.xpcFailed(error))
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: HelperError.timeout)
                }
            }
        }
    }

    private func withConnection<T: Sendable>(
        timeout: TimeInterval,
        body: @escaping @Sendable (any WattHelperXPC, CheckedContinuation<T, Error>) -> Void
    ) async throws -> T {
        let connection = NSXPCConnection(
            machServiceName: WattHelperMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: WattHelperXPC.self)
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: HelperError.xpcFailed(error))
            }
            guard let typed = proxy as? any WattHelperXPC else {
                continuation.resume(throwing: HelperError.notInstalled)
                return
            }
            body(typed, continuation)
        }
    }
}
