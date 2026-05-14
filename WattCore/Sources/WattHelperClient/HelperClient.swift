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

    /// Always calls register(), regardless of current status. Used when
    /// re-installing after a binary update — the service is .enabled but
    /// launchd needs to be told about the new binary.
    public func forceRegister() throws {
        let service = Self.appService()
        do {
            try service.register()
        } catch {
            // SMAppService throws if status is .requiresApproval
            if service.status == .requiresApproval {
                throw HelperError.requiresApproval
            }
            throw error
        }
    }

    public func unregister() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.appService().unregister { _ in
                continuation.resume()
            }
        }
    }

    public func currentStatus() -> SMAppService.Status {
        Self.appService().status
    }

    public func hello(timeout: TimeInterval = 3) async throws -> HelperHelloResponse {
        let data: Data = try await withConnection(timeout: timeout) { proxy, once in
            proxy.hello { data, error in
                if let error {
                    once.resume(throwing: HelperError.xpcFailed(error.localizedDescription))
                } else if let data {
                    once.resume(returning: data)
                } else {
                    once.resume(throwing: HelperError.timeout)
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
        let data: Data = try await withConnection(timeout: timeout) { proxy, once in
            proxy.listProcesses { data, error in
                if let error {
                    once.resume(throwing: HelperError.xpcFailed(error.localizedDescription))
                } else if let data {
                    once.resume(returning: data)
                } else {
                    once.resume(throwing: HelperError.timeout)
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

    // Wraps a CheckedContinuation so that only the first resume call wins.
    // Both the XPC error handler and the reply callback hold a reference; we
    // must guarantee exactly one resume regardless of ordering.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }

    private func withConnection<T: Sendable>(
        timeout: TimeInterval,
        body: @escaping @Sendable (any WattHelperXPC, Once<T>) -> Void
    ) async throws -> T {
        let raw = NSXPCConnection(
            machServiceName: WattHelperMachServiceName,
            options: .privileged
        )
        raw.remoteObjectInterface = NSXPCInterface(with: WattHelperXPC.self)
        raw.resume()
        let box = ConnectionBox(connection: raw)

        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                box.connection.invalidate()
                once.resume(throwing: HelperError.timeout)
            }

            raw.invalidationHandler = {
                timeoutTask.cancel()
                box.connection.invalidate()
            }

            let proxy = box.connection.remoteObjectProxyWithErrorHandler { error in
                logger.error("XPC remote object error: \(error.localizedDescription, privacy: .public)")
                timeoutTask.cancel()
                box.connection.invalidate()
                once.resume(throwing: HelperError.xpcFailed(error.localizedDescription))
            }
            guard let typed = proxy as? any WattHelperXPC else {
                logger.error("XPC proxy cast failed — proxy type: \(type(of: proxy), privacy: .public)")
                timeoutTask.cancel()
                box.connection.invalidate()
                once.resume(throwing: HelperError.notInstalled)
                return
            }
            body(typed, once)
        }
    }
}
