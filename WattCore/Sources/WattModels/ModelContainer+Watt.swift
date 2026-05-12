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

    public static func defaultStoreURL() throws -> URL {
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
        return dir.appending(path: "store.sqlite", directoryHint: .notDirectory)
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
