import Foundation
import SwiftData

public enum WattStore {
    public static let schema = Schema([
        Sample.self,
        ProcessSample.self,
        UserEvent.self,
        DrainEpisode.self,
        Report.self
    ])

    /// Root data directory: `~/Library/Application Support/Watt/`. Holds the
    /// SwiftData store, the `Reports/` mirror directory, and any future
    /// on-disk artifacts.
    public static func dataDirectory() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appending(path: "Watt", directoryHint: .isDirectory)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// On-disk Markdown mirror of every `Report`. The SwiftData store remains
    /// the source of truth; this directory is rewritten on every report
    /// generation so a user can grep, share, or open the files directly.
    public static func reportsDirectory() throws -> URL {
        let dir = try dataDirectory().appending(path: "Reports", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func defaultStoreURL() throws -> URL {
        try dataDirectory().appending(path: "store.sqlite", directoryHint: .notDirectory)
    }

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
        let url = try defaultStoreURL()
        let configuration = ModelConfiguration(url: url)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Lightweight migration failed (e.g. a new non-optional column was added
            // without a default). The store is ephemeral telemetry — episodes and
            // reports are small and regenerable. Delete and start fresh rather than
            // blocking the app from launching.
            print("WattStore: migration failed (\(error)). Deleting store and starting fresh.")
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                let path = url.path + suffix
                if fm.fileExists(atPath: path) {
                    try? fm.removeItem(atPath: path)
                }
            }
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(url: url)])
        }
    }
}
