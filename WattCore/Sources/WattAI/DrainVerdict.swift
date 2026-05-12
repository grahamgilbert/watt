import Foundation

/// The plain-language piece of a `Report`. Authored either by the on-device
/// `FoundationModels` session or by `Templater.fallbackVerdict` when Apple
/// Intelligence is unavailable. Either way, this is the only part of the
/// report that is not deterministically derived from the underlying samples.
public struct DrainVerdict: Sendable, Hashable, Codable {
    public var headline: String
    public var verdictParagraph: String
    public var suspectRationales: [String]
    public var recommendedActions: [String]

    public init(
        headline: String,
        verdictParagraph: String,
        suspectRationales: [String],
        recommendedActions: [String]
    ) {
        self.headline = headline
        self.verdictParagraph = verdictParagraph
        self.suspectRationales = suspectRationales
        self.recommendedActions = recommendedActions
    }
}
