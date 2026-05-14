import Foundation
import Observation

/// Persisted user preferences for Watt. All values are stored in
/// UserDefaults.standard under stable keys so they survive app restarts.
@MainActor
@Observable
public final class WattPreferences {
    private enum Keys {
        static let notifyOnEpisodeReady = "watt.prefs.notifyOnEpisodeReady"
    }

    public var notifyOnEpisodeReady: Bool {
        didSet { UserDefaults.standard.set(notifyOnEpisodeReady, forKey: Keys.notifyOnEpisodeReady) }
    }

    public init() {
        // Default true — notifications are on unless the user has explicitly turned them off.
        if UserDefaults.standard.object(forKey: Keys.notifyOnEpisodeReady) == nil {
            self.notifyOnEpisodeReady = true
        } else {
            self.notifyOnEpisodeReady = UserDefaults.standard.bool(forKey: Keys.notifyOnEpisodeReady)
        }
    }
}
