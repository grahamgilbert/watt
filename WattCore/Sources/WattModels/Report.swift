import Foundation
import SwiftData

@Model
public final class Report {
    @Attribute(.unique) public var id: UUID
    public var generatedAt: Date
    public var headline: String
    public var markdown: String
    public var generatedByLLM: Bool
    public var modelTokenCount: Int?
    public var episode: DrainEpisode?

    public init(
        id: UUID = UUID(),
        generatedAt: Date,
        headline: String,
        markdown: String,
        generatedByLLM: Bool,
        modelTokenCount: Int? = nil,
        episode: DrainEpisode? = nil
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.headline = headline
        self.markdown = markdown
        self.generatedByLLM = generatedByLLM
        self.modelTokenCount = modelTokenCount
        self.episode = episode
    }
}
