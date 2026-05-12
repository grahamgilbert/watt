import CoreServices
import Foundation
import os.lock

/// Records the *rate* of filesystem events on the system, in events/second.
/// Per-process attribution would require an EndpointSecurity entitlement; this
/// sampler intentionally surfaces the rate only.
public final class FSEventsSampler: @unchecked Sendable {
    private let counter = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private var stream: FSEventStreamRef?
    private var lastSampleAt: Date = Date()
    private let lastSampleLock = OSAllocatedUnfairLock<Date>(initialState: Date())

    public init() {}

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = ["/" as CFString] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, _, _, _ in
                guard let info else { return }
                let owner = Unmanaged<FSEventsSampler>.fromOpaque(info).takeUnretainedValue()
                owner.bump(by: UInt64(count))
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func bump(by amount: UInt64) {
        counter.withLock { $0 = $0 &+ amount }
    }

    public func consumeRate() -> Double {
        let count = counter.withLock { current -> UInt64 in
            let v = current
            current = 0
            return v
        }
        let now = Date()
        let elapsed = lastSampleLock.withLock { last -> TimeInterval in
            let dt = now.timeIntervalSince(last)
            last = now
            return dt
        }
        guard elapsed > 0 else { return 0 }
        return Double(count) / elapsed
    }
}
