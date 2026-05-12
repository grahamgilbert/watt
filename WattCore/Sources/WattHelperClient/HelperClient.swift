import Foundation
import os.log
import ServiceManagement
import WattHelperProtocol

private let logger = Logger(subsystem: "com.grahamgilbert.watt", category: "helper-client")

/// Talks to `com.grahamgilbert.watt.helper` over XPC. The helper runs as
/// root (registered via `SMAppService.daemon`) and provides visibility into
/// processes that an unprivileged client cannot see — primarily Endpoint
/// Security extensions like CrowdStrike Falcon.
public actor HelperClient {
    public enum HelperError: Error, Sendable {
        case notInstalled
        case requiresApproval
        case versionMismatch(installed: Int, expected: Int)
        case xpcFailed(String)
        case timeout
        case decodeFailed(String)
    }

    public init() {}

    public func registerIfNeeded() throws {
        let service = Self.appService()
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            throw HelperError.requiresApproval
        case .notRegistered, .notFound:
            try service.register()
        @unknown default:
            try? service.register()
        }
    }

    public func unregister() throws {
        try Self.appService().unregister()
    }

    public func currentStatus() -> SMAppService.Status {
        Self.appService().status
    }

    public func hello(timeout: TimeInterval = 3) async throws -> HelperHelloResponse {
        let data: Data = try await withConnection(timeout: timeout) { proxy, continuation in
            proxy.hello { data, error in
                if let error {
                    continuation.resume(throwing: HelperError.xpcFailed(error.localizedDescription))
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: HelperError.timeout)
                }
            }
        }
        do {
            return try JSONDecoder().decode(HelperHelloResponse.self, from: data)
        } catch {
            throw HelperError.decodeFailed(error.localizedDescription)
        }
    }

    public func listProcesses(timeout: TimeInterval = 5) async throws -> [HelperProcessInfo] {
        let data: Data = try await withConnection(timeout: timeout) { proxy, continuation in
            proxy.listProcesses { data, error in
                if let error {
                    continuation.resume(throwing: HelperError.xpcFailed(error.localizedDescription))
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: HelperError.timeout)
                }
            }
        }
        do {
            return try JSONDecoder().decode([HelperProcessInfo].self, from: data)
        } catch {
            throw HelperError.decodeFailed(error.localizedDescription)
        }
    }

    // MARK: - Internals

    private static func appService() -> SMAppService {
        SMAppService.daemon(plistName: "com.grahamgilbert.watt.helper.plist")
    }

    private struct ConnectionBox: @unchecked Sendable {
        let connection: NSXPCConnection
    }

    private func withConnection<T: Sendable>(
        timeout: TimeInterval,
        body: @escaping @Sendable (any WattHelperXPC, CheckedContinuation<T, Error>) -> Void
    ) async throws -> T {
        let raw = NSXPCConnection(
            machServiceName: WattHelperMachServiceName,
            options: .privileged
        )
        raw.remoteObjectInterface = NSXPCInterface(with: WattHelperXPC.self)
        raw.resume()
        let box = ConnectionBox(connection: raw)

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            box.connection.invalidate()
        }
        defer {
            timeoutTask.cancel()
            box.connection.invalidate()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let proxy = box.connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: HelperError.xpcFailed(error.localizedDescription))
            }
            guard let typed = proxy as? any WattHelperXPC else {
                continuation.resume(throwing: HelperError.notInstalled)
                return
            }
            body(typed, continuation)
        }
    }
}
