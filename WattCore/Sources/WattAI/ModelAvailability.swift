import Foundation

/// Public, framework-agnostic representation of whether on-device
/// FoundationModels can answer a query. The `WattAI` module exposes this so
/// that callers (and tests) don't need to import `FoundationModels` directly.
public enum ModelAvailability: Sendable, Equatable {
    case available
    case appleIntelligenceNotEnabled
    case modelNotReady
    case deviceNotEligible
    case otherUnavailable(String)
}
