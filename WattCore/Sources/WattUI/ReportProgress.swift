import Foundation
import Observation
import SwiftData

/// MainActor-isolated UI state describing whether a report is being
/// generated. The report window (and menu) bind to this so the user gets a
/// progress banner / spinner when a lookback or regenerate action is in
/// flight.
@MainActor
@Observable
public final class ReportProgress {
    public enum Phase: Equatable, Sendable {
        case idle
        case generating(label: String)
        case finished(label: String, episodeID: PersistentIdentifier?)
        case failed(label: String, message: String)
    }

    public private(set) var phase: Phase = .idle

    /// When a generation finishes successfully, this is the episode the UI
    /// should auto-select. Cleared after the consumer reads it (set to nil).
    public var pendingSelection: PersistentIdentifier?

    public init() {}

    public func startGenerating(label: String) {
        phase = .generating(label: label)
    }

    public func finish(label: String, episodeID: PersistentIdentifier?) {
        phase = .finished(label: label, episodeID: episodeID)
        pendingSelection = episodeID
        // Auto-clear the success banner after a few seconds so it doesn't
        // sit on screen forever.
        let snapshot = phase
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                guard let self else { return }
                if self.phase == snapshot { self.phase = .idle }
            }
        }
    }

    public func fail(label: String, message: String) {
        phase = .failed(label: label, message: message)
        let snapshot = phase
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            await MainActor.run {
                guard let self else { return }
                if self.phase == snapshot { self.phase = .idle }
            }
        }
    }

    public var isGenerating: Bool {
        if case .generating = phase { return true }
        return false
    }
}
