import Foundation

struct RecordingContinuity {
    private var last: (wall: Date, elapsed: TimeInterval)?
    mutating func observe(wall: Date, elapsed: TimeInterval, cadence: TimeInterval) -> String? {
        defer { last = (wall, elapsed) }
        guard let last else { return nil }
        let duration = elapsed - last.elapsed
        if duration <= 0 || abs(wall.timeIntervalSince(last.wall) - duration) > 2 { return "Clock changed or sleep was not observed" }
        if duration > max(15, cadence * 2.5) { return "Sampling delayed" }
        return nil
    }
    mutating func reset() { last = nil }
}

// Everything here runs on Monitor's single recorder queue after initialization.
final class RecorderBackend: @unchecked Sendable {
    let collector = Collector()
    var store: HistoryStore?
    var initializationError: String?
    var continuity = RecordingContinuity()
    var segment = UUID().uuidString
    var lastFrame: Date?
    var gap: RecordingGap?
    private var persistedGap: String?

    func restore() throws -> ([Frame], [RecordingGap]) {
        guard let store else { return ([], []) }
        let frames = try store.recent()
        let gaps = try store.gaps()
        lastFrame = frames.last?.time
        if let open = gaps.last(where: { $0.end == nil }) { gap = open; persistedGap = open.id }
        else if let lastFrame { interrupt(at: lastFrame, reason: "Recorder was not running") }
        return (frames, try store.gaps())
    }
    func interrupt(at time: Date = Date(), reason: String) {
        collector.reset(); continuity.reset(); segment = UUID().uuidString
        guard gap == nil else { return }
        gap = RecordingGap(id: UUID().uuidString, start: time, end: nil, reason: reason)
        persistedGap = try? store?.beginGap(at: time, reason: reason)
    }
    func sample(cadence: TimeInterval, wall: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> (Frame?, String?) {
        if let reason = continuity.observe(wall: wall, elapsed: uptime, cadence: cadence) {
            interrupt(at: lastFrame ?? wall, reason: reason)
            _ = continuity.observe(wall: wall, elapsed: uptime, cadence: cadence)
        }
        guard var frame = collector.sample() else {
            if collector.failed { interrupt(at:lastFrame ?? wall,reason:"System collection unavailable"); return (nil,"System collection unavailable") }
            return (nil, initializationError)
        }
        frame.segment = segment; frame.cadence = cadence
        guard let store else { return (frame, initializationError ?? "History unavailable; live values are not recorded.") }
        do {
            if let gap, persistedGap == nil { persistedGap = try store.beginGap(at: gap.start, reason: gap.reason) }
            try store.append(frame)
            if let persistedGap { try store.closeGap(persistedGap, at: frame.time) }
            gap = nil; persistedGap = nil; lastFrame = frame.time
            return (frame, nil)
        } catch {
            // A disk-full condition may prevent persisting the gap until recovery.
            interrupt(at: lastFrame ?? wall, reason: "Recording write failed")
            return (nil, "Recording interrupted: \(error.localizedDescription)")
        }
    }
}
