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
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let url = try defaultStoreURL()
            configuration = ModelConfiguration(url: url)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
