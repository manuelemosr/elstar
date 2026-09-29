import Foundation

/// Whether the built-in on-device model can answer right now, and - when it
/// cannot - an honest, actionable reason. Shown on the first-choice card and
/// anywhere a native send is attempted; never a silent fallback to a server.
public nonisolated struct AppleIntelligenceAvailability: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case available
        case unavailable
    }

    public var status: Status
    /// One-line human reason ("Apple Intelligence is turned off in Settings.").
    public var reason: String?
    /// Concrete next step ("Open Settings -> Apple Intelligence & Siri and turn
    /// it on."). Never a fake success.
    public var recovery: String?

    public static let available = AppleIntelligenceAvailability(status: .available, reason: nil, recovery: nil)

    public static func unavailable(reason: String, recovery: String?) -> AppleIntelligenceAvailability {
        AppleIntelligenceAvailability(status: .unavailable, reason: reason, recovery: recovery)
    }

    public var isAvailable: Bool { status == .available }
}
