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
    /// Whether this device's hardware and OS can host the on-device model at
    /// all, independent of the current toggle or download state. When false
    /// the connection is not offered on this device (local servers only);
    /// transient states like "turned off" or "still downloading" keep it true.
    public var deviceEligible: Bool

    public init(status: Status, reason: String?, recovery: String?, deviceEligible: Bool = true) {
        self.status = status
        self.reason = reason
        self.recovery = recovery
        self.deviceEligible = deviceEligible
    }

    public static let available = AppleIntelligenceAvailability(status: .available, reason: nil, recovery: nil)

    public static func unavailable(reason: String, recovery: String?, deviceEligible: Bool = true) -> AppleIntelligenceAvailability {
        AppleIntelligenceAvailability(status: .unavailable, reason: reason, recovery: recovery, deviceEligible: deviceEligible)
    }

    public var isAvailable: Bool { status == .available }
}
